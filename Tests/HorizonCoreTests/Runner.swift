import Foundation
import Darwin
import HorizonCore
import AppKit
import PDFKit

@MainActor enum CheckContext {
    static var failures = [String]()
    static func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { failures.append("\(file):\(line): \(message)") }
}

/// Standalone integration runner: works with Command Line Tools, without XCTest/Testing runtimes.
@main struct HorizonChecks {
    @MainActor static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--ui-fixture"), CommandLine.arguments.count > index + 1 {
            do { try await createFixture(URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("UI fixture ready. Password: horizon demo password") }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        let suite = VaultTests()
        var tests: [(String, @MainActor () async throws -> Void)] = [
            ("spacePersistence", suite.testSpacePersistencePlacementAndFailures),
            ("legacySpaceMigration", suite.testLegacySpaceMigrationAndBackup),
            ("cryptoVectors", { try suite.testStandardCryptoVectors() }),
            ("passwordsRecovery", suite.testPasswordsNormalizationRecoveryAndBackupOldPassword),
            ("passwordBoundsProcessLock", suite.testPasswordBoundsAndProcessLock),
            ("recoveryOnboardingAfterLock", suite.testRecoveryOnboardingSurvivesLock),
            ("streamingBoundariesDuplicates", suite.testEmptyBoundaryStreamingAndDuplicates),
            ("noPlaintextPreviewLimits", suite.testNoPlaintextNamesOrContentsAndPreviewLimit),
            ("tamperReorderTruncateExport", suite.testTamperTruncationTrailingAndReorderedChunks),
            ("foldersTrashExpiration", suite.testFoldersMoveCycleTrashRestoreAndExpiration),
            ("restoreOrphanConflict", suite.testRestoreOrphanIntoRootAndConflict),
            ("transactionFailuresDraft", suite.testTransactionFailuresRetainOriginalNoteAndDraft),
            ("cancellationChangedSource", suite.testCancellationAndChangedSource),
            ("backupRestoreRecovery", suite.testBackupRestoreValidationAndRecovery),
            ("manifestVersionSymlink", suite.testManifestTamperUnknownVersionAndSymlink),
            ("activationFailure", suite.testActivationFailureKeepsExistingVault),
            ("lockedAccessProtectedDestinations", suite.testLockedAccessNoteLimitProtectedDestinationsAndExportCancel)
        ]
        if ProcessInfo.processInfo.environment["HORIZON_LARGE_TEST"] == "1" { tests.append(("largeFileOverFourGiB", suite.testLargeFileOverFourGiB)) }
        if let index = CommandLine.arguments.firstIndex(of: "--filter"), CommandLine.arguments.count > index + 1 {
            let filter = CommandLine.arguments[index + 1]; tests = tests.filter { $0.0.range(of: filter, options: .regularExpression) != nil }
        }
        guard !tests.isEmpty else { print("No matching checks"); exit(2) }
        let start = Date()
        for (name, run) in tests {
            let before = CheckContext.failures.count
            print("RUN  \(name)"); fflush(stdout)
            do { try await run() } catch { CheckContext.fail("\(name): \(error)") }
            print("\(CheckContext.failures.count == before ? "PASS" : "FAIL") \(name)"); fflush(stdout)
        }
        for failure in CheckContext.failures { print(failure) }
        print("\(tests.count) checks, \(CheckContext.failures.count) failures, \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        exit(CheckContext.failures.isEmpty ? 0 : 1)
    }
    @MainActor private static func createFixture(_ root: URL) async throws {
        let service = try VaultService(root: root)
        let status = await service.status()
        guard !status.exists else {
            try await service.unlock(password: "horizon demo password"); try await service.acknowledgeRecoveryKey()
            _ = await service.lock(); print("Fixture already exists"); return
        }
        _ = try await service.create(password: "horizon demo password")
        try await service.acknowledgeRecoveryKey()
        let folder = try await service.createFolder(name: "Личное", parent: nil)
        let note = try await service.createNote(name: "Начало моего пространства", parent: nil)
        _ = try await service.saveNote(NoteDraft(id: note.id, title: note.name, text: "Здесь можно хранить документы, фотографии и личные записи.\n\nЭто демонстрационные данные для проверки Horizon."))
        _ = try await service.createNote(name: "Идеи и планы", parent: folder.id)
        let sources = root.deletingLastPathComponent().appendingPathComponent("ui-fixtures")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let text = sources.appendingPathComponent("Письмо себе.txt")
        try Data("Всё важное. Внутри.\nТестовый документ Horizon.".utf8).write(to: text)
        _ = try await service.importFile(text, parent: nil, token: OperationToken())
        let image = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Horizon-1024.png")
        let photo = sources.appendingPathComponent("Горизонт.png")
        try FileManager.default.copyItem(at: image, to: photo)
        _ = try await service.importFile(photo, parent: nil, token: OperationToken())
        if let picture = NSImage(contentsOf: image), let page = PDFPage(image: picture) {
            let pdf = PDFDocument(); pdf.insert(page, at: 0)
            let path = sources.appendingPathComponent("Документ.pdf")
            if let data = pdf.dataRepresentation() { try data.write(to: path); _ = try await service.importFile(path, parent: nil, token: OperationToken()) }
        }
        _ = await service.lock()
    }
}
