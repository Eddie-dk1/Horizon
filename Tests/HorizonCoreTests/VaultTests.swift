import Foundation
import CryptoKit
@testable import HorizonCore

final class FaultSwitch: @unchecked Sendable {
    private let mutex = NSLock()
    private var point: CommitPoint?
    func set(_ value: CommitPoint?) { mutex.lock(); point = value; mutex.unlock() }
    func hit(_ value: CommitPoint) throws {
        mutex.lock(); let fail = point == value; mutex.unlock()
        if fail { throw HorizonError.message("Simulated disk failure") }
    }
}

@MainActor final class VaultTests {
    private var roots: [URL] = []
    deinit { for root in roots { try? FileManager.default.removeItem(at: root) } }
    let password = "a strong password 2026"
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("horizon-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
    func fixture(_ data: Data, name: String = "личный документ.txt", at directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name); try data.write(to: url); return url
    }
    func allFiles(_ root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        return enumerator.compactMap { $0 as? URL }
    }
    func activeStore(_ root: URL) throws -> URL {
        let state = try JSONDecoder().decode(StoreState.self, from: Data(contentsOf: root.appendingPathComponent("state.json")))
        return root.appendingPathComponent("vaults").appendingPathComponent(state.active!.uuidString)
    }
    func rejects(_ block: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await block(); CheckContext.fail("Expected failure", file: file, line: line) } catch {}
    }
    private func rewriteLegacy(_ root: URL, password: String) throws {
        let store = try activeStore(root)
        let h = try JSONDecoder().decode(Header.self, from: Data(contentsOf: store.appendingPathComponent("header.json")))
        let key = SymmetricKey(data: try VaultCrypto.open(h.passwordWrap, key: VaultCrypto.passwordKey(password, header: h), context: "Horizon.v1.password|" + h.vaultID.uuidString))
        let manifestKey = VaultCrypto.subkey(key, vault: h.vaultID, purpose: "manifest")
        let url = store.appendingPathComponent("manifest.hzn")
        var m = try JSONDecoder().decode(Manifest.self, from: VaultCrypto.open(Data(contentsOf: url), key: manifestKey, context: "Horizon.v1.manifest|" + h.vaultID.uuidString))
        m.version = 1
        for index in m.items.indices { m.items[index].rootPosition = nil; m.items[index].localPosition = nil }
        try Disk.atomic(VaultCrypto.seal(JSONEncoder().encode(m), key: manifestKey, context: "Horizon.v1.manifest|" + h.vaultID.uuidString), to: url)
    }
    func testSpacePersistencePlacementAndFailures() async throws {
        let root = try directory(); let faults = FaultSwitch()
        let data = root.appendingPathComponent("data")
        var service: VaultService? = try VaultService(root: data, hooks: StorageHooks(checkpoint: faults.hit))
        _ = try await service!.create(password: password); try await service!.acknowledgeRecoveryKey()
        let folder = try await service!.createFolder(name: "Galaxy", parent: nil)
        let nested = try await service!.createFolder(name: "Nested", parent: folder.id)
        let file = try await service!.importFile(fixture(Data("saved content".utf8), at: root), parent: nested.id, token: OperationToken(),
            placement: ImportPlacement(point: SpacePoint(x: 300, y: 120)))
        expectEqual(file.localPosition, SpacePoint(x: 300, y: 120))
        let initial = try await service!.items()
        let moved = SpacePoint(x: 421, y: -213)
        try await service!.setSpacePositions([file.id: moved, folder.id: SpacePoint(x: 500, y: 200)], folder: nil)
        try await service!.setSpacePositions([file.id: SpacePoint(x: -260, y: 85)], folder: nested.id)
        let updated = try await service!.items(); let updatedFile = updated.first { $0.id == file.id }!
        expectEqual(updatedFile.rootPosition, moved); expectEqual(updatedFile.localPosition, SpacePoint(x: -260, y: 85))
        expectEqual(updatedFile.modified, file.modified); expectEqual(updatedFile.object, file.object); expectEqual(updatedFile.digest, file.digest)
        await rejects { try await service!.setSpacePositions([file.id: SpacePoint(x: .infinity, y: 1)], folder: nil) }
        await rejects { try await service!.setSpacePositions([file.id: moved], folder: folder.id) }
        // Invalid batches must not partially apply earlier valid members.
        await rejects { try await service!.setSpacePositions([folder.id: moved, UUID(): moved], folder: nil) }
        expectEqual(try await service!.items(), updated)
        faults.set(.beforeManifest)
        await rejects { try await service!.setSpacePositions([file.id: SpacePoint(x: 999, y: 500)], folder: nil) }
        expectEqual(try await service!.items(), updated)
        faults.set(.afterManifest)
        await rejects { try await service!.setSpacePositions([file.id: SpacePoint(x: 700, y: 500)], folder: nil) }
        expectEqual(try await service!.items().first { $0.id == file.id }?.rootPosition, SpacePoint(x: 700, y: 500))
        faults.set(nil)
        _ = await service!.lock(); try await service!.unlock(password: password)
        expectEqual(try await service!.items().first { $0.id == file.id }?.localPosition, updatedFile.localPosition)
        let backup = root.appendingPathComponent("space.horizonbackup"); try await service!.backup(to: backup, token: OperationToken())
        let restored = try VaultService(root: root.appendingPathComponent("restored"))
        try await restored.restoreBackup(from: backup, password: password, token: OperationToken())
        expectEqual(try await restored.items(), try await service!.items())
        try await service!.trash(folder.id); try await service!.restoreItem(folder.id)
        expectEqual(try await service!.items().first { $0.id == file.id }?.localPosition, updatedFile.localPosition)
        try await service!.move(file.id, parent: folder.id)
        let relocated = try await service!.items().first { $0.id == file.id }!
        expectEqual(relocated.rootPosition, SpacePoint(x: 700, y: 500)); expectTrue(relocated.localPosition != updatedFile.localPosition)
        try await service!.move(file.id, parent: nil)
        expectEqual(try await service!.items().first { $0.id == file.id }?.localPosition, nil)
        _ = await service!.lock(); service = nil
        let reopened = try VaultService(root: data); try await reopened.unlock(password: password)
        expectEqual(try await reopened.items().first { $0.id == file.id }?.rootPosition, SpacePoint(x: 700, y: 500))
        expectTrue(initial.first { $0.id == file.id }?.rootPosition != moved)
        // Multiple files placed at one drop location must get distinct positions.
        let source = try fixture(Data(), name: "empty", at: root)
        let a = try await reopened.importFile(source, parent: nil, token: OperationToken(), placement: ImportPlacement(point: moved))
        let b = try await reopened.importFile(source, parent: nil, token: OperationToken(), placement: ImportPlacement(point: moved))
        expectTrue(a.rootPosition != b.rootPosition)
    }
    func testLegacySpaceMigrationAndBackup() async throws {
        let root = try directory(); let data = root.appendingPathComponent("data"); let faults = FaultSwitch()
        let service = try VaultService(root: data, hooks: StorageHooks(checkpoint: faults.hit))
        _ = try await service.create(password: password); try await service.acknowledgeRecoveryKey()
        let folder = try await service.createFolder(name: "Galaxy", parent: nil)
        let file = try await service.importFile(fixture(Data("legacy".utf8), at: root), parent: folder.id, token: OperationToken())
        _ = await service.lock(); try rewriteLegacy(data, password: password)
        let original = try activeStore(data)
        for boundary in [CommitPoint.beforeManifest, .afterManifest, .beforeActivation] {
            faults.set(boundary)
            await rejects { try await service.unlock(password: password) }
            expectEqual(try activeStore(data), original)
        }
        let cancelled = OperationToken(); cancelled.cancel(); faults.set(nil)
        await rejects { try await service.unlock(password: password, token: cancelled) }
        expectEqual(try activeStore(data), original)
        try await service.unlock(password: password)
        expectTrue(try activeStore(data) != original); expectTrue(FileManager.default.fileExists(atPath: original.path))
        expectEqual(await service.status().previousCount, 1)
        let migrated = try await service.items()
        expectTrue(migrated.allSatisfy { $0.rootPosition != nil && ($0.parent == nil || $0.localPosition != nil) })
        expectEqual(try await service.readPreview(file.id), Data("legacy".utf8))
        // A legacy backup can be opened in a new prepared store without changing its source.
        let backup = root.appendingPathComponent("legacy.horizonbackup")
        try FileManager.default.copyItem(at: original, to: backup)
        let restored = try VaultService(root: root.appendingPathComponent("restored"))
        try await restored.restoreBackup(from: backup, password: password, token: OperationToken())
        expectEqual(try await restored.items(), migrated)
        expectEqual(try await restored.readPreview(file.id), Data("legacy".utf8))
    }
    func testStandardCryptoVectors() throws {
        let key = try VaultCrypto.pbkdf(Data("password".utf8), salt: Data("salt".utf8), rounds: 1)
        expectEqual(key.map { String(format: "%02x", $0) }.joined(), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let box = try AES.GCM.seal(Data(), using: SymmetricKey(data: Data(repeating: 0, count: 32)), nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 12)))
        expectEqual(box.tag.map { String(format: "%02x", $0) }.joined(), "530f8afbc74536b9a963b4f1c4cb738b")
        let ikm = SymmetricKey(data: Data(repeating: 0x0b, count: 22))
        let hkdf = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data(0x00...0x0c), info: Data(0xf0...0xf9), outputByteCount: 42)
        expectEqual(hkdf.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }, "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }
    func testPasswordsNormalizationRecoveryAndBackupOldPassword() async throws {
        let root = try directory(); let service = try VaultService(root: root.appendingPathComponent("data"))
        let original = "  паро\u{0301}ль очень длинный  "
        let recovery = try await service.create(password: original)
        _ = await service.lock()
        await rejects { try await service.unlock(password: original.trimmingCharacters(in: .whitespaces)) }
        try await service.unlock(password: original.precomposedStringWithCanonicalMapping)
        let backup = root.appendingPathComponent("old.horizonbackup"); try await service.backup(to: backup, token: OperationToken())
        try await service.changePassword(current: original, new: password)
        _ = await service.lock()
        await rejects { try await service.unlock(password: original) }
        try await service.unlock(password: password)
        _ = await service.lock()
        await rejects { try await service.recover(code: String(repeating: "0", count: 64), newPassword: self.password) }
        try await service.recover(code: recovery.lowercased(), newPassword: "a new password 2026")
        _ = await service.lock(); try await service.unlock(password: "a new password 2026")
        let second = try VaultService(root: root.appendingPathComponent("second"))
        try await second.restoreBackup(from: backup, password: original, token: OperationToken())
        let status = await second.status(); expectTrue(status.exists)
    }
    func testPasswordBoundsAndProcessLock() async throws {
        let root = try directory(); let service = try VaultService(root: root)
        await rejects { _ = try await service.create(password: "too short") }
        await rejects { _ = try await service.create(password: String(repeating: "x", count: 257)) }
        _ = try await service.create(password: password)
        expectThrows { _ = try VaultService(root: root) }
    }
    func testRecoveryOnboardingSurvivesLock() async throws {
        let root = try directory(); let service = try VaultService(root: root)
        let recovery = try await service.create(password: password)
        _ = await service.lock(); try await service.unlock(password: password)
        let pending = try await service.pendingRecoveryKey(); expectEqual(pending, recovery)
        try await service.acknowledgeRecoveryKey()
        _ = await service.lock(); try await service.unlock(password: password)
        let after = try await service.pendingRecoveryKey(); expectNil(after)
    }
    func testEmptyBoundaryStreamingAndDuplicates() async throws {
        let root = try directory(); let service = try VaultService(root: root.appendingPathComponent("data"))
        _ = try await service.create(password: password)
        for size in [0, 1, VaultService.blockSize - 1, VaultService.blockSize, VaultService.blockSize + 1] {
            let data = Data(repeating: UInt8(size % 251), count: size)
            let source = try fixture(data, name: "same.bin", at: root)
            let item = try await service.importFile(source, parent: nil, token: OperationToken())
            expectEqual(item.size, UInt64(size))
            let output = root.appendingPathComponent("output.bin")
            try await service.export(item.id, to: output, token: OperationToken())
            expectEqual(try Data(contentsOf: output), data)
            expectEqual(try Data(contentsOf: source), data)
        }
        let items = try await service.items(); expectEqual(Set(items.map(\.name)).count, 5)
        _ = await service.lock(); try await service.unlock(password: password)
        let reopened = try await service.items(); expectEqual(reopened.count, 5)
    }
    func testNoPlaintextNamesOrContentsAndPreviewLimit() async throws {
        let root = try directory(); let storage = root.appendingPathComponent("data"); let service = try VaultService(root: storage)
        _ = try await service.create(password: password)
        let secret = Data("SECRET-MATERIAL-a very private note".utf8)
        let source = try fixture(secret, name: "secret-filename.txt", at: root)
        let item = try await service.importFile(source, parent: nil, token: OperationToken())
        let preview = try await service.readPreview(item.id); expectEqual(preview, secret)
        for url in allFiles(storage) {
            expectFalse(url.lastPathComponent.contains("secret-filename"))
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let bytes = try Data(contentsOf: url)
                expectNil(bytes.range(of: secret)); expectNil(bytes.range(of: Data("secret-filename".utf8)))
            }
        }
        let big = root.appendingPathComponent("large.bin"); _ = FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: UInt64(VaultService.previewLimit + 1)); try handle.close()
        let large = try await service.importFile(big, parent: nil, token: OperationToken())
        let unavailable = try await service.readPreview(large.id); expectNil(unavailable)
    }
    func testTamperTruncationTrailingAndReorderedChunks() async throws {
        let root = try directory(); let storage = root.appendingPathComponent("data"); let service = try VaultService(root: storage)
        _ = try await service.create(password: password)
        let data = Data(repeating: 73, count: VaultService.blockSize * 2)
        let item = try await service.importFile(fixture(data, at: root), parent: nil, token: OperationToken())
        let path = try activeStore(storage).appendingPathComponent("objects").appendingPathComponent(item.object!.uuidString + ".hzn")
        let original = try Data(contentsOf: path)
        var tampered = original; tampered[100] ^= 1; try tampered.write(to: path)
        await rejects { _ = try await service.readPreview(item.id) }
        try original.dropLast().write(to: path); await rejects { _ = try await service.readPreview(item.id) }
        try (original + Data([0])).write(to: path); await rejects { _ = try await service.readPreview(item.id) }
        let length = 4 + VaultService.blockSize + 28
        let swapped = original.prefix(8) + original.subdata(in: (8 + length)..<(8 + length * 2)) + original.subdata(in: 8..<(8 + length))
        try swapped.write(to: path); await rejects { _ = try await service.readPreview(item.id) }
        let destination = try fixture(Data("preserve-existing".utf8), name: "export.bin", at: root)
        await rejects { try await service.export(item.id, to: destination, token: OperationToken()) }
        expectEqual(try String(contentsOf: destination, encoding: .utf8), "preserve-existing")
    }
    func testFoldersMoveCycleTrashRestoreAndExpiration() async throws {
        let root = try directory(); let service = try VaultService(root: root)
        _ = try await service.create(password: password)
        let parent = try await service.createFolder(name: "Parent", parent: nil)
        let child = try await service.createFolder(name: "Child", parent: parent.id)
        let note = try await service.createNote(name: "Note", parent: child.id)
        _ = try await service.saveNote(NoteDraft(id: note.id, title: "Note", text: "secret"))
        await rejects { try await service.move(parent.id, parent: child.id) }
        try await service.trash(parent.id)
        let trashed = try await service.items(); expectTrue(trashed.allSatisfy(\.isTrashed))
        try await service.restoreItem(parent.id)
        let restored = try await service.items(); expectTrue(restored.allSatisfy { !$0.isTrashed })
        try await service.trash(child.id); try await service.trash(parent.id); try await service.permanentlyDelete(parent.id)
        let empty = try await service.items(); expectTrue(empty.isEmpty)
        let expired = try await service.createNote(name: "expire", parent: nil)
        try await service.trash(expired.id, at: Date().addingTimeInterval(-31 * 86400))
        _ = await service.lock(); try await service.unlock(password: password)
        let after = try await service.items(); expectTrue(after.isEmpty)
    }
    func testRestoreOrphanIntoRootAndConflict() async throws {
        let root = try directory(); let service = try VaultService(root: root)
        _ = try await service.create(password: password)
        let folder = try await service.createFolder(name: "folder", parent: nil)
        let note = try await service.createNote(name: "same", parent: folder.id)
        try await service.trash(note.id); try await service.trash(folder.id)
        _ = try await service.createNote(name: "same", parent: nil)
        try await service.restoreItem(note.id)
        let items = try await service.items(); let restored = items.first { $0.id == note.id }!
        expectNil(restored.parent); expectEqual(restored.name, "same (2)")
    }
    func testTransactionFailuresRetainOriginalNoteAndDraft() async throws {
        let root = try directory(); let fault = FaultSwitch()
        let service = try VaultService(root: root, hooks: StorageHooks { try fault.hit($0) })
        _ = try await service.create(password: password)
        let note = try await service.createNote(name: "Private note", parent: nil)
        _ = try await service.saveNote(NoteDraft(id: note.id, title: note.name, text: "original"))
        for point in [CommitPoint.afterObject, .beforeManifest] {
            fault.set(point)
            await rejects { _ = try await service.saveNote(NoteDraft(id: note.id, title: note.name, text: "changed")) }
            let data = try await service.readPreview(note.id); expectEqual(data, Data("original".utf8))
        }
        fault.set(.beforeManifest)
        let retained = await service.lock(draft: NoteDraft(id: note.id, title: note.name, text: "draft preserved")); expectTrue(retained)
        fault.set(nil); try await service.unlock(password: password)
        let draft = try await service.pendingDraft(); expectEqual(draft?.text, "draft preserved")
        _ = try await service.saveNote(draft!); let status = await service.status(); expectFalse(status.hasDraft)
        fault.set(.afterManifest)
        await rejects { _ = try await service.saveNote(NoteDraft(id: note.id, title: note.name, text: "committed")) }
        fault.set(nil); _ = await service.lock(); try await service.unlock(password: password)
        let committed = try await service.readPreview(note.id); expectEqual(committed, Data("committed".utf8))
    }
    func testCancellationAndChangedSource() async throws {
        let root = try directory(); let service = try VaultService(root: root.appendingPathComponent("data"))
        _ = try await service.create(password: password)
        let source = try fixture(Data(repeating: 12, count: VaultService.blockSize + 1), at: root)
        let cancelled = OperationToken()
        await rejects {
            _ = try await service.importFile(source, parent: nil, token: cancelled) { progress in if progress.fraction > 0.1 { cancelled.cancel() } }
        }
        let items = try await service.items(); expectTrue(items.isEmpty)
        let changed = FaultSwitch()
        await rejects {
            _ = try await service.importFile(source, parent: nil, token: OperationToken()) { progress in
                if progress.fraction >= 0.5 { try? Data([42]).write(to: source); changed.set(.afterObject) }
            }
        }
        let after = try await service.items(); expectTrue(after.isEmpty)
    }
    func testBackupRestoreValidationAndRecovery() async throws {
        let root = try directory(); let storage = root.appendingPathComponent("data"); let service = try VaultService(root: storage)
        let code = try await service.create(password: password)
        let note = try await service.createNote(name: "old note", parent: nil)
        _ = try await service.saveNote(NoteDraft(id: note.id, title: note.name, text: "backup contents"))
        let backup = root.appendingPathComponent("valid.horizonbackup"); try await service.backup(to: backup, token: OperationToken())
        _ = try await service.createNote(name: "current note", parent: nil)
        _ = await service.lock()
        await rejects { try await service.restoreBackup(from: backup, password: "wrong", token: OperationToken()) }
        try await service.unlock(password: password); let unchanged = try await service.items(); expectEqual(unchanged.count, 2)
        _ = await service.lock()
        try await service.restoreBackup(from: backup, password: nil, recovery: code, newPassword: "recovered password 2026", token: OperationToken())
        let restored = try await service.items(); expectEqual(restored.count, 1)
        let status = await service.status(); expectEqual(status.previousCount, 1)
        let data = try await service.readPreview(note.id); expectEqual(data, Data("backup contents".utf8))
        _ = await service.lock(); try await service.unlock(password: "recovered password 2026")
        let broken = root.appendingPathComponent("broken.horizonbackup"); try FileManager.default.copyItem(at: backup, to: broken)
        let object = broken.appendingPathComponent("objects").appendingPathComponent(restored[0].object!.uuidString + ".hzn")
        try Data([0]).write(to: object)
        _ = await service.lock()
        await rejects { try await service.restoreBackup(from: broken, password: self.password, token: OperationToken()) }
        try await service.unlock(password: "recovered password 2026")
        let after = try await service.items(); expectEqual(after, restored)
    }
    func testManifestTamperUnknownVersionAndSymlink() async throws {
        let root = try directory(); let storage = root.appendingPathComponent("data"); let service = try VaultService(root: storage)
        _ = try await service.create(password: password)
        let manifest = try activeStore(storage).appendingPathComponent("manifest.hzn")
        let original = try Data(contentsOf: manifest); var bad = original; bad[15] ^= 1; try bad.write(to: manifest)
        _ = await service.lock(); await rejects { try await service.unlock(password: self.password) }
        try original.write(to: manifest); try await service.unlock(password: password)
        let source = try fixture(Data([1, 2, 3]), at: root); let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await rejects { _ = try await service.importFile(link, parent: nil, token: OperationToken()) }
        let backup = root.appendingPathComponent("unknown.horizonbackup"); try await service.backup(to: backup, token: OperationToken())
        let path = backup.appendingPathComponent("header.json"); var h = try JSONDecoder().decode(Header.self, from: Data(contentsOf: path)); h.version = 999
        try JSONEncoder().encode(h).write(to: path)
        _ = await service.lock(); await rejects { try await service.restoreBackup(from: backup, password: self.password, token: OperationToken()) }
        try await service.unlock(password: password)
    }
    func testActivationFailureKeepsExistingVault() async throws {
        let root = try directory(); let fault = FaultSwitch()
        let service = try VaultService(root: root.appendingPathComponent("data"), hooks: StorageHooks { try fault.hit($0) })
        _ = try await service.create(password: password)
        let backup = root.appendingPathComponent("backup.horizonbackup"); try await service.backup(to: backup, token: OperationToken())
        _ = try await service.createNote(name: "keep me", parent: nil); _ = await service.lock()
        fault.set(.beforeActivation)
        await rejects { try await service.restoreBackup(from: backup, password: self.password, token: OperationToken()) }
        fault.set(nil); try await service.unlock(password: password)
        let items = try await service.items(); expectEqual(items.map(\.name), ["keep me"])
    }
    func testLockedAccessNoteLimitProtectedDestinationsAndExportCancel() async throws {
        let root = try directory(); let storage = root.appendingPathComponent("data")
        let service = try VaultService(root: storage)
        _ = try await service.create(password: password)
        let note = try await service.createNote(name: "small note", parent: nil)
        await rejects { _ = try await service.saveNote(NoteDraft(id: note.id, title: note.name, text: String(repeating: "x", count: VaultService.noteLimit + 1))) }
        let original = try await service.readPreview(note.id); expectEqual(original, Data())
        let source = try fixture(Data(repeating: 4, count: VaultService.blockSize + 1), at: root)
        let item = try await service.importFile(source, parent: nil, token: OperationToken())
        let destination = try fixture(Data("keep me".utf8), name: "existing.txt", at: root)
        let token = OperationToken()
        await rejects { try await service.export(item.id, to: destination, token: token) { _ in token.cancel() } }
        expectEqual(try String(contentsOf: destination, encoding: .utf8), "keep me")
        await rejects { try await service.export(item.id, to: storage.appendingPathComponent("state.json"), token: OperationToken()) }
        await rejects { try await service.backup(to: storage.appendingPathComponent("bad.horizonbackup"), token: OperationToken()) }
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: storage)
        await rejects { try await service.export(item.id, to: alias.appendingPathComponent("state.json"), token: OperationToken()) }
        _ = await service.lock()
        await rejects { _ = try await service.items() }
        await rejects { _ = try await service.readPreview(item.id) }
        await rejects { _ = try await service.createFolder(name: "blocked", parent: nil) }
        try await service.unlock(password: password)
        let after = try await service.items(); expectEqual(after.count, 2)
    }
    func testLargeFileOverFourGiB() async throws {
        guard ProcessInfo.processInfo.environment["HORIZON_LARGE_TEST"] == "1" else { return }
        let root = try directory(); let service = try VaultService(root: root.appendingPathComponent("data"))
        _ = try await service.create(password: password)
        let source = root.appendingPathComponent("over-four-gib.bin"); _ = FileManager.default.createFile(atPath: source.path, contents: nil)
        let size: UInt64 = 4 * 1024 * 1024 * 1024 + 17
        let file = try FileHandle(forWritingTo: source); try file.truncate(atOffset: size); try file.seek(toOffset: size - 17); try file.write(contentsOf: Data(repeating: 0x7f, count: 17)); try file.close()
        let item = try await service.importFile(source, parent: nil, token: OperationToken()); expectEqual(item.size, size)
        let destination = root.appendingPathComponent("export.bin"); try await service.export(item.id, to: destination, token: OperationToken())
        let input = try FileHandle(forReadingFrom: source); let output = try FileHandle(forReadingFrom: destination)
        defer { try? input.close(); try? output.close() }
        while let a = try input.read(upToCount: VaultService.blockSize), !a.isEmpty { let b = try output.read(upToCount: a.count); expectEqual(a, b) }
        expectTrue((try output.read(upToCount: 1) ?? Data()).isEmpty)
    }
}

@MainActor private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { CheckContext.fail("Values differ: \(a) vs \(b)", file: file, line: line) } }
@MainActor private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if !value { CheckContext.fail("Expected true", file: file, line: line) } }
@MainActor private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if value { CheckContext.fail("Expected false", file: file, line: line) } }
@MainActor private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { CheckContext.fail("Expected nil", file: file, line: line) } }
@MainActor private func expectThrows(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) { do { try operation(); CheckContext.fail("Expected an error", file: file, line: line) } catch {} }
