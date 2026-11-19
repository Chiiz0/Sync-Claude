import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct TranscriptCompactionResult {
    public internal(set) var removedFiles = 0
    public internal(set) var reclaimedBytes: Int64 = 0
    public internal(set) var failures: [String] = []
    public var message: String {
        "已精简旧正文归档，回收 \(removedFiles) 份重复快照、\(ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file))。"
    }
    func checkFailures() throws {
        if !failures.isEmpty { throw SyncError("旧正文归档精简未完成，将重试：\(failures.joined(separator: "；"))") }
    }
}

extension Engine {
    /// Independent of Desktop record parsing and the automatic archive preference.
    /// Only removes verified redundant files inside our archive, under the same lock
    /// used by older releases and purge/recovery operations.
    public func compactHistory() throws -> TranscriptCompactionResult {
        try locked(state) {
            guard !hasPendingOperation else { throw SyncError("请先完成上次操作，再精简旧正文归档。") }
            return try history.compactArchivedTranscripts()
        }
    }
}

private struct TranscriptSnapshot {
    let url: URL
    let size: Int64
    let stamp: String

    init?(_ url: URL) throws {
        try safePath(url)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        self.url = url
        size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        stamp = "\(url.lastPathComponent):\(size):\(modified):\(created):\(inode)"
    }

    func checkUnchanged() throws {
        guard try TranscriptSnapshot(url)?.stamp == stamp else {
            throw SyncError("归档文件已变化：\(url.lastPathComponent)")
        }
    }
}

extension History {
    func compactArchivedTranscripts() throws -> TranscriptCompactionResult {
        let root = vault.appendingPathComponent("transcripts")
        try safePath(root)
        guard exists(root) else { return TranscriptCompactionResult() }
        var result = TranscriptCompactionResult()
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { uuid($0.lastPathComponent) }.sorted { $0.path < $1.path }
        compactedTranscriptInventories = compactedTranscriptInventories.filter { folders.contains($0.key) }
        for folder in folders {
            do { try compactTranscripts(folder, result: &result) }
            catch {
                // One broken directory must not strand all other legacy archives.
                compactedTranscriptInventories[folder] = nil
                result.failures.append("\(folder.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return result
    }

    private func compactTranscripts(_ folder: URL, result: inout TranscriptCompactionResult) throws {
        try safePath(folder)
        var snapshots: [TranscriptSnapshot] = []
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "jsonl", name.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { continue }
            if let snapshot = try TranscriptSnapshot(file) { snapshots.append(snapshot) }
        }
        func inventory(_ items: [TranscriptSnapshot]) -> String {
            sha(Data(items.map(\.stamp).sorted().joined(separator: "\n").utf8))
        }
        guard compactedTranscriptInventories[folder] != inventory(snapshots) else { return }
        var kept: [TranscriptSnapshot] = [], removed: Set<URL> = []
        defer {
            if !removed.isEmpty {
                let fd = open(folder.path, O_RDONLY)
                if fd >= 0 { _ = fsync(fd); close(fd) }
            }
        }
        if snapshots.count > 1 {
            for snapshot in snapshots.sorted(by: { $0.size != $1.size ? $0.size > $1.size : $0.url.path < $1.url.path }) {
                // digestTree hashes regular files in chunks. Keep only paths in memory,
                // rather than retaining every divergent full transcript in a large archive.
                guard try digestTree(snapshot.url) == snapshot.url.deletingPathExtension().lastPathComponent else { continue }
                try snapshot.checkUnchanged()
                var covered = false
                for longer in kept where longer.size > snapshot.size {
                    if try isTranscriptPrefix(snapshot.url, of: longer.url) {
                        try longer.checkUnchanged()
                        try snapshot.checkUnchanged()
                        covered = true
                        break
                    }
                }
                if covered {
                    try fm.removeItem(at: snapshot.url)
                    removed.insert(snapshot.url)
                    result.removedFiles += 1
                    result.reclaimedBytes += snapshot.size
                } else { kept.append(snapshot) }
            }
        }
        // Written only after success. A crash, failed deletion, or older app writing
        // a snapshot leaves a changed inventory that will be retried without new input.
        compactedTranscriptInventories[folder] = inventory(snapshots.filter { !removed.contains($0.url) })
    }

    private func isTranscriptPrefix(_ prefix: URL, of full: URL) throws -> Bool {
        try safePath(prefix); try safePath(full)
        let shorter = try FileHandle(forReadingFrom: prefix)
        defer { try? shorter.close() }
        let longer = try FileHandle(forReadingFrom: full)
        defer { try? longer.close() }
        while let chunk = try shorter.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            guard try longer.read(upToCount: chunk.count) == chunk else { return false }
        }
        return true
    }
}
