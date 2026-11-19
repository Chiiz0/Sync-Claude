import Foundation

public struct ScheduledRunInfo: Codable, Identifiable {
    public let id: String
    public let taskID: String
    public let title: String
    public let project: String
    public let owners: [String]
    public let lastActivity: Double
    public let blockedReason: String?
    public var canRemove: Bool { blockedReason == nil }
}

public struct ScheduledRunRemovalPreview: Codable, Identifiable {
    public var id: String { fingerprint }
    public let runs: [ScheduledRunInfo]
    public let notificationReferences: Int
    public let fingerprint: String
}

extension Engine {
    /// A completed turn count or archive flag alone is never evidence that a run ended.
    /// A terminal transcript event permits selection. Mutation stops Claude and rechecks it.
    func scheduledRunBlock(_ copies: [Record], transcript: URL?) throws -> String? {
        if copies.contains(where: { $0.initializing }) { return "正在初始化" }
        for record in copies {
            for key in ["isRunning", "interruptedAwaitingPerson", "interruptedUnseenResume", "armedWorkAtQuit"] {
                if let flag = record.value[key], !(flag is NSNull), (flag as? Bool) != false { return "仍在运行、等待输入或有中断待续任务" }
            }
            for key in ["pendingFirstStart", "cutTurn"] {
                if let value = record.value[key], !(value is NSNull) { return "运行尚未完整结束" }
            }
        }
        guard let transcript else { return "缺少正文，无法确认运行已结束" }
        try safePath(transcript)
        let data = try Data(contentsOf: transcript)
        guard data.last == 10 else { return "正文仍在写入或不完整" }
        var terminal: [String: Any]?
        for line in data.split(separator: 10) {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return "正文格式无法识别" }
            if let type = item["type"] as? String, ["user", "assistant", "result"].contains(type), item["isSidechain"] as? Bool != true { terminal = item }
        }
        guard let last = terminal else { return "没有可确认的结束事件" }
        if last["type"] as? String == "result", ["success", "error_during_execution", "error_max_turns", "error_max_budget_usd", "error_max_structured_output_retries"].contains(last["subtype"] as? String ?? "") { return nil }
        if last["type"] as? String == "assistant", let message = last["message"] as? [String: Any],
           message["stop_reason"] as? String == "end_turn",
           !(message["content"] as? [[String: Any]] ?? []).contains(where: { $0["type"] as? String == "tool_use" }) { return nil }
        return "最近一轮尚无结束证据，可能仍在等待工具或审批"
    }

    public func scheduledRuns() throws -> [ScheduledRunInfo] {
        let records = try history.records(), deleted = try history.deletedSessions(), transcripts = try history.transcripts()
        return try Dictionary(grouping: records, by: \.id).compactMap { id, copies in
            guard deleted[id.lowercased()] == nil, let record = copies.max(by: { $0.activity < $1.activity }),
                  let task = copies.compactMap({ $0.value["scheduledTaskId"] as? String }).first else { return nil }
            let taskIDs = Set(copies.compactMap { $0.value["scheduledTaskId"] as? String })
            let cliIDs = Set(copies.compactMap { $0.value["cliSessionId"] as? String })
            let reason = taskIDs.count != 1 || cliIDs.count != 1 ? "账户间的任务或正文关联不一致" : try scheduledRunBlock(copies, transcript: transcripts[record.value["cliSessionId"] as? String ?? ""])
            return ScheduledRunInfo(id: id, taskID: task, title: record.value["title"] as? String ?? "未命名运行",
                project: record.value["originCwd"] as? String ?? record.value["cwd"] as? String ?? "",
                owners: copies.map { $0.owner.key }.sorted(), lastActivity: record.activity, blockedReason: reason)
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    public func previewScheduledRunRemoval(ids: [String]) throws -> ScheduledRunRemovalPreview {
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy(validSession) else { throw SyncError("请选择已完成的任务运行记录") }
        let all = try scheduledRuns(), selected = Set(ids)
        let runs = all.filter { selected.contains($0.id) }
        guard runs.count == ids.count else { throw SyncError("运行列表已变化，请刷新后重新选择") }
        if let blocked = runs.first(where: { !$0.canRemove }) { throw SyncError("“\(blocked.title)”不可移除：\(blocked.blockedReason!)") }
        var fingerprints: [String] = [], notifications = 0
        let transcripts = try history.transcripts()
        for record in try history.records() where selected.contains(record.id) {
            fingerprints.append(record.file.path + ":" + (try digestTree(record.file)))
            guard let cli = record.value["cliSessionId"] as? String, let transcript = try transcripts[cli] else { throw SyncError("运行正文已变化") }
            fingerprints.append(transcript.path + ":" + (try digestTree(transcript)))
        }
        for manifest in try taskManifests() {
            let count = manifest.tasks.filter { selected.contains($0["notifySessionId"] as? String ?? "") }.count
            if count > 0 { notifications += count; fingerprints.append(manifest.file.path + ":" + (try digestTree(manifest.file))) }
        }
        return ScheduledRunRemovalPreview(runs: runs, notificationReferences: notifications, fingerprint: sha(Data(fingerprints.sorted().joined(separator: "\n").utf8)))
    }

    public func removeScheduledRuns(_ preview: ScheduledRunRemovalPreview, allowOpenSessions: Bool = false) throws -> Outcome {
        return try mutate("移除任务运行历史", configuration: false, allowOpenSessions: allowOpenSessions, countLabel: "移除运行记录", countUnit: "条") { tx in
            let ids = preview.runs.map(\.id), selected = Set(ids)
            let current = try previewScheduledRunRemoval(ids: ids)
            guard current.fingerprint == preview.fingerprint else { throw SyncError("运行或任务引用已变化，请重新预览后移除") }
            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            // Tombstones and the ledger are in this same undo journal. A failed operation must
            // not leave irreversible deletion intent behind for the next background archive.
            var deleted = try history.deletedSessions()
            for id in ids { deleted[id.lowercased()] = timestamp }
            try tx.write(["version": 1, "sessions": deleted], to: history.deletionLedger)
            for record in try history.records() where selected.contains(record.id) {
                try tx.writeData(Data(String(timestamp).utf8), to: record.owner.directory.appendingPathComponent("deleted_" + record.id.dropFirst(6)))
                try tx.replace(record.file, with: nil)
            }
            // A notification may point at a run being removed. Detach only that optional
            // reference, keeping the task, its prompt, enabled state and dispatch timestamps.
            for manifest in try taskManifests() {
                var changed = false
                let tasks = manifest.tasks.map { task -> [String: Any] in
                    var task = task
                    if selected.contains(task["notifySessionId"] as? String ?? "") { task.removeValue(forKey: "notifySessionId"); changed = true }
                    return task
                }
                if changed { var value = manifest.value; value["scheduledTasks"] = tasks; try tx.write(value, to: manifest.file) }
            }
            try detachScheduleNotifications(ids: selected, transaction: tx)
            return ids.count
        }
    }

    func detachScheduleNotifications(ids: Set<String>, transaction tx: Transaction) throws {
        guard exists(scheduleLedger) else { return }
        var ledger = try readScheduleLedger(), entries = ledger["tasks"] as? [String: [String: Any]] ?? [:], changed = false
        for (id, var entry) in entries {
            guard var definition = entry["definition"] as? [String: Any], ids.contains(definition["notifySessionId"] as? String ?? "") else { continue }
            let previous = try LocalSchedule.fingerprint(definition)
            definition.removeValue(forKey: "notifySessionId"); entry["definition"] = definition
            // Transform only baselines we can prove match the old canonical definition.
            // Reading today's copies into the baseline would swallow unrelated user edits.
            var baselines = entry["copies"] as? [String: String] ?? [:]
            let updated = try LocalSchedule.fingerprint(definition)
            for (owner, hash) in baselines where hash == previous { baselines[owner] = updated }
            entry["copies"] = baselines; entries[id] = entry; changed = true
        }
        if changed { ledger["tasks"] = entries; try tx.write(ledger, to: scheduleLedger) }
    }
}
