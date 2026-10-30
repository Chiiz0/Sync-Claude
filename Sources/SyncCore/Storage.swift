import Foundation
import CryptoKit
import Darwin

public struct SyncError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

let fm = FileManager.default
func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

// Refuse symlinks in ALL ancestors, including nonexistent final destinations.
func safePath(_ url: URL) throws {
    var cursor = url.standardizedFileURL
    while cursor.path != "/" {
        if let a = try? fm.attributesOfItem(atPath: cursor.path), a[.type] as? FileAttributeType == .typeSymbolicLink {
            throw SyncError("拒绝通过符号链接操作：\(cursor.path)")
        }
        cursor.deleteLastPathComponent()
    }
}
func privateDir(_ url: URL) throws {
    try safePath(url)
    try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}
func readJSON(_ url: URL, optional: Bool = false) throws -> [String: Any] {
    try safePath(url)
    if optional && !exists(url) { return [:] }
    let bytes = try Data(contentsOf: url)
    guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw SyncError("JSON 格式无法识别：\(url.lastPathComponent)")
    }
    return value
}
func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
}
func atomicData(_ data: Data, _ url: URL) throws {
    try safePath(url)
    try privateDir(url.deletingLastPathComponent())
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".sync-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw SyncError("无法写入临时文件") }
    let handle = try FileHandle(forWritingTo: tmp)
    try handle.synchronize(); try handle.close()
    guard rename(tmp.path, url.path) == 0 else { throw SyncError("原子写入失败：\(url.lastPathComponent)") }
    let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
    if fd >= 0 { _ = fsync(fd); close(fd) }
}
func atomicJSON(_ value: Any, _ url: URL) throws { try atomicData(jsonData(value), url) }

func treeFiles(_ root: URL) throws -> [URL] {
    try safePath(root)
    guard exists(root) else { return [] }
    let a = try fm.attributesOfItem(atPath: root.path)
    if a[.type] as? FileAttributeType == .typeRegular { return [root] }
    var result: [URL] = []
    for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
        try safePath(child)
        let type = try fm.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType
        if type == .typeDirectory { result += try treeFiles(child) }
        else if type == .typeRegular { result.append(child) }
        else { throw SyncError("无法安全复制特殊文件：\(child.lastPathComponent)") }
    }
    return result.sorted { $0.path < $1.path }
}
func digestTree(_ root: URL) throws -> String {
    let files = try treeFiles(root)
    var digest = SHA256()
    for file in files {
        digest.update(data: Data(file.path.dropFirst(root.path.count).utf8))
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        while let chunk = try h.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func privateCopy(_ source: URL, _ target: URL) throws {
    _ = try treeFiles(source)
    try safePath(target); try privateDir(target.deletingLastPathComponent())
    try fm.copyItem(at: source, to: target)
    for f in try treeFiles(target) { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    }
    guard try digestTree(source) == digestTree(target) else { throw SyncError("备份校验不一致") }
}

struct Undo: Codable {
    var destination: String
    var backup: String?
    var digest: String?
}
struct Journal: Codable {
    var id: String
    var operation: String
    var status: String
    var entries: [Undo]
}

// One journal per mutation. The write-ahead undo entry is durable before touching Claude.
final class Transaction {
    let root: URL
    let folder: URL
    var journal: Journal
    var beforeWrite: (() throws -> Void)?
    var pending: URL { root.appendingPathComponent("pending.json") }
    init(root: URL, operation: String) throws {
        self.root = root
        let id = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
        folder = root.appendingPathComponent("backups/\(id)")
        journal = Journal(id: id, operation: operation, status: "pending", entries: [])
        guard !exists(root.appendingPathComponent("pending.json")) else { throw SyncError("上次操作尚未结束，请先恢复未完成的操作。") }
        try privateDir(folder); try persist()
    }
    func persist() throws {
        let data = try JSONEncoder().encode(journal)
        try atomicData(data, folder.appendingPathComponent("manifest.json"))
        try atomicData(data, pending)
    }
    func replace(_ target: URL, with source: URL?) throws {
        try beforeWrite?()
        try safePath(target)
        let index = journal.entries.count
        var undo = Undo(destination: target.path)
        if exists(target) {
            let copy = folder.appendingPathComponent("\(index)-before")
            try privateCopy(target, copy)
            undo.backup = copy.path; undo.digest = try digestTree(copy)
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".sync-stage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        if let source { try privateCopy(source, stage) }
        journal.entries.append(undo); try persist()
        try beforeWrite?()
        if exists(target) { try fm.moveItem(at: target, to: folder.appendingPathComponent("\(index)-displaced")) }
        if source != nil { try privateDir(target.deletingLastPathComponent()); try fm.moveItem(at: stage, to: target) }
    }
    func write(_ value: Any, to target: URL) throws {
        try writeData(jsonData(value), to: target)
    }
    func writeData(_ data: Data, to target: URL) throws {
        let temp = folder.appendingPathComponent("\(journal.entries.count)-new.json")
        try atomicData(data, temp); try replace(target, with: temp)
    }
    func commit() throws {
        journal.status = "complete"
        try atomicData(JSONEncoder().encode(journal), folder.appendingPathComponent("manifest.json"))
        try fm.removeItem(at: pending)
    }
    func rollback() throws { try Self.recover(root: root) }
    static func recover(root: URL) throws {
        let pending = root.appendingPathComponent("pending.json")
        var journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: pending))
        guard journal.id.range(of: "^[0-9]+-[a-f0-9-]{36}$", options: .regularExpression) != nil else { throw SyncError("恢复日志 ID 无效") }
        let folder = root.appendingPathComponent("backups/\(journal.id)")
        let allowed = [root, root.deletingLastPathComponent().appendingPathComponent("Claude"), root.deletingLastPathComponent().appendingPathComponent("Claude-3p")]
        for (index, item) in journal.entries.enumerated() {
            let target = URL(fileURLWithPath: item.destination).standardizedFileURL
            guard allowed.contains(where: { target.path.hasPrefix($0.path + "/") }),
                  item.backup == nil || item.backup == folder.appendingPathComponent("\(index)-before").path else { throw SyncError("恢复日志包含范围外路径，已停止。") }
        }
        for (index, item) in journal.entries.enumerated().reversed() {
            let target = URL(fileURLWithPath: item.destination)
            try safePath(target)
            if let backup = item.backup {
                guard try digestTree(URL(fileURLWithPath: backup)) == item.digest else { throw SyncError("恢复前校验失败，已保留所有备份。") }
            }
            if exists(target) {
                try fm.moveItem(at: target, to: folder.appendingPathComponent("\(index)-recovery-\(UUID().uuidString)"))
            }
            if let backup = item.backup { try privateCopy(URL(fileURLWithPath: backup), target) }
        }
        journal.status = "rolled-back"
        try atomicData(JSONEncoder().encode(journal), folder.appendingPathComponent("manifest.json"))
        try fm.removeItem(at: pending)
    }
}

func locked<T>(_ root: URL, _ body: () throws -> T) throws -> T {
    try privateDir(root)
    let path = root.appendingPathComponent("operation.lock"); try safePath(path)
    let fd = open(path.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw SyncError("无法创建操作锁") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SyncError("另一个操作正在进行，请稍后重试。") }
    defer { _ = flock(fd, LOCK_UN) }
    return try body()
}
