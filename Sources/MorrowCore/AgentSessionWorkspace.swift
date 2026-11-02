import Foundation
import Darwin

public struct AgentWorkspaceLease: Codable, Sendable, Equatable {
    public let sessionID: String
    public let generation: String
    public let directory: URL
}
public struct AgentWorkspaceFile: Codable, Sendable {
    public let path: String
    public let bytes: Int
}
public struct AgentWorkspaceMedia: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let mimeType: String
    public let bytes: Int
    public let lease: AgentWorkspaceLease
    public init(id: String, name: String, path: String, mimeType: String, bytes: Int, lease: AgentWorkspaceLease) {
        self.id = id; self.name = name; self.path = path; self.mimeType = mimeType; self.bytes = bytes; self.lease = lease
    }
}
public struct AgentWorkspaceVideoJob: Codable, Identifiable, Sendable {
    public let id: String
    public let model: String
    public let lease: AgentWorkspaceLease
    public init(id: String, model: String, lease: AgentWorkspaceLease) { self.id = id; self.model = model; self.lease = lease }
}

/// Short Unix-socket-compatible paths, owned by one store and one chat. A lease
/// is revoked before cleanup so late network results cannot recreate files.
public actor AgentSessionWorkspaces {
    private let namespace: String
    private let temporaryRoot: URL
    private var archived = Set<String>()
    public init(owner: URL, temporaryRoot: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)) {
        namespace = String(MailStore.hash(owner.standardizedFileURL.path).prefix(12))
        self.temporaryRoot = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func directory(_ sessionID: String) -> URL {
        // Even a scoped child plus SRT's socket suffix must fit macOS sun_path.
        temporaryRoot.appendingPathComponent("MorrowResponder-" + String(MailStore.hash(namespace + ":" + sessionID).prefix(12)), isDirectory: true)
    }
    public func open(_ sessionID: String, scope: String? = nil) throws -> AgentWorkspaceLease {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256, !archived.contains(sessionID) else { throw MailError.message("归档会话的临时工作区不可使用。") }
        let parent = directory(sessionID)
        _ = try ensure(parent, sessionID: sessionID)
        let selected = scope.map { parent.appendingPathComponent("MorrowResponder-" + String(MailStore.hash($0).prefix(12)), isDirectory: true) } ?? parent
        return try ensure(selected, sessionID: sessionID)
    }
    private func ensure(_ path: URL, sessionID: String) throws -> AgentWorkspaceLease {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            let lease = try manifest(path)
            guard lease.sessionID == sessionID, lease.directory == path else { throw MailError.message("临时工作区不属于当前会话。") }
            return lease
        }
        try fm.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lease = AgentWorkspaceLease(sessionID: sessionID, generation: UUID().uuidString, directory: path)
        try JSONEncoder().encode(lease).write(to: path.appendingPathComponent(".workspace.json"), options: .atomic)
        for name in ["input", "output", "media", "tmp"] {
            try fm.createDirectory(at: path.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        return lease
    }
    private func manifest(_ path: URL) throws -> AgentWorkspaceLease {
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard path.standardizedFileURL == path, path.resolvingSymlinksInPath() == path,
              attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw MailError.message("临时工作区路径、归属或权限无效。") }
        let file = path.appendingPathComponent(".workspace.json")
        guard (try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular,
              file.resolvingSymlinksInPath() == file else { throw MailError.message("临时工作区清单无效。") }
        return try JSONDecoder().decode(AgentWorkspaceLease.self, from: BoundedFileReader.read(file, maximumBytes: 4096))
    }
    public func validate(_ lease: AgentWorkspaceLease) throws {
        guard !archived.contains(lease.sessionID) else { throw CancellationError() }
        let parent = directory(lease.sessionID)
        guard lease.directory == parent || (lease.directory.deletingLastPathComponent() == parent && lease.directory.lastPathComponent.range(of: #"^MorrowResponder-[a-f0-9]{12}$"#, options: .regularExpression) != nil),
              try manifest(parent).sessionID == lease.sessionID else { throw CancellationError() }
        let current = try manifest(lease.directory)
        guard current == lease else { throw CancellationError() }
    }
    public func file(_ path: String, lease: AgentWorkspaceLease, mustExist: Bool = true) throws -> URL {
        try validate(lease)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !path.hasPrefix(".") else { throw MailError.message("工作区文件路径无效。") }
        let candidate = lease.directory.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(lease.directory.resolvingSymlinksInPath().path + "/") else { throw MailError.message("文件不在当前会话工作区。") }
        if mustExist { guard (try FileManager.default.attributesOfItem(atPath: resolved.path)[.type] as? FileAttributeType) == .typeRegular else { throw MailError.message("工作区文件不可读。") } }
        return resolved
    }
    public func write(_ data: Data, path: String, lease: AgentWorkspaceLease) throws -> AgentWorkspaceFile {
        guard data.count <= 128 * 1024 * 1024 else { throw MailError.message("工作区单个文件超过128MiB限制。") }
        let target = try file(path, lease: lease, mustExist: false)
        let replaced = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard try usedBytes(lease) - replaced + data.count <= 512 * 1024 * 1024 else { throw MailError.message("会话工作区超过512MiB预算。") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return .init(path: path, bytes: data.count)
    }
    public func read(_ path: String, lease: AgentWorkspaceLease, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        try BoundedFileReader.read(file(path, lease: lease), maximumBytes: maximumBytes)
    }
    public func list(_ lease: AgentWorkspaceLease) throws -> [AgentWorkspaceFile] {
        try validate(lease)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let items = FileManager.default.enumerator(at: lease.directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var result: [AgentWorkspaceFile] = []
        for case let item as URL in items {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { items.skipDescendants(); continue }
            if values.isRegularFile == true {
                let path = String(item.path.dropFirst(lease.directory.path.count + 1))
                if !path.hasPrefix("input/") && !path.hasPrefix("tmp/") && !path.hasPrefix("MorrowResponder-") {
                    result.append(.init(path: path, bytes: values.fileSize ?? 0))
                }
            }
            guard result.count <= 4096 else { throw MailError.message("工作区文件数量超过限制。") }
        }
        return result.sorted { $0.path < $1.path }
    }
    private func usedBytes(_ lease: AgentWorkspaceLease) throws -> Int {
        try validate(lease)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let items = FileManager.default.enumerator(at: directory(lease.sessionID), includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0, count = 0
        for case let item as URL in items {
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { items.skipDescendants(); continue }
            count += 1
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
            guard count <= 8192, total <= 512 * 1024 * 1024 else { throw MailError.message("会话工作区超过文件数量或512MiB预算。") }
        }
        return total
    }
    public func checkBudget(_ lease: AgentWorkspaceLease) throws { _ = try usedBytes(lease) }
    public func archive(_ sessionID: String) throws {
        archived.insert(sessionID)
        let path = directory(sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let lease = try manifest(path)
        guard lease.directory == path, lease.sessionID == sessionID else { throw MailError.message("工作区归属校验失败，未清理文件。") }
        try FileManager.default.removeItem(at: path)
    }
    public func restore(_ sessionID: String) { archived.remove(sessionID) }
}
