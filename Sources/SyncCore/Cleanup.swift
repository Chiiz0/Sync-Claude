import Foundation

public struct AccountRecordInfo: Codable, Identifiable {
    public let id: String
    public let profile: String
    public let account: String
    public let organization: String
    public let sessionCount: Int
    public let uniqueSessionCount: Int
    public let missingTranscriptCount: Int
    public let fileCount: Int
    public let bytes: Int64
    public let empty: Bool
    public let savedLogin: Bool
    public let blockedReason: String?
    public let fingerprint: String
    public var canClean: Bool { blockedReason == nil }
}

public struct RemovedAccountRecord: Codable, Identifiable {
    public let id: String
    public let profile: String
    public let account: String
    public let organization: String
    public let sessionCount: Int
    public let bytes: Int64
    public let cleanedAt: Double
    public let digest: String
    public var restoredAt: Double?
}

extension Engine {
    var cleanupIndex: URL { state.appendingPathComponent("removed-records/index.json") }

    public func accountRecords() throws -> [AccountRecordInfo] {
        let owners = try history.owners(), records = try history.records(), transcripts = try history.transcripts()
        let saved = Set(try accounts().compactMap { $0["account"] as? String })
        let occurrences = Dictionary(grouping: records, by: { $0.id })
        var identities: [String: String] = [:]
        for profile in ["Claude", "Claude-3p"] {
            let config = try readJSON(support.appendingPathComponent(profile + "/config.json"), optional: true)
            if let account = config["lastKnownAccountUuid"] as? String, uuid(account) { identities[profile] = account }
        }
        return try owners.map { owner in
            let files = try treeFiles(owner.directory)
            let local = records.filter { $0.owner == owner }
            let sessionFiles = files.filter { $0.deletingLastPathComponent() == owner.directory && $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            var reason: String?
            if identities[owner.profile] == nil { reason = "无法识别此模式保留的登录，请先进入 Claude Code" }
            else if identities[owner.profile] == owner.account { reason = "当前保留的\(owner.profile == "Claude" ? "官方账号" : "API")目录" }
            else if sessionFiles.count != local.count { reason = "包含远程或不支持的会话，请先在 Claude 中处理" }
            let schedule = owner.directory.appendingPathComponent("scheduled-tasks.json")
            var emptySchedule = true
            if exists(schedule) {
                if let data = try? readJSON(schedule),
                   let tasks = data["scheduledTasks"] as? [Any],
                   let skips = data["recordedSkips"] as? [String: Any] {
                    let known = Set(data.keys).isSubset(of: ["scheduledTasks", "recordedSkips", "sundayAliasBoundaryStamped", "dayFieldsOrBoundaryStamped"])
                    emptySchedule = tasks.isEmpty && skips.isEmpty && known
                    if !tasks.isEmpty { reason = reason ?? "有定时任务，请先在 Claude 中停用并移除" }
                    if !known { reason = reason ?? "定时任务文件含未识别字段，请先检查" }
                } else {
                    emptySchedule = false
                    reason = reason ?? "定时任务文件格式无法识别，请先在 Claude 中检查"
                }
            }
            let verifiedEmpty = try isEmptyRecordDirectory(owner.directory)
            let empty = sessionFiles.isEmpty && emptySchedule && verifiedEmpty
            let bytes = try files.reduce(Int64(0)) { sum, file in
                sum + (((try fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0)
            }
            return AccountRecordInfo(id: owner.key, profile: owner.profile, account: owner.account, organization: owner.organization,
                sessionCount: sessionFiles.count,
                uniqueSessionCount: local.filter { occurrences[$0.id]?.count == 1 }.count,
                missingTranscriptCount: local.filter { transcripts[$0.value["cliSessionId"] as? String ?? ""] == nil }.count,
                fileCount: files.count, bytes: bytes, empty: empty, savedLogin: owner.profile == "Claude" && saved.contains(owner.account),
                blockedReason: reason, fingerprint: try digestTree(owner.directory))
        }
    }

    func cleanupEntries() throws -> [RemovedAccountRecord] {
        try safePath(cleanupIndex)
        guard exists(cleanupIndex) else { return [] }
        let entries = try JSONDecoder().decode([RemovedAccountRecord].self, from: Data(contentsOf: cleanupIndex))
        guard Set(entries.map(\.id)).count == entries.count else { throw SyncError("清理记录索引重复") }
        for entry in entries {
            guard uuid(entry.id), ["Claude", "Claude-3p"].contains(entry.profile), uuid(entry.account), uuid(entry.organization),
                  entry.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw SyncError("清理记录索引无效") }
        }
        return entries
    }

    public func removedAccountRecords() throws -> [RemovedAccountRecord] {
        try cleanupEntries().filter { $0.restoredAt == nil }.sorted { $0.cleanedAt > $1.cleanedAt }
    }

    public func restoredAccountBackups() throws -> [RemovedAccountRecord] {
        let entries = try cleanupEntries()
        let recoverableScopes = Set(entries.filter { $0.restoredAt == nil }.map { PurgeScope($0) })
        let restored = entries.filter { $0.restoredAt != nil && !recoverableScopes.contains(PurgeScope($0)) }
        return Dictionary(grouping: restored, by: { PurgeScope($0) }).values.compactMap { $0.max { $0.cleanedAt < $1.cleanedAt } }.sorted { $0.cleanedAt > $1.cleanedAt }
    }

    func writeCleanupEntries(_ entries: [RemovedAccountRecord], _ tx: Transaction) throws {
        try tx.write(JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)), to: cleanupIndex)
    }

