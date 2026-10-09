import Foundation
import CryptoKit
import Darwin

public actor VaultService {
    public static let blockSize = 4 * 1024 * 1024
    public static let noteLimit = 1024 * 1024
    public static let previewLimit = 32 * 1024 * 1024
    public let root: URL
    private let hooks: StorageHooks
    private let lockFD: Int32
    private var state: StoreState
    private var master: SymmetricKey?
    private var manifest: Manifest?
    private var retainedDraft: (vault: UUID, store: UUID, note: UUID, sealed: Data)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var stores: URL { root.appendingPathComponent("vaults", isDirectory: true) }
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private func store(_ id: UUID) -> URL { stores.appendingPathComponent(id.uuidString, isDirectory: true) }
    private var activeURL: URL { store(state.active!) }
    private func objectURL(_ id: UUID, at url: URL) -> URL { url.appendingPathComponent("objects").appendingPathComponent(id.uuidString + ".hzn") }

    public init(root: URL, hooks: StorageHooks = StorageHooks()) throws {
        self.root = root
        self.hooks = hooks
        try Disk.directory(root)
        try Disk.directory(root.appendingPathComponent("vaults"))
        let fd = Darwin.open(root.appendingPathComponent(".process-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HorizonError.message("Не удалось открыть Horizon.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw HorizonError.message("Horizon уже запущен. Откройте существующее окно.")
        }
        lockFD = fd
        do {
            let url = root.appendingPathComponent("state.json")
            if Disk.fm.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(StoreState.self, from: Disk.read(url, maximum: 64 * 1024))
                guard state.version == 1 else { throw HorizonError.message("Нужна более новая версия Horizon.") }
                if let active = state.active { try Disk.requireDirectory(root.appendingPathComponent("vaults").appendingPathComponent(active.uuidString)) }
            } else { state = StoreState() }
        } catch { flock(fd, LOCK_UN); Darwin.close(fd); throw error }
    }
    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }

    public func status() -> VaultStatus {
        VaultStatus(exists: state.active != nil, lastBackup: state.lastBackup, previousCount: state.previous.count, hasDraft: retainedDraft != nil)
    }
    public func items() throws -> [VaultItem] { try unlocked().1.items }
    private func unlocked() throws -> (SymmetricKey, Manifest) {
        guard let master, let manifest else { throw HorizonError.message("Пространство закрыто.") }
        return (master, manifest)
    }
    private func header(at url: URL) throws -> Header {
        try Disk.requireDirectory(url)
        let h = try decoder.decode(Header.self, from: Disk.read(url.appendingPathComponent("header.json"), maximum: 64 * 1024))
        guard h.version == 1, h.rounds == 600_000, h.salt.count == 32, h.passwordWrap.count == 60, h.recoveryWrap.count == 60 else {
            throw HorizonError.message("Неподдерживаемый или повреждённый формат хранилища.")
        }
        return h
    }
    private func wrapContext(_ vault: UUID, _ method: String) -> String { "Horizon.v1.\(method)|\(vault.uuidString)" }
    private func masterKey(header h: Header, password: String) throws -> SymmetricKey {
        do {
            let bytes = try VaultCrypto.open(h.passwordWrap, key: VaultCrypto.passwordKey(password, header: h), context: wrapContext(h.vaultID, "password"))
            guard bytes.count == 32 else { throw HorizonError.message("Повреждён ключ.") }
            return SymmetricKey(data: bytes)
        } catch { throw HorizonError.message("Неверный пароль или повреждён ключ хранилища.") }
    }
    private func masterKey(header h: Header, recovery: String) throws -> SymmetricKey {
        let recoveryBytes = try VaultCrypto.recoveryData(recovery)
        do {
            let bytes = try VaultCrypto.open(h.recoveryWrap, key: SymmetricKey(data: recoveryBytes), context: wrapContext(h.vaultID, "recovery"))
            guard bytes.count == 32 else { throw HorizonError.message("Повреждён ключ.") }
            return SymmetricKey(data: bytes)
        } catch { throw HorizonError.message("Неверный ключ восстановления.") }
    }
    private func validate(_ m: Manifest, at url: URL) throws {
        try Disk.requireDirectory(url.appendingPathComponent("objects"))
        guard (1...2).contains(m.version), m.items.count <= 100_000, m.pendingRecovery == nil || m.pendingRecovery?.count == 32 else { throw HorizonError.message("Неподдерживаемый каталог.") }
        let ids = Set(m.items.map(\.id))
        guard ids.count == m.items.count else { throw HorizonError.message("Повреждён каталог.") }
        let byID = Dictionary(uniqueKeysWithValues: m.items.map { ($0.id, $0) })
        var objects = Set<UUID>()
        for item in m.items {
            _ = try validName(item.name)
            guard item.rootPosition?.isValid != false, item.localPosition?.isValid != false,
                m.version == 1 || (item.rootPosition != nil && (item.parent == nil ? item.localPosition == nil : item.localPosition != nil)) else {
                throw HorizonError.message("Повреждено расположение карты.")
            }
            guard (item.trashedAt == nil) == (item.trashBatch == nil) else { throw HorizonError.message("Повреждена Корзина.") }
            if let p = item.parent {
                guard let folder = byID[p], folder.isFolder, item.isTrashed || !folder.isTrashed else { throw HorizonError.message("Повреждена структура папок.") }
            }
            var visited: Set<UUID> = [item.id]; var parent = item.parent
            while let p = parent {
                guard visited.insert(p).inserted else { throw HorizonError.message("Цикл в структуре папок.") }
                parent = byID[p]?.parent
            }
            if item.isFolder {
                guard item.object == nil, item.size == 0, item.chunks == 0, item.digest == nil else { throw HorizonError.message("Повреждена папка.") }
            } else {
                guard let object = item.object, objects.insert(object).inserted, item.digest?.count == 32,
                    item.chunks == max(1, item.size / UInt64(Self.blockSize) + (item.size % UInt64(Self.blockSize) == 0 ? 0 : 1)),
                    item.size <= UInt64(Int64.max), !item.isNote || item.size <= Self.noteLimit else { throw HorizonError.message("Повреждена запись файла.") }
                try Disk.regular(objectURL(object, at: url))
            }
        }
    }
    private func readManifest(at url: URL, h: Header, key: SymmetricKey) throws -> Manifest {
        do {
            let sealed = try Disk.read(url.appendingPathComponent("manifest.hzn"), maximum: 64 * 1024 * 1024)
            let bytes = try VaultCrypto.open(sealed, key: VaultCrypto.subkey(key, vault: h.vaultID, purpose: "manifest"), context: "Horizon.v1.manifest|" + h.vaultID.uuidString)
            let m = try decoder.decode(Manifest.self, from: bytes)
            guard m.vaultID == h.vaultID else { throw HorizonError.message("Неверный каталог.") }
            try validate(m, at: url)
            return m
        } catch { throw HorizonError.message("Не удалось прочитать каталог. Хранилище повреждено или копия неполная.") }
    }
    private func writeManifest(_ candidate: Manifest, at url: URL, key: SymmetricKey) throws {
        let data = try encoder.encode(candidate)
        guard data.count <= 64 * 1024 * 1024 - 28 else { throw HorizonError.message("Каталог превышает допустимый размер.") }
        try Disk.atomic(VaultCrypto.seal(data, key: VaultCrypto.subkey(key, vault: candidate.vaultID, purpose: "manifest"), context: "Horizon.v1.manifest|" + candidate.vaultID.uuidString), to: url.appendingPathComponent("manifest.hzn"))
    }
    private func commit(_ candidate: Manifest) throws {
        let key = try unlocked().0
        try validate(candidate, at: activeURL)
        try hooks.checkpoint(.beforeManifest)
        try writeManifest(candidate, at: activeURL, key: key)
        manifest = candidate
        try hooks.checkpoint(.afterManifest)
    }
    private func activate(_ id: UUID, token: OperationToken? = nil) throws {
        try hooks.checkpoint(.beforeActivation); try token?.check()
        var next = state
        if let previous = state.active { next.previous.append(previous) }
        next.active = id; next.lastBackup = nil
        try Disk.atomic(encoder.encode(next), to: stateURL)
        state = next
    }

    public func create(password: String) throws -> String {
        guard state.active == nil else { throw HorizonError.message("Пространство уже создано.") }
        try VaultCrypto.validatePassword(password)
        let id = UUID(); let vault = UUID(); let destination = store(id)
        let bytes = try VaultCrypto.random(32); let recovery = try VaultCrypto.random(32)
        let key = SymmetricKey(data: bytes)
        var h = Header(vaultID: vault, salt: try VaultCrypto.random(32), passwordWrap: Data(repeating: 0, count: 60), recoveryWrap: Data(repeating: 0, count: 60))
        h.passwordWrap = try VaultCrypto.seal(bytes, key: VaultCrypto.passwordKey(password, header: h), context: wrapContext(vault, "password"))
        h.recoveryWrap = try VaultCrypto.seal(bytes, key: SymmetricKey(data: recovery), context: wrapContext(vault, "recovery"))
        let m = Manifest(vaultID: vault, pendingRecovery: recovery)
        do {
            try Disk.directory(destination.appendingPathComponent("objects"))
            try Disk.directory(destination.appendingPathComponent("staging"))
            try writeManifest(m, at: destination, key: key)
            try Disk.atomic(encoder.encode(h), to: destination.appendingPathComponent("header.json"))
            try activate(id)
            master = key; manifest = m
        } catch { if state.active != id { try? Disk.fm.removeItem(at: destination) }; throw error }
        return VaultCrypto.recoveryString(recovery)
    }
    public func unlock(password: String, token: OperationToken = OperationToken(), progress: ProgressHandler? = nil) throws {
        guard state.active != nil else { throw HorizonError.message("Сначала создайте пространство.") }
        let h = try header(at: activeURL)
        let key = try masterKey(header: h, password: password)
        let old = try readManifest(at: activeURL, h: h, key: key)
        let m = try migrateIfNeeded(old, header: h, key: key, token: token, progress: progress)
        master = key; manifest = m
        do { try expireTrash(); try cleanOrphans() }
        catch { master = nil; manifest = nil; throw error }
    }
    private func upgraded(_ old: Manifest) -> Manifest {
        guard old.version == 1 else { return old }
        var m = old; m.version = 2
        let ordered = m.items.indices.sorted {
            m.items[$0].created == m.items[$1].created ? m.items[$0].id.uuidString < m.items[$1].id.uuidString : m.items[$0].created < m.items[$1].created
        }
        var localSlots: [UUID: Int] = [:]
        for (slot, index) in ordered.enumerated() {
            m.items[index].rootPosition = .automatic(slot)
            if let parent = m.items[index].parent {
                let local = localSlots[parent, default: 0]
                m.items[index].localPosition = .automatic(local); localSlots[parent] = local + 1
            } else { m.items[index].localPosition = nil }
        }
        return m
    }
    private func migrateIfNeeded(_ old: Manifest, header h: Header, key: SymmetricKey,
                                 token: OperationToken, progress: ProgressHandler?) throws -> Manifest {
        guard old.version == 1 else { try token.check(); return old }
        let source = activeURL; let id = UUID(); let target = store(id); let m = upgraded(old)
        progress?(OperationProgress(fraction: 0, phase: "Обновление карты"))
        do {
            try Disk.directory(target.appendingPathComponent("objects")); try Disk.directory(target.appendingPathComponent("staging"))
            let files = m.items.filter { !$0.isFolder }
            for (index, item) in files.enumerated() {
                let destination = objectURL(item.object!, at: target)
                try Disk.copy(objectURL(item.object!, at: source), destination, token: token)
                try consume(item, url: destination, vault: m.vaultID, key: key, token: token, sink: { _ in })
                progress?(OperationProgress(fraction: Double(index + 1) / Double(max(1, files.count)), phase: "Обновление карты"))
            }
            try validate(m, at: target); try hooks.checkpoint(.beforeManifest)
            try writeManifest(m, at: target, key: key); try hooks.checkpoint(.afterManifest)
            try Disk.atomic(encoder.encode(h), to: target.appendingPathComponent("header.json"))
            _ = try readManifest(at: target, h: h, key: key)
            Disk.syncDirectory(target.appendingPathComponent("objects")); Disk.syncDirectory(target); Disk.syncDirectory(stores)
            try token.check(); try activate(id, token: token); return m
        } catch { if state.active != id { try? Disk.fm.removeItem(at: target) }; throw error }
    }
    public func setSpacePositions(_ positions: [UUID: SpacePoint], folder: UUID?) throws {
        var m = try unlocked().1; try checkParent(folder, in: m)
        let indices = Dictionary(uniqueKeysWithValues: m.items.indices.map { (m.items[$0].id, $0) })
        for (id, point) in positions {
            guard point.isValid, let index = indices[id], !m.items[index].isTrashed,
                  folder == nil || m.items[index].parent == folder else { throw HorizonError.message("Запись или расположение недоступны.") }
            if folder == nil { m.items[index].rootPosition = point }
            else { m.items[index].localPosition = point }
        }
        if !positions.isEmpty { try commit(m) }
    }
    private func place(_ item: inout VaultItem, in m: Manifest, placement: ImportPlacement? = nil) throws {
        let roots = m.items.compactMap(\.rootPosition)
        item.rootPosition = try SpacePoint.available(near: item.parent == nil ? placement?.point : nil,
            spacing: item.parent == nil ? placement?.spacing ?? 56 : 56, occupied: roots)
        if let parent = item.parent {
            item.localPosition = try SpacePoint.available(near: placement?.point, spacing: placement?.spacing ?? 56,
                occupied: m.items.filter { $0.parent == parent }.compactMap(\.localPosition))
        } else { item.localPosition = nil }
    }
    public func recover(code: String, newPassword: String, token: OperationToken = OperationToken(), progress: ProgressHandler? = nil) throws {
        try VaultCrypto.validatePassword(newPassword)
        guard state.active != nil else { throw HorizonError.message("Хранилище не найдено.") }
        var h = try header(at: activeURL)
        let key = try masterKey(header: h, recovery: code)
        let old = try readManifest(at: activeURL, h: h, key: key)
        let m = try migrateIfNeeded(old, header: h, key: key, token: token, progress: progress)
        let bytes = key.withUnsafeBytes { Data($0) }
        h.salt = try VaultCrypto.random(32)
        h.passwordWrap = try VaultCrypto.seal(bytes, key: VaultCrypto.passwordKey(newPassword, header: h), context: wrapContext(h.vaultID, "password"))
        try Disk.atomic(encoder.encode(h), to: activeURL.appendingPathComponent("header.json"))
        master = key; manifest = m
        do { try expireTrash(); try cleanOrphans() }
        catch { master = nil; manifest = nil; throw error }
    }
    public func changePassword(current: String, new: String) throws {
        let (key, m) = try unlocked(); try VaultCrypto.validatePassword(new)
        var h = try header(at: activeURL)
        let verified = try masterKey(header: h, password: current)
        guard verified.withUnsafeBytes({ Data($0) }) == key.withUnsafeBytes({ Data($0) }) else { throw HorizonError.message("Неверный пароль.") }
        h.salt = try VaultCrypto.random(32)
        h.passwordWrap = try VaultCrypto.seal(key.withUnsafeBytes { Data($0) }, key: VaultCrypto.passwordKey(new, header: h), context: wrapContext(m.vaultID, "password"))
        try Disk.atomic(encoder.encode(h), to: activeURL.appendingPathComponent("header.json"))
    }
    public func pendingRecoveryKey() throws -> String? {
        guard let bytes = try unlocked().1.pendingRecovery else { return nil }
        guard bytes.count == 32 else { throw HorizonError.message("Повреждён ключ восстановления.") }
        return VaultCrypto.recoveryString(bytes)
    }
    public func acknowledgeRecoveryKey() throws {
        var m = try unlocked().1; m.pendingRecovery = nil; try commit(m)
    }
    public func lock(draft: NoteDraft? = nil) -> Bool {
        if let draft, let key = master, let m = manifest, let storeID = state.active {
            do { _ = try saveNote(draft) }
            catch {
                if let data = try? encoder.encode(draft), let sealed = try? VaultCrypto.seal(data, key: VaultCrypto.subkey(key, vault: m.vaultID, purpose: "draft"), context: "Horizon.v1.draft|" + m.vaultID.uuidString) {
                    retainedDraft = (m.vaultID, storeID, draft.id, sealed)
                }
            }
        }
        master = nil; manifest = nil
        return retainedDraft != nil
    }
    public func pendingDraft() throws -> NoteDraft? {
        let (key, m) = try unlocked()
        guard let retainedDraft, retainedDraft.vault == m.vaultID, retainedDraft.store == state.active else { return nil }
        return try decoder.decode(NoteDraft.self, from: VaultCrypto.open(retainedDraft.sealed, key: VaultCrypto.subkey(key, vault: m.vaultID, purpose: "draft"), context: "Horizon.v1.draft|" + m.vaultID.uuidString))
    }
    private func validName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 240, name != ".", name != "..", !name.contains("/"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HorizonError.message("Название: от 1 до 240 символов, без косой черты и управляющих символов.")
        }
        return name
    }
    private func checkParent(_ parent: UUID?, in m: Manifest) throws {
        if let parent { guard m.items.contains(where: { $0.id == parent && $0.isFolder && !$0.isTrashed }) else { throw HorizonError.message("Папка недоступна.") } }
    }
    private func uniqueName(_ value: String, parent: UUID?, in m: Manifest, excluding: UUID? = nil) throws -> String {
        let name = try validName(value)
        let taken = Set(m.items.filter { $0.parent == parent && !$0.isTrashed && $0.id != excluding }.map { $0.name.lowercased() })
        if !taken.contains(name.lowercased()) { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for suffix in 2...100_002 {
            let extra = " (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
            let candidate = String(base.prefix(max(1, 240 - extra.count))) + extra
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        throw HorizonError.message("Слишком много одинаковых названий.")
    }
    private func newItem(name: String, kind: ItemKind, parent: UUID?, m: Manifest) throws -> VaultItem {
        try checkParent(parent, in: m)
        guard m.items.count < 100_000 else { throw HorizonError.message("Достигнут предел: 100 000 записей.") }
        var item = VaultItem(id: UUID(), name: try uniqueName(name, parent: parent, in: m), kind: kind, parent: parent,
            created: Date(), modified: Date(), size: 0, object: nil, chunks: 0, digest: nil, trashedAt: nil, trashBatch: nil)
        try place(&item, in: m); return item
    }
    public func createFolder(name: String, parent: UUID?) throws -> VaultItem {
        var m = try unlocked().1
        let item = try newItem(name: name, kind: .folder, parent: parent, m: m)
        m.items.append(item); try commit(m); return item
    }
    public func createNote(name: String, parent: UUID?) throws -> VaultItem {
        var m = try unlocked().1
        var item = try newItem(name: name, kind: .note, parent: parent, m: m)
        item = try writeObject(item, data: Data(), source: nil, expectedSize: 0, token: OperationToken(), progress: nil)
        m.items.append(item)
        do { try commit(m) } catch { removeUnreferenced(item.object); throw error }
        return item
    }
    private func chunkContext(vault: UUID, object: UUID, index: UInt64, length: Int, size: UInt64, chunks: UInt64) -> String {
        "Horizon.v1.chunk|\(vault.uuidString)|\(object.uuidString)|\(index)|\(length)|\(size)|\(chunks)"
    }
    private func writeObject(_ original: VaultItem, data: Data?, source: FileHandle?, expectedSize: UInt64,
                             token: OperationToken, progress: ProgressHandler?) throws -> VaultItem {
        let (key, m) = try unlocked()
        let object = UUID(); let staging = activeURL.appendingPathComponent("staging").appendingPathComponent(object.uuidString)
        try Disk.directory(staging.deletingLastPathComponent())
        let output = try Disk.newFile(staging)
        var result = original
        result.object = object; result.size = expectedSize
        result.chunks = max(1, expectedSize / UInt64(Self.blockSize) + (expectedSize % UInt64(Self.blockSize) == 0 ? 0 : 1))
        let fileKey = VaultCrypto.subkey(key, vault: m.vaultID, purpose: "object." + object.uuidString)
        var hasher = SHA256(); var offset: UInt64 = 0
        defer { try? output.close(); try? Disk.fm.removeItem(at: staging) }
        try output.write(contentsOf: Data("HZNOBJ01".utf8))
        for number in 0..<result.chunks {
            try token.check()
            let length = Int(min(UInt64(Self.blockSize), expectedSize - offset))
            let plain: Data
            if let data { plain = data.subdata(in: Int(offset)..<(Int(offset) + length)) }
            else if let source { plain = try Disk.exact(source, count: length) }
            else { plain = Data() }
            hasher.update(data: plain)
            let sealed = try VaultCrypto.seal(plain, key: fileKey, context: chunkContext(vault: m.vaultID, object: object, index: number, length: length, size: expectedSize, chunks: result.chunks))
            try output.write(contentsOf: Disk.uint32(UInt32(sealed.count))); try output.write(contentsOf: sealed)
            offset += UInt64(length)
            progress?(OperationProgress(fraction: expectedSize == 0 ? 0.5 : Double(offset) / Double(expectedSize) * 0.5, phase: "Шифрование"))
        }
        if let source, let trailing = try source.read(upToCount: 1), !trailing.isEmpty { throw HorizonError.message("Исходный файл изменился во время чтения.") }
        result.digest = Data(hasher.finalize())
        try output.synchronize(); try output.close()
        try consume(result, url: staging, vault: m.vaultID, key: key, token: token, progress: { fraction in
            progress?(OperationProgress(fraction: 0.5 + fraction * 0.5, phase: "Проверка сохранённой копии"))
        }, sink: { _ in })
        try token.check()
        let target = objectURL(object, at: activeURL)
        try Disk.replace(staging, target)
        do { try hooks.checkpoint(.afterObject) } catch { try? Disk.fm.removeItem(at: target); throw error }
        return result
    }
    private func consume(_ item: VaultItem, url: URL, vault: UUID, key: SymmetricKey, token: OperationToken,
                         progress: ((Double) -> Void)? = nil, sink: (Data) throws -> Void) throws {
        guard let object = item.object else { throw HorizonError.message("Нет содержимого файла.") }
        let input = try Disk.readHandle(url); defer { try? input.close() }
        guard try Disk.exact(input, count: 8) == Data("HZNOBJ01".utf8) else { throw HorizonError.message("Неподдерживаемый объект.") }
        let fileKey = VaultCrypto.subkey(key, vault: vault, purpose: "object." + object.uuidString)
        var hasher = SHA256(); var total: UInt64 = 0
        for number in 0..<item.chunks {
            try token.check()
            let length = Int(min(UInt64(Self.blockSize), item.size - total))
            let stored = try Disk.decode32(Disk.exact(input, count: 4))
            guard stored == length + 28 else { throw HorizonError.message("Повреждена длина блока.") }
            let combined = try Disk.exact(input, count: Int(stored))
            let plain: Data
            do { plain = try VaultCrypto.open(combined, key: fileKey, context: chunkContext(vault: vault, object: object, index: number, length: length, size: item.size, chunks: item.chunks)) }
            catch { throw HorizonError.message("Файл повреждён: проверка целостности не пройдена.") }
            guard plain.count == length else { throw HorizonError.message("Повреждена длина содержимого.") }
            hasher.update(data: plain); try sink(plain); total += UInt64(length)
            progress?(item.size == 0 ? 1 : Double(total) / Double(item.size))
        }
        guard total == item.size, Data(hasher.finalize()) == item.digest,
            (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw HorizonError.message("Файл повреждён или содержит лишние блоки.") }
    }
    private func removeUnreferenced(_ object: UUID?) {
        guard let object, manifest?.items.contains(where: { $0.object == object }) != true else { return }
        try? Disk.fm.removeItem(at: objectURL(object, at: activeURL))
    }
    private func requireExternalDestination(_ destination: URL) throws {
        let dataPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != dataPath, !path.hasPrefix(dataPath + "/") else {
            throw HorizonError.message("Сохраните копию вне папки данных Horizon.")
        }
    }
    public func importFile(_ url: URL, parent: UUID?, token: OperationToken, progress: ProgressHandler? = nil, placement: ImportPlacement? = nil) throws -> VaultItem {
        try token.check(); var m = try unlocked().1
        try Disk.regular(url)
        let values = try url.resourceValues(forKeys: [.isPackageKey])
        guard values.isPackage != true else { throw HorizonError.message("Пакеты macOS пока не поддерживаются.") }
        let input = try Disk.readHandle(url); defer { try? input.close() }
        var before = stat(); guard fstat(input.fileDescriptor, &before) == 0, before.st_size >= 0 else { throw HorizonError.message("Не удалось прочитать размер файла.") }
        var item = try newItem(name: url.lastPathComponent, kind: .file, parent: parent, m: m)
        if let placement { try place(&item, in: m, placement: placement) }
        item = try writeObject(item, data: nil, source: input, expectedSize: UInt64(before.st_size), token: token, progress: progress)
        do {
            try token.check()
            var after = stat(); var pathInfo = stat()
            guard fstat(input.fileDescriptor, &after) == 0, before.st_size == after.st_size,
                lstat(url.path, &pathInfo) == 0, before.st_dev == pathInfo.st_dev, before.st_ino == pathInfo.st_ino,
                before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw HorizonError.message("Исходный файл изменился во время загрузки. Попробуйте ещё раз.")
            }
            m.items.append(item); try commit(m); return item
        } catch { removeUnreferenced(item.object); throw error }
    }
    public func readPreview(_ id: UUID) throws -> Data? {
        let (key, m) = try unlocked()
        guard let item = m.items.first(where: { $0.id == id && !$0.isTrashed && !$0.isFolder }) else { throw HorizonError.message("Запись недоступна.") }
        guard item.size <= Self.previewLimit else { return nil }
        var output = Data()
        try consume(item, url: objectURL(item.object!, at: activeURL), vault: m.vaultID, key: key, token: OperationToken(), sink: { output.append($0) })
        return output
    }
    public func export(_ id: UUID, to destination: URL, token: OperationToken, progress: ProgressHandler? = nil) throws {
        try requireExternalDestination(destination)
        let (key, m) = try unlocked()
        guard let item = m.items.first(where: { $0.id == id && !$0.isFolder }) else { throw HorizonError.message("Запись не найдена.") }
        try Disk.requireDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".horizon-export-" + UUID().uuidString)
        defer { try? Disk.fm.removeItem(at: temporary) }
        let output = try Disk.newFile(temporary); defer { try? output.close() }
        try consume(item, url: objectURL(item.object!, at: activeURL), vault: m.vaultID, key: key, token: token,
            progress: { progress?(OperationProgress(fraction: $0, phase: "Экспорт")) }, sink: { try output.write(contentsOf: $0) })
        try output.synchronize(); try output.close(); try token.check()
        try Disk.replace(temporary, destination)
    }
    @discardableResult public func saveNote(_ draft: NoteDraft) throws -> VaultItem {
        var m = try unlocked().1
        guard let pos = m.items.firstIndex(where: { $0.id == draft.id && $0.isNote && !$0.isTrashed }) else { throw HorizonError.message("Заметка недоступна.") }
        let data = Data(draft.text.utf8)
        guard data.count <= Self.noteLimit else { throw HorizonError.message("Заметка превышает 1 МиБ. Сохраните материал как файл.") }
        let old = m.items[pos]; var item = old
        item.name = try uniqueName(draft.title, parent: old.parent, in: m, excluding: old.id); item.modified = Date()
        item = try writeObject(item, data: data, source: nil, expectedSize: UInt64(data.count), token: OperationToken(), progress: nil)
        m.items[pos] = item
        do { try commit(m) } catch { removeUnreferenced(item.object); throw error }
        removeUnreferenced(old.object)
        if retainedDraft?.store == state.active, retainedDraft?.note == draft.id { retainedDraft = nil }
        return item
    }
    public func rename(_ id: UUID, name: String) throws {
        var m = try unlocked().1
        guard let pos = m.items.firstIndex(where: { $0.id == id && !$0.isTrashed }) else { throw HorizonError.message("Запись недоступна.") }
        m.items[pos].name = try uniqueName(name, parent: m.items[pos].parent, in: m, excluding: id)
        m.items[pos].modified = Date(); try commit(m)
    }
    public func move(_ id: UUID, parent: UUID?) throws {
        var m = try unlocked().1; try checkParent(parent, in: m)
        guard let pos = m.items.firstIndex(where: { $0.id == id && !$0.isTrashed }) else { throw HorizonError.message("Запись недоступна.") }
        if m.items[pos].parent == parent { return }
        var p = parent
        while let current = p {
            guard current != id else { throw HorizonError.message("Нельзя переместить папку внутрь себя или её потомка.") }
            p = m.items.first(where: { $0.id == current })?.parent
        }
        let name = try uniqueName(m.items[pos].name, parent: parent, in: m, excluding: id)
        m.items[pos].parent = parent; m.items[pos].name = name; m.items[pos].modified = Date()
        m.items[pos].localPosition = try parent.map { target in
            try SpacePoint.available(near: nil, spacing: 56, occupied: m.items.filter { $0.parent == target && $0.id != id }.compactMap(\.localPosition))
        }
        try commit(m)
    }
    private func descendants(_ id: UUID, in m: Manifest) -> Set<UUID> {
        var ids: Set<UUID> = [id]; var grew = true
        while grew { let count = ids.count; for item in m.items { if let p = item.parent, ids.contains(p) { ids.insert(item.id) } }; grew = count != ids.count }
        return ids
    }
    public func trash(_ id: UUID, at date: Date = Date()) throws {
        var m = try unlocked().1
        guard m.items.contains(where: { $0.id == id && !$0.isTrashed }) else { throw HorizonError.message("Запись недоступна.") }
        let ids = descendants(id, in: m); let batch = UUID()
        for pos in m.items.indices where ids.contains(m.items[pos].id) && !m.items[pos].isTrashed {
            m.items[pos].trashedAt = date; m.items[pos].trashBatch = batch
        }
        try commit(m)
    }
    public func restoreItem(_ id: UUID) throws {
        var m = try unlocked().1
        guard let selected = m.items.first(where: { $0.id == id && $0.isTrashed }), let batch = selected.trashBatch else { throw HorizonError.message("Запись не найдена в Корзине.") }
        let restoring = m.items.filter { $0.trashBatch == batch }
        let ids = Set(restoring.map(\.id))
        // Resolve parent folders first, including subtrees restored from a deleted parent.
        var ordered = restoring
        ordered.sort { depth($0, in: m) < depth($1, in: m) }
        for item in ordered {
            guard let pos = m.items.firstIndex(where: { $0.id == item.id }) else { continue }
            var parent = item.parent
            if let p = parent, !ids.contains(p), !m.items.contains(where: { $0.id == p && !$0.isTrashed }) { parent = nil }
            m.items[pos].parent = parent
            if parent == nil { m.items[pos].localPosition = nil }
            m.items[pos].name = try uniqueName(item.name, parent: parent, in: m, excluding: item.id)
            m.items[pos].trashedAt = nil; m.items[pos].trashBatch = nil
        }
        try commit(m)
    }
    private func depth(_ item: VaultItem, in m: Manifest) -> Int {
        var depth = 0; var p = item.parent
        while let id = p { depth += 1; p = m.items.first(where: { $0.id == id })?.parent }
        return depth
    }
    public func permanentlyDelete(_ id: UUID?) throws {
        var m = try unlocked().1
        let ids: Set<UUID>
        if let id {
            guard m.items.contains(where: { $0.id == id && $0.isTrashed }) else { throw HorizonError.message("Запись не находится в Корзине.") }
            ids = descendants(id, in: m)
        } else { ids = Set(m.items.filter(\.isTrashed).map(\.id)) }
        let objects = m.items.filter { ids.contains($0.id) }.compactMap(\.object)
        m.items.removeAll { ids.contains($0.id) }; try commit(m)
        for object in objects { removeUnreferenced(object) }
    }
    private func expireTrash() throws {
        guard var m = manifest else { return }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        var ids = Set<UUID>()
        for item in m.items where (item.trashedAt ?? .distantFuture) <= cutoff { ids.formUnion(descendants(item.id, in: m)) }
        if ids.isEmpty { return }
        let objects = m.items.filter { ids.contains($0.id) }.compactMap(\.object)
        m.items.removeAll { ids.contains($0.id) }; try commit(m)
        for object in objects { removeUnreferenced(object) }
    }
    private func cleanOrphans() throws {
        let m = try unlocked().1
        let staging = activeURL.appendingPathComponent("staging"); try Disk.directory(staging)
        for url in try Disk.fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) { try? Disk.fm.removeItem(at: url) }
        let keep = Set(m.items.compactMap(\.object).map { $0.uuidString + ".hzn" })
        for url in try Disk.fm.contentsOfDirectory(at: activeURL.appendingPathComponent("objects"), includingPropertiesForKeys: nil) where !keep.contains(url.lastPathComponent) { try? Disk.fm.removeItem(at: url) }
    }
    public func backup(to destination: URL, token: OperationToken, progress: ProgressHandler? = nil) throws {
        try requireExternalDestination(destination)
        let (_, m) = try unlocked()
        guard !Disk.fm.fileExists(atPath: destination.path) else { throw HorizonError.message("Копия с таким именем уже существует. Выберите новое имя.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".horizon-backup-" + UUID().uuidString)
        defer { try? Disk.fm.removeItem(at: temporary) }
        try Disk.directory(temporary.appendingPathComponent("objects"))
        try Disk.copy(activeURL.appendingPathComponent("header.json"), temporary.appendingPathComponent("header.json"), token: token)
        try Disk.copy(activeURL.appendingPathComponent("manifest.hzn"), temporary.appendingPathComponent("manifest.hzn"), token: token)
        let objects = m.items.compactMap(\.object)
        for (pos, object) in objects.enumerated() {
            try Disk.copy(objectURL(object, at: activeURL), objectURL(object, at: temporary), token: token)
            progress?(OperationProgress(fraction: Double(pos + 1) / Double(max(1, objects.count)), phase: "Резервная копия"))
        }
        Disk.syncDirectory(temporary.appendingPathComponent("objects")); Disk.syncDirectory(temporary)
        try token.check(); try Disk.moveExclusive(temporary, destination)
        var next = state; next.lastBackup = Date()
        try Disk.atomic(encoder.encode(next), to: stateURL); state = next
    }
    public func restoreBackup(from source: URL, password: String?, recovery: String? = nil, newPassword: String? = nil,
                              token: OperationToken, progress: ProgressHandler? = nil) throws {
        guard master == nil else { throw HorizonError.message("Перед восстановлением закройте пространство.") }
        guard retainedDraft == nil else { throw HorizonError.message("Сначала откройте текущее пространство и сохраните несохранённый черновик.") }
        var h = try header(at: source)
        let key: SymmetricKey
        if let recovery, let newPassword {
            try VaultCrypto.validatePassword(newPassword)
            key = try masterKey(header: h, recovery: recovery)
            h.salt = try VaultCrypto.random(32)
            h.passwordWrap = try VaultCrypto.seal(key.withUnsafeBytes { Data($0) }, key: VaultCrypto.passwordKey(newPassword, header: h), context: wrapContext(h.vaultID, "password"))
        } else if let password { key = try masterKey(header: h, password: password) }
        else { throw HorizonError.message("Введите пароль резервной копии.") }
        let m = upgraded(try readManifest(at: source, h: h, key: key))
        let id = UUID(); let target = store(id)
        do {
            try Disk.directory(target.appendingPathComponent("objects")); try Disk.directory(target.appendingPathComponent("staging"))
            let files = m.items.filter { !$0.isFolder }
            for (pos, item) in files.enumerated() {
                let url = objectURL(item.object!, at: target)
                try Disk.copy(objectURL(item.object!, at: source), url, token: token)
                try consume(item, url: url, vault: m.vaultID, key: key, token: token, sink: { _ in })
                progress?(OperationProgress(fraction: Double(pos + 1) / Double(max(1, files.count)), phase: "Проверка резервной копии"))
            }
            try validate(m, at: target); try writeManifest(m, at: target, key: key)
            try Disk.atomic(encoder.encode(h), to: target.appendingPathComponent("header.json"))
            _ = try readManifest(at: target, h: h, key: key)
            Disk.syncDirectory(target.appendingPathComponent("objects")); Disk.syncDirectory(target); Disk.syncDirectory(stores)
            try token.check(); try activate(id, token: token)
            master = key; manifest = m
            try expireTrash()
        } catch { if state.active != id { try? Disk.fm.removeItem(at: target) }; throw error }
    }
    public func removePreviousCopies() throws {
        _ = try unlocked()
        var next = state; next.previous = []
        try Disk.atomic(encoder.encode(next), to: stateURL)
        let old = state.previous; state = next
        for id in old { try? Disk.fm.removeItem(at: store(id)) }
    }
}
