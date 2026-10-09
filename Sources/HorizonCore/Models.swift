import Foundation

public enum HorizonError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}

public enum ItemKind: String, Codable, Sendable { case file, folder, note }

public struct VaultItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let kind: ItemKind
    public var parent: UUID?
    public var created: Date
    public var modified: Date
    public var size: UInt64
    public var object: UUID?
    public var chunks: UInt64
    public var digest: Data?
    public var trashedAt: Date?
    public var trashBatch: UUID?
    public var rootPosition: SpacePoint? = nil
    public var localPosition: SpacePoint? = nil
    public var isFolder: Bool { kind == .folder }
    public var isNote: Bool { kind == .note }
    public var isTrashed: Bool { trashedAt != nil }
}

struct Manifest: Codable, Sendable {
    var version = 2
    var vaultID: UUID
    var items: [VaultItem] = []
    // Kept encrypted until the user explicitly confirms saving the recovery key.
    var pendingRecovery: Data?
}

struct Header: Codable, Sendable {
    var version = 1
    var vaultID: UUID
    var salt: Data
    var rounds: UInt32 = 600_000
    var passwordWrap: Data
    var recoveryWrap: Data
}

struct StoreState: Codable, Sendable {
    var version = 1
    var active: UUID?
    var previous: [UUID] = []
    var lastBackup: Date?
}

public struct VaultStatus: Sendable {
    public let exists: Bool
    public let lastBackup: Date?
    public let previousCount: Int
    public let hasDraft: Bool
}

public struct OperationProgress: Sendable {
    public let fraction: Double
    public let phase: String
}

public struct NoteDraft: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let text: String
    public init(id: UUID, title: String, text: String) { self.id = id; self.title = title; self.text = text }
}

/// Cancellation can be requested immediately by the UI while the vault actor is writing.
public final class OperationToken: @unchecked Sendable {
    private let mutex = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { mutex.lock(); cancelled = true; mutex.unlock() }
    public func check() throws {
        mutex.lock(); let value = cancelled; mutex.unlock()
        if value { throw CancellationError() }
    }
}

public typealias ProgressHandler = @Sendable (OperationProgress) -> Void

/// Test-only fault seam also documents the transaction boundaries.
public enum CommitPoint: String, Sendable { case afterObject, beforeManifest, afterManifest, beforeActivation }
public struct StorageHooks: Sendable {
    public let checkpoint: @Sendable (CommitPoint) throws -> Void
    public init(checkpoint: @escaping @Sendable (CommitPoint) throws -> Void = { _ in }) { self.checkpoint = checkpoint }
}