    public func cleanAccountRecords(_ previews: [AccountRecordInfo], allowOpenSessions: Bool = false) throws -> Outcome {
        guard !previews.isEmpty, Set(previews.map(\.id)).count == previews.count else { throw SyncError("请选择需要清理的账户目录") }
        return try mutate("清理账户记录", configuration: false, allowOpenSessions: allowOpenSessions, countLabel: "移除账户目录", countUnit: "个") { tx in
            // Resolve trusted paths and recheck the reviewed content after Claude has fully stopped.
            let current = try accountRecords(), owners = try history.owners()
            for preview in previews {
                guard let item = current.first(where: { $0.id == preview.id }), item.fingerprint == preview.fingerprint else {
                    throw SyncError("账户目录已变化，请刷新并重新检查后清理。")
                }
                guard item.canClean else { throw SyncError(item.blockedReason ?? "此目录不可清理") }
            }
            var entries = try cleanupEntries()
            for preview in previews {
                guard let owner = owners.first(where: { $0.key == preview.id }), let item = current.first(where: { $0.id == preview.id }) else { throw SyncError("账户目录不存在") }
                let id = UUID().uuidString.lowercased()
                let backup = state.appendingPathComponent("removed-records/\(id)/content")
                try privateCopy(owner.directory, backup)
                guard try digestTree(backup) == item.fingerprint, try digestTree(owner.directory) == item.fingerprint else { throw SyncError("备份期间目录发生变化，已停止清理") }
                try tx.replace(owner.directory, with: nil)
                let accountDirectory = owner.directory.deletingLastPathComponent()
                if try fm.contentsOfDirectory(atPath: accountDirectory.path).isEmpty { try tx.replace(accountDirectory, with: nil) }
                entries.append(RemovedAccountRecord(id: id, profile: owner.profile, account: owner.account, organization: owner.organization,
                    sessionCount: item.sessionCount, bytes: item.bytes, cleanedAt: Date().timeIntervalSince1970, digest: item.fingerprint))
            }
            try writeCleanupEntries(entries, tx)
            return previews.count
        }
    }

    public func restoreAccountRecords(id: String, allowOpenSessions: Bool = false) throws -> Outcome {
        guard uuid(id) else { throw SyncError("清理记录 ID 无效") }
        return try mutate("恢复账户记录", configuration: false, allowOpenSessions: allowOpenSessions, countLabel: "恢复账户目录", countUnit: "个") { tx in
            var entries = try cleanupEntries()
            guard let index = entries.firstIndex(where: { $0.id == id && $0.restoredAt == nil }) else { throw SyncError("未找到可恢复的清理记录") }
            let entry = entries[index]
            let target = support.appendingPathComponent("\(entry.profile)/claude-code-sessions/\(entry.account)/\(entry.organization)")
            try safePath(target)
            guard !exists(target) else { throw SyncError("账户目录已重新建立，恢复会覆盖现有记录，已停止。") }
            let backup = state.appendingPathComponent("removed-records/\(id)/content")
            guard exists(backup), try digestTree(backup) == entry.digest else { throw SyncError("恢复副本缺失或校验失败，未修改账户目录。") }
            try tx.replace(target, with: backup)
            entries[index].restoredAt = Date().timeIntervalSince1970
            try writeCleanupEntries(entries, tx)
            return 1
        }
    }
}
