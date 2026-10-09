import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HorizonCore

enum SessionPhase { case boot, locked, recoveryKey, opening, unlocked, locking }
enum Section: String, CaseIterable { case all = "Space", notes = "Заметки", folders = "Папки", trash = "Корзина" }
enum SortOrder: String, Codable, CaseIterable { case name = "Название", date = "Дата изменения", size = "Размер" }
// Decoding ignores the old mode field, preserving the remaining preferences.
struct Preferences: Codable { var idleMinutes = 5; var textScale = 1.0; var animationsEnabled = true }
enum EditAction: Identifiable {
    case folder, note, rename(VaultItem), move(VaultItem), settings, password, recovery, restore(URL)
    var id: String { switch self { case .folder: "folder"; case .note: "note"; case .rename: "rename"; case .move: "move"; case .settings: "settings"; case .password: "password"; case .recovery: "recovery"; case .restore: "restore" } }
}

struct SpaceImportDestination {
    let sessionID: UUID
    let folder: UUID?
    let point: SpacePoint?
    let spacing: Double
}
struct SpaceBirth: Identifiable, Equatable {
    let id = UUID()
    let itemID: UUID
    let folder: UUID?
    let point: SpacePoint
    let sessionID: UUID
}

@MainActor final class AppModel: ObservableObject {
    @Published var phase: SessionPhase = .boot
    @Published var exists = false
    @Published var items: [VaultItem] = []
    @Published var section: Section = .all
    @Published var folder: UUID?
    @Published var search = ""
    @Published var sort: SortOrder = .name
    @Published var preferences = Preferences() { didSet { savePreferences() } }
    @Published var error: String?
    @Published var banner: String?
    @Published var busy = false
    @Published var progress: OperationProgress?
    @Published var operationName = ""
    @Published var recoveryCode = ""
    @Published var acknowledgedRecovery = false
    @Published var edit: EditAction?
    @Published var preview: VaultItem?
    @Published var previewData: Data?
    @Published var previewLoading = false
    @Published var noteTitle = ""
    @Published var noteText = ""
    @Published var noteStatus = "Сохранено"
    @Published var dirtyNote = false
    @Published var lastBackup: Date?
    @Published var previousCount = 0
    @Published var hasRetainedDraft = false
    @Published var absorbed = 0
    @Published var lastAdded: UUID?
    @Published var births: [SpaceBirth] = []
    @Published var layoutSaving = false
    @Published var layoutStatus = ""
    private(set) var service: VaultService?
    @Published private(set) var root: URL
    let personalRoot: URL
    let testRoot: URL
    var isTestSpace: Bool { root.standardizedFileURL == testRoot.standardizedFileURL }
    private var generation = UUID()
    private var token: OperationToken?
    private var lastActivity = Date()
    private var autoSave: Task<Void, Never>?
    private var noteRevision = 0
    private var savedNoteTitle = ""
    private var savedNoteText = ""
    private var monitor: Any?
    private var timer: Timer?
    private var startupError: String?
    var sessionID: UUID { generation }

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        personalRoot = support.appendingPathComponent("Horizon", isDirectory: true)
        let projectDemo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/ui-vault", isDirectory: true)
        testRoot = FileManager.default.fileExists(atPath: projectDemo.appendingPathComponent("state.json").path) ? projectDemo : support.appendingPathComponent("Horizon Demo", isDirectory: true)
        if let index = arguments.firstIndex(of: "--vault-root"), arguments.count > index + 1 {
            root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            root = UserDefaults.standard.bool(forKey: "UseTestSpace") ? testRoot : personalRoot
        }
        do { service = try VaultService(root: root) } catch { service = nil; startupError = error.localizedDescription }
        if let data = try? Data(contentsOf: root.appendingPathComponent("preferences.json")), let prefs = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = prefs
            if ![1, 5, 15, 30].contains(preferences.idleMinutes) { preferences.idleMinutes = 5 }
            preferences.textScale = min(1.25, max(0.9, preferences.textScale))
        }
    }
    func start() async {
        guard phase == .boot else { return }
        if let startupError { error = startupError; phase = .locked; return }
        if isTestSpace, let service {
            do {
                try await prepareTestSpace(service)
                UserDefaults.standard.set(true, forKey: "UseTestSpace")
            }
            catch { self.error = error.localizedDescription; phase = .locked; return }
        }
        await refreshStatus(); phase = .locked
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.touch() }; return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .unlocked, Date().timeIntervalSince(self.lastActivity) >= Double(self.preferences.idleMinutes * 60) else { return }
                await self.lock()
            }
        }
    }
    private func prepareTestSpace(_ service: VaultService) async throws {
        guard !(await service.status()).exists else { return }
        _ = try await service.create(password: "horizon demo password")
        try await service.acknowledgeRecoveryKey()
        _ = try await service.createNote(name: "Добро пожаловать в тестовый Space", parent: nil)
        _ = await service.lock()
    }
    func switchSpace(test: Bool) async {
        guard !busy && !layoutSaving, phase == .locked || phase == .recoveryKey else { return }
        let destination = test ? testRoot : personalRoot
        if root.standardizedFileURL == destination.standardizedFileURL {
            UserDefaults.standard.set(test, forKey: "UseTestSpace"); return
        }
        do {
            let next = try VaultService(root: destination)
            if test { try await prepareTestSpace(next) }
            await lock()
            service = next; root = destination
            UserDefaults.standard.set(test, forKey: "UseTestSpace")
            await refreshStatus(); touch()
        } catch { report(error) }
    }
    func touch() { lastActivity = Date() }
    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        try? data.write(to: root.appendingPathComponent("preferences.json"), options: .atomic)
    }
    func refreshStatus() async {
        guard let service else { return }
        let status = await service.status()
        exists = status.exists; lastBackup = status.lastBackup; previousCount = status.previousCount; hasRetainedDraft = status.hasDraft
    }
    func refreshItems() async {
        guard let service, phase == .unlocked else { return }
        let stamp = generation
        do { let value = try await service.items(); if generation == stamp, phase == .unlocked { items = value } }
        catch { if generation == stamp { self.error = error.localizedDescription } }
    }
    func authenticate(password: String, confirmation: String) async {
        guard let service, !busy && !layoutSaving, phase == .locked else { return }
        if !exists && password != confirmation { error = "Пароли не совпадают."; return }
        busy = true; let stamp = generation; let operation = OperationToken(); token = operation
        do {
            if exists { try await service.unlock(password: password, token: operation, progress: progressHandler(stamp)) }
            else {
                let code = try await service.create(password: password)
                guard stamp == generation else { _ = await service.lock(); return }
                recoveryCode = code; acknowledgedRecovery = false; phase = .recoveryKey; exists = true; busy = false; token = nil; progress = nil; return
            }
            guard stamp == generation else { _ = await service.lock(); return }
            busy = false; token = nil; progress = nil; await reveal()
        } catch { if stamp == generation { report(error); busy = false; token = nil; progress = nil; await refreshStatus() } }
    }
    func finishRecovery() async {
        guard acknowledgedRecovery, let service, !busy && !layoutSaving else { return }
        let stamp = generation; busy = true
        do {
            try await service.acknowledgeRecoveryKey()
            guard stamp == generation else { return }
            recoveryCode = ""; busy = false; await reveal()
        } catch { if stamp == generation { busy = false; report(error) } }
    }
    private func reveal() async {
        let stamp = generation
        if let service {
            do {
                if let code = try await service.pendingRecoveryKey() {
                    guard stamp == generation else { return }
                    recoveryCode = code; acknowledgedRecovery = false; phase = .recoveryKey; return
                }
            } catch { report(error); return }
        }
        phase = .opening
        if preferences.animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try? await Task.sleep(for: .milliseconds(850))
        }
        guard stamp == generation, phase == .opening else { return }
        phase = .unlocked; touch(); await refreshItems(); await refreshStatus()
        if let service {
            do {
                if let draft = try await service.pendingDraft(), let item = items.first(where: { $0.id == draft.id }) {
                    preview = item; previewData = Data(draft.text.utf8); noteTitle = draft.title; noteText = draft.text
                    savedNoteTitle = item.name; savedNoteText = ""
                    dirtyNote = true; noteStatus = "Есть несохранённый черновик"; banner = "Черновик восстановлен из памяти. Сохраните его."
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func lock() async {
        guard phase != .locking else { return }
        let draft = currentDraft
        generation = UUID(); token?.cancel(); token = nil; autoSave?.cancel(); autoSave = nil
        phase = .locking
        births = []; layoutSaving = false; layoutStatus = ""
        items = []; preview = nil; previewData = nil; noteTitle = ""; noteText = ""; dirtyNote = false
        savedNoteTitle = ""; savedNoteText = ""
        edit = nil; search = ""; folder = nil; section = .all; recoveryCode = ""; banner = nil; error = nil; lastAdded = nil
        operationName = ""; progress = nil; busy = false
        if let service { hasRetainedDraft = await service.lock(draft: draft) }
        phase = .locked; await refreshStatus()
    }
    var currentDraft: NoteDraft? {
        guard dirtyNote, let preview, preview.isNote else { return nil }
        return NoteDraft(id: preview.id, title: noteTitle, text: noteText)
    }
    var filtered: [VaultItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = items.filter { item in
            guard section == .trash ? item.isTrashed : !item.isTrashed else { return false }
            if !query.isEmpty { return item.name.localizedCaseInsensitiveContains(query) }
            switch section {
            case .notes: return item.isNote
            case .folders: return item.isFolder && item.parent == nil
            case .trash:
                return !items.contains { $0.id == item.parent && $0.isTrashed && $0.trashBatch == item.trashBatch }
            case .all: return folder == nil || item.parent == folder
            }
        }
        result.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: return a.modified > b.modified
            case .size: return a.size > b.size
            }
        }
        return result
    }
    var breadcrumbs: [VaultItem] {
        var result: [VaultItem] = []; var p = folder
        while let id = p, let item = items.first(where: { $0.id == id }) { result.insert(item, at: 0); p = item.parent }
        return result
    }
    var heading: String { if !search.isEmpty { return "Результаты поиска" }; return folder.flatMap { id in items.first { $0.id == id }?.name } ?? section.rawValue }
    func select(_ section: Section) { touch(); self.section = section; folder = nil; search = "" }
    func navigate(_ id: UUID?) { touch(); section = .all; folder = id; search = "" }
    @discardableResult func navigateUp() -> Bool {
        guard phase == .unlocked, edit == nil, preview == nil, error == nil,
              section == .all, let folder else { return false }
        navigate(items.first { $0.id == folder }?.parent)
        return true
    }
    func report(_ error: Error) { if !(error is CancellationError) { self.error = error.localizedDescription } }
    private func progressHandler(_ stamp: UUID) -> ProgressHandler {
        { [weak self] progress in Task { @MainActor in if let self, self.generation == stamp { self.progress = progress } } }
    }
    func chooseFiles() {
        guard phase == .unlocked, !busy && !layoutSaving else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"; panel.message = "Оригиналы останутся на компьютере."
        if panel.runModal() == .OK { let urls = panel.urls; Task { await importFiles(urls) } }; touch()
    }
    var mapFolder: UUID? {
        section == .all && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? folder : nil
    }
    func saveSpacePositions(_ changes: [UUID: CGPoint], folder: UUID?) async {
        guard let service, phase == .unlocked, !busy, !layoutSaving else { return }
        let stamp = generation; layoutSaving = true; layoutStatus = "Сохраняется расположение…"
        let values = changes.mapValues { SpacePoint(x: $0.x, y: $0.y) }
        do {
            try await service.setSpacePositions(values, folder: folder)
            guard stamp == generation else { return }
            await refreshItems(); guard stamp == generation, phase == .unlocked else { return }
            layoutSaving = false; layoutStatus = "Расположение сохранено"
        } catch {
            guard stamp == generation else { return }
            await refreshItems(); guard stamp == generation, phase == .unlocked else { return }
            layoutSaving = false; layoutStatus = "Ошибка сохранения расположения"; report(error)
        }
    }
    func importFiles(_ urls: [URL], destination: SpaceImportDestination? = nil) async {
        guard let service, phase == .unlocked, !busy, !layoutSaving else { return }
        let target = destination ?? SpaceImportDestination(sessionID: generation, folder: mapFolder, point: nil, spacing: 56)
        guard target.sessionID == generation else { return }
        let stamp = generation; let operation = OperationToken(); token = operation; busy = true
        let parent = target.folder
        if mapFolder == parent { section = .all; folder = parent; search = "" }
        touch()
        var successes = 0; var failures: [String] = []
        for url in urls {
            guard stamp == generation else { break }
            operationName = url.lastPathComponent
            let access = url.startAccessingSecurityScopedResource()
            do {
                let placement = target.point.map { ImportPlacement(point: $0, spacing: target.spacing) }
                let item = try await service.importFile(url, parent: parent, token: operation, progress: progressHandler(stamp), placement: placement)
                if stamp == generation {
                    successes += 1; await refreshItems()
                    guard stamp == generation, phase == .unlocked else {
                        if access { url.stopAccessingSecurityScopedResource() }; return
                    }
                    if let point = parent == nil ? item.rootPosition : item.localPosition {
                        births.append(SpaceBirth(itemID: item.id, folder: parent, point: point, sessionID: stamp))
                        if births.count > 32 { births.removeFirst(births.count - 32) }
                    }
                }
            } catch {
                if access { url.stopAccessingSecurityScopedResource() }
                if stamp == generation { await refreshItems() }
                if error is CancellationError { break }
                failures.append(url.lastPathComponent + ": " + error.localizedDescription)
                continue
            }
            if access { url.stopAccessingSecurityScopedResource() }
        }
        guard stamp == generation else { return }
        busy = false; token = nil; progress = nil; operationName = ""
        banner = successes > 0 ? "Сохранено: \(successes). Оригиналы остались на компьютере." : "Загрузка завершена без новых файлов."
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    func cancelOperation() { token?.cancel() }
    func open(_ item: VaultItem) async {
        touch()
        if item.isFolder { navigate(item.id); return }
        guard let service, phase == .unlocked, !item.isTrashed else { return }
        if preview != nil { await closePreview(); if preview != nil { return } }
        let stamp = generation
        preview = item; previewData = nil; previewLoading = true; noteStatus = "Сохранено"; dirtyNote = false
        do {
            let data = try await service.readPreview(item.id)
            guard generation == stamp, preview?.id == item.id else { return }
            previewData = data; previewLoading = false
            if item.isNote {
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                savedNoteTitle = item.name; savedNoteText = text; noteTitle = item.name; noteText = text
            }
        } catch { if stamp == generation { preview = nil; previewLoading = false; report(error) } }
    }
    func noteChanged() {
        touch(); guard preview?.isNote == true, noteTitle != savedNoteTitle || noteText != savedNoteText else { return }
        dirtyNote = true; noteRevision += 1; noteStatus = "Сохраняется…"; autoSave?.cancel()
        autoSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)); try Task.checkCancellation() }
            catch { return }
            await self?.saveCurrentNote()
        }
    }
    func saveCurrentNote() async {
        guard let service, phase == .unlocked, let draft = currentDraft else { return }
        let stamp = generation; let revision = noteRevision
        do {
            let item = try await service.saveNote(draft)
            guard stamp == generation, preview?.id == draft.id else { return }
            if revision == noteRevision {
                savedNoteTitle = item.name; savedNoteText = draft.text; noteTitle = item.name
                dirtyNote = false; noteStatus = "Сохранено"; preview = item
            }
            await refreshItems(); await refreshStatus()
        } catch { if stamp == generation { noteStatus = "Ошибка сохранения"; report(error) } }
    }
    func closePreview() async {
        autoSave?.cancel(); await saveCurrentNote()
        guard !dirtyNote else { return }
        preview = nil; previewData = nil; noteTitle = ""; noteText = ""; savedNoteTitle = ""; savedNoteText = ""
    }
    func perform(_ operation: @escaping @Sendable (VaultService) async throws -> Void) async {
        guard let service, phase == .unlocked, !busy && !layoutSaving else { return }
        let stamp = generation; busy = true
        do { try await operation(service) } catch { if stamp == generation { report(error) } }
        if stamp == generation { busy = false; await refreshItems(); await refreshStatus() }
    }
    func create(kind: ItemKind, name: String) async {
        guard let service, phase == .unlocked, !busy && !layoutSaving else { return }
        let stamp = generation; busy = true
        do {
            let item: VaultItem
            if kind == .folder { item = try await service.createFolder(name: name, parent: folder) }
            else { item = try await service.createNote(name: name, parent: folder) }
            guard stamp == generation else { return }
            busy = false; edit = nil; section = .all; search = ""; await refreshItems(); lastAdded = item.id
            if kind == .note { await open(item) }
        } catch { if stamp == generation { busy = false; report(error) } }
    }
    func rename(_ item: VaultItem, name: String) async { await perform { try await $0.rename(item.id, name: name) }; if error == nil { edit = nil } }
    func move(_ item: VaultItem, parent: UUID?) async { await perform { try await $0.move(item.id, parent: parent) }; if error == nil { edit = nil } }
    func trash(_ item: VaultItem) async { await perform { try await $0.trash(item.id) } }
    func restore(_ item: VaultItem) async { await perform { try await $0.restoreItem(item.id) } }
    func deleteForever(_ item: VaultItem?) async {
        let alert = NSAlert(); alert.messageText = item == nil ? "Очистить Корзину?" : "Удалить окончательно?"
        alert.informativeText = "Восстановить запись внутри Horizon после этого не получится. Резервные копии могут её содержать."
        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Удалить")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        await perform { try await $0.permanentlyDelete(item?.id) }
    }
    func export(_ item: VaultItem) async {
        guard let service, phase == .unlocked, !busy && !layoutSaving else { return }
        if item.isNote, preview?.id == item.id { await saveCurrentNote(); if dirtyNote { return } }
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.name.replacingOccurrences(of: ":", with: "-") + (item.isNote ? ".txt" : "")
        panel.message = "Сохранённая копия будет доступна вне Horizon."; panel.prompt = "Сохранить копию"
        guard panel.runModal() == .OK, let url = panel.url else { touch(); return }
        let stamp = generation; let operation = OperationToken(); token = operation; busy = true; operationName = "Экспорт"
        do { try await service.export(item.id, to: url, token: operation, progress: progressHandler(stamp)); if stamp == generation { banner = "Копия сохранена вне Horizon." } }
        catch { if stamp == generation { report(error) } }
        if stamp == generation { busy = false; progress = nil; token = nil; operationName = "" }
    }
    func backup() async {
        guard let service, phase == .unlocked, !busy && !layoutSaving else { return }
        await saveCurrentNote(); if dirtyNote { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Horizon_" + formatter.string(from: Date()) + ".horizonbackup"
        panel.message = "Резервная копия остаётся зашифрованной."; panel.prompt = "Создать копию"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let stamp = generation; let operation = OperationToken(); token = operation; busy = true; operationName = "Резервная копия"
        do { try await service.backup(to: url, token: operation, progress: progressHandler(stamp)); if stamp == generation { banner = "Зашифрованная резервная копия создана." } }
        catch { if stamp == generation { report(error) } }
        if stamp == generation { busy = false; token = nil; progress = nil; operationName = ""; await refreshStatus() }
    }
    func chooseBackup() {
        guard phase == .locked, !busy && !layoutSaving else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = false
        panel.message = "Выберите пакет .horizonbackup. Текущее хранилище будет сохранено отдельно."
        if panel.runModal() == .OK, let url = panel.url { edit = .restore(url) }
    }
    func recover(code: String, password: String, confirm: String) async {
        guard let service, phase == .locked, !busy && !layoutSaving else { return }
        guard password == confirm else { error = "Пароли не совпадают."; return }
        let stamp = generation; busy = true; let operation = OperationToken(); token = operation
        do { try await service.recover(code: code, newPassword: password, token: operation, progress: progressHandler(stamp)); guard stamp == generation else { return }; edit = nil; busy = false; token = nil; progress = nil; await reveal() }
        catch { if stamp == generation { busy = false; token = nil; progress = nil; report(error) } }
    }
    func restoreBackup(url: URL, password: String, code: String?, newPassword: String, confirm: String) async {
        guard let service, phase == .locked, !busy && !layoutSaving else { return }
        if code != nil && newPassword != confirm { error = "Пароли не совпадают."; return }
        let stamp = generation; let operation = OperationToken(); token = operation; busy = true; operationName = "Восстановление"
        do {
            try await service.restoreBackup(from: url, password: code == nil ? password : nil, recovery: code, newPassword: code == nil ? nil : newPassword,
                token: operation, progress: progressHandler(stamp))
            guard stamp == generation else { return }
            edit = nil; busy = false; token = nil; progress = nil; operationName = ""; await refreshStatus(); await reveal()
        } catch { if stamp == generation { busy = false; token = nil; progress = nil; operationName = ""; report(error) } }
    }
    func changePassword(old: String, new: String, confirm: String) async {
        guard new == confirm else { error = "Пароли не совпадают."; return }
        await perform { try await $0.changePassword(current: old, new: new) }
        if error == nil { edit = nil; banner = "Пароль изменён. Старые резервные копии используют прежний пароль." }
    }
    func saveRecoveryKey() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Horizon — ключ восстановления.txt"
        panel.message = "Этот ключ открывает ваше хранилище. Сохраните его отдельно от Horizon."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let dataPath = root.resolvingSymlinksInPath().standardizedFileURL.path
                let destination = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard destination != dataPath, !destination.hasPrefix(dataPath + "/") else { throw HorizonError.message("Сохраните ключ отдельно, вне папки данных Horizon.") }
                try Data(("Horizon — ключ восстановления\n\n" + recoveryCode + "\n\nХраните отдельно. Этот ключ открывает хранилище.\n").utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { report(error) }
        }
    }
}
