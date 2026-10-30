import Foundation

private struct SessionDeletionLedger: Codable {
    var version = 1
    /// Native deletion timestamps in milliseconds. No titles, paths, or transcript content.
    var sessions: [String: Int64] = [:]
}

extension History {
    var deletionLedger: URL { vault.appendingPathComponent("deletions.json") }

    /// Only explicit native tombstones count as deletion; a missing record never does.
    func deletedSessions() throws -> [String: Int64] {
        try safePath(deletionLedger)
        var ledger = SessionDeletionLedger()
        if exists(deletionLedger) {
            ledger = try JSONDecoder().decode(SessionDeletionLedger.self, from: Data(contentsOf: deletionLedger))
            guard ledger.version == 1, ledger.sessions.allSatisfy({ validSession($0.key) && $0.key == $0.key.lowercased() && $0.value > 0 }) else {
                throw SyncError("会话删除索引无法识别，已停止同步。")
            }
        }
        for owner in try owners() {
            for file in try fm.contentsOfDirectory(at: owner.directory, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                guard name.hasPrefix("deleted_"), uuid(String(name.dropFirst(8))) else { continue }
                try safePath(file)
                let attributes = try fm.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue <= 32 else {
                    throw SyncError("Code 会话删除标记格式无法识别，已停止同步。")
                }
                let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let timestamp = Int64(text), timestamp > 0 else {
                    throw SyncError("Code 会话删除标记缺少有效时间，已停止同步。")
                }
                let id = "local_" + name.dropFirst(8).lowercased()
                ledger.sessions[id] = max(ledger.sessions[id] ?? 0, timestamp)
            }
        }
        return ledger.sessions
    }

    @discardableResult
    func rememberDeletions() throws -> [String: Int64] {
        let sessions = try deletedSessions()
        if !sessions.isEmpty {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(SessionDeletionLedger(sessions: sessions))
            // Retain intent even if its source account directory is later cleaned or restored.
            // This monotonic intent is not rolled back with an unrelated configuration change.
            let previous = exists(deletionLedger) ? try Data(contentsOf: deletionLedger) : nil
            if previous != data { try atomicData(data, deletionLedger) }
        }
        return sessions
    }

    func pendingDeletionCopies() throws -> Int {
        let deleted = try deletedSessions()
        return try records().filter { deleted[$0.id.lowercased()] != nil }.count
    }

    /// Called only inside a stopped-Claude transaction. Back up metadata, never erase JSONL.
    func synchronizeDeletions(transaction: Transaction) throws -> Int {
        let deleted = try rememberDeletions()
        var count = 0
        for record in try records() {
            guard let timestamp = deleted[record.id.lowercased()] else { continue }
            let marker = record.owner.directory.appendingPathComponent("deleted_" + record.id.dropFirst(6))
            if !exists(marker) { try transaction.writeData(Data(String(timestamp).utf8), to: marker) }
            try transaction.replace(record.file, with: nil)
            count += 1
        }
        return count
    }
}
