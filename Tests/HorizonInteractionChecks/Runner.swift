import Foundation
import HorizonCore

@main struct InteractionChecks {
    @MainActor static func main() async {
        guard let index = CommandLine.arguments.firstIndex(of: "--vault-root"), CommandLine.arguments.count > index + 1 else { fatalError("A temporary test root is required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let model = AppModel()
            guard model.root == root, let service = model.service else { fatalError("Tests must never use a personal vault") }
            _ = try await service.create(password: "test space password 2026")
            try await service.acknowledgeRecoveryKey(); model.phase = .unlocked
            let a = try await service.createFolder(name: "A", parent: nil)
            let b = try await service.createFolder(name: "B", parent: nil)
            await model.refreshItems()
            let nested = try await service.createFolder(name: "Nested", parent: a.id)
            await model.refreshItems()
            model.navigate(nested.id); model.navigateUp()
            check(model.folder == a.id, "Escape navigation must return exactly one level")
            model.edit = .settings; model.navigateUp()
            check(model.folder == a.id, "Escape in a sheet must not leave its galaxy")
            model.edit = nil; model.preview = nested; model.navigateUp()
            check(model.folder == a.id, "Escape behind a preview must not change the map")
            model.preview = nil; model.navigateUp()
            check(model.folder == nil, "Escape in a top-level galaxy must return to Space")
            model.navigateUp()
            check(model.folder == nil, "Escape at the root must leave Space open")
            let source = root.appendingPathComponent("source.txt")
            try Data("public test".utf8).write(to: source)
            let target = SpaceImportDestination(sessionID: model.sessionID, folder: a.id, point: SpacePoint(x: 400, y: 150), spacing: 56)
            // Simulate navigation while NSItemProvider asynchronously resolves addresses.
            model.navigate(b.id)
            await model.importFiles([source, source, source, source], destination: target)
            check(model.folder == b.id, "Resolving a drop must not navigate back to its original map")
            let files = model.items.filter { $0.kind == .file }
            check(files.count == 4 && files.allSatisfy { $0.parent == a.id }, "Every batch file must use the captured destination")
            check(files[0].localPosition == target.point, "Drop point must be saved with the file")
            check(Set(files.compactMap { $0.localPosition.map { "\($0.x),\($0.y)" } }).count == 4, "Batch imports must not overlap")
            check(model.births.count == 4 && model.births.allSatisfy { $0.folder == a.id && $0.sessionID == model.sessionID }, "Every committed file needs its own scoped birth event")
            let original = files[0]
            await model.saveSpacePositions([original.id: CGPoint(x: -500, y: 250)], folder: a.id)
            check(!model.layoutSaving && model.items.first { $0.id == original.id }?.localPosition == SpacePoint(x: -500, y: 250), "App model must refresh persisted coordinates")
            check(model.items.first { $0.id == original.id }?.modified == original.modified, "Layout edits must not change document dates")
            let expired = target
            await model.lock()
            check(model.births.isEmpty && model.items.isEmpty && model.layoutStatus.isEmpty, "Lock must clear events, catalogue and layout status")
            try await service.unlock(password: "test space password 2026"); model.phase = .unlocked
            await model.refreshItems()
            await model.importFiles([source], destination: expired)
            check(model.items.filter { $0.kind == .file }.count == 4 && model.births.isEmpty, "An old drop must not run in a new session")
            await model.lock()
            print("Interactions: Escape navigation, captured drop, batch positions, birth events, layout save and stale-session cancellation — PASS")
        } catch { fatalError("Interaction check failed: \(error)") }
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
}
