import Foundation

public struct SessionInfo: Codable, Identifiable {
    public let id: String
    public let title: String
    public let project: String
    public let lastActivity: Double
    public let transcriptAvailable: Bool
    public let archived: Bool
    public let initializing: Bool
    public let scheduledTaskID: String?
}
struct Owner: Hashable {
    let profile: String
    let account: String
    let organization: String
    let directory: URL
    var key: String { "\(profile)/\(account)/\(organization)" }
}
struct Record {
    let owner: Owner
    let file: URL
    let value: [String: Any]
    var id: String { value["sessionId"] as! String }
    var activity: Double { (value["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0 }
    var initializing: Bool { isInitializingCodeRecord(value) }
}

// Desktop persists a placeholder before starting the CLI. It is not a broken record.
func isInitializingCodeRecord(_ value: [String: Any]) -> Bool {
    guard value["cliSessionId"] == nil || value["cliSessionId"] is NSNull,
          let pending = value["pendingFirstStart"] as? [String: Any],
          let since = pending["since"] as? Double, since.isFinite, since > 0,
          pending["options"] is [String: Any] else { return false }
    return true
}

public struct LiveRecordReadPending: LocalizedError {
    public let fileName: String
    public var errorDescription: String? { "Claude 正在写入会话记录，请稍后重试：\(fileName)" }
}

func readNativeRecordJSON(_ file: URL, running: Bool,
                          read: (URL) throws -> Data = { try Data(contentsOf: $0) },
                          pause: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> [String: Any] {
    try safePath(file)
    for attempt in 0..<3 {
        do {
            let data = try read(file)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncError("Code 记录必须是 JSON 对象：\(file.lastPathComponent)")
            }
            return value
        } catch {
            let ns = error as NSError
            let retryable = ns.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, 3840].contains(ns.code)
            guard running && retryable else { throw error }
            if attempt < 2 { pause(attempt == 0 ? 0.025 : 0.075); continue }
            let modified = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
            if modified == nil || abs(modified!.timeIntervalSinceNow) < 2 {
                throw LiveRecordReadPending(fileName: file.lastPathComponent)
            }
            throw SyncError("Code 记录无法读取：\(file.lastPathComponent)。请检查该记录；其他归档仍保留。")
        }
    }
    preconditionFailure("unreachable")
}

func uuid(_ value: String) -> Bool { UUID(uuidString: value) != nil && !value.contains("/") }
func validSession(_ value: String) -> Bool { value.hasPrefix("local_") && uuid(String(value.dropFirst(6))) }

final class History {
    let support: URL
    let home: URL
    let vault: URL
    let isRunning: () -> Bool
    // A per-process optimization, never a permanent migration-complete flag. A
    // restart rechecks all folders; old versions can add copies at any time.
    var compactedTranscriptInventories: [URL: String] = [:]
    init(support: URL, home: URL, state: URL, isRunning: @escaping () -> Bool = { false }) {
        self.support = support; self.home = home; self.vault = state.appendingPathComponent("history")
        self.isRunning = isRunning
    }
    func owners() throws -> [Owner] {
        var owners: [Owner] = []
        for profile in ["Claude", "Claude-3p"] {
            let root = support.appendingPathComponent("\(profile)/claude-code-sessions")
            try safePath(root)
            guard exists(root) else { continue }
            for account in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where uuid(account.lastPathComponent) {
                try safePath(account)
                for org in try fm.contentsOfDirectory(at: account, includingPropertiesForKeys: [.isDirectoryKey]) where uuid(org.lastPathComponent) {
                    try safePath(org)
                    guard (try org.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
                    owners.append(Owner(profile: profile, account: account.lastPathComponent, organization: org.lastPathComponent, directory: org))
                }
            }
        }
        return owners.sorted { $0.key < $1.key }
    }
    func records() throws -> [Record] {
        var records: [Record] = []
        for owner in try owners() {
            for file in try fm.contentsOfDirectory(at: owner.directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("local_") {
                let value = try readNativeRecordJSON(file, running: isRunning())
                guard let id = value["sessionId"] as? String, validSession(id), file.lastPathComponent == id + ".json",
                      let cwd = value["cwd"] as? String, cwd.hasPrefix("/"),
                      isInitializingCodeRecord(value) || (value["cliSessionId"] as? String).map(uuid) == true else {
                    throw SyncError("发现不支持的 Code 记录格式，未修改原记录：\(file.lastPathComponent)")
                }
                // SSH/cloud records require their original remote context. Never relabel them as local.
                if value["sshHost"] != nil || value["remoteSessionId"] != nil || value["environmentId"] != nil { continue }
                records.append(Record(owner: owner, file: file, value: value))
            }
        }
        return records
    }
    func transcripts() throws -> [String: URL] {
        let root = home.appendingPathComponent(".claude/projects")
        try safePath(root)
        guard exists(root) else { return [:] }
        var result: [String: URL] = [:]
        for project in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            try safePath(project)
            guard (try project.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
            for file in try fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" && uuid(file.deletingPathExtension().lastPathComponent) {
                try safePath(file)
                let id = file.deletingPathExtension().lastPathComponent
                if let previous = result[id], try sha(Data(contentsOf: previous)) != sha(Data(contentsOf: file)) {
                    throw SyncError("同一会话 ID 出现在两个不同的历史文件中；需先处理冲突。")
                }
                result[id] = file
            }
        }
        return result
    }
    func ingest(preferredOwners: Set<String> = []) throws -> Int {
        // Reclaim legacy copies before allocating another full transcript, even if
        // reading the current Desktop records will fail later in this operation.
        try compactArchivedTranscripts().checkFailures()
        let deleted = try rememberDeletions()
        let records = try records(), transcripts = try transcripts()
        try privateDir(vault)
        var index = try readJSON(vault.appendingPathComponent("index.json"), optional: true)
        for record in records where !record.initializing {
            let bytes = try jsonData(record.value), hash = sha(bytes)
            let version = vault.appendingPathComponent("records/\(record.id)/\(hash).json")
            if !exists(version) { try atomicData(bytes, version) }
            let old = index[record.id] as? [String: Any]
            let last = old?["lastActivity"] as? Double ?? -1
            let oldPreferred = (old?["owner"] as? String).map(preferredOwners.contains) ?? false
            if record.activity > last || record.activity == last && (!oldPreferred || preferredOwners.contains(record.owner.key)) {
                index[record.id] = ["hash": hash, "owner": record.owner.key, "lastActivity": record.activity]
            }
            var ids = record.value["priorCliSessionIds"] as? [String] ?? []
            ids.append(record.value["cliSessionId"] as! String)
            for id in Set(ids) where uuid(id) {
                guard let source = transcripts[id] else { continue }
                // A live JSONL may be mid-append: keep complete prefixes only. Never rewrite the source.
                var content = try Data(contentsOf: source)
                if let lastLF = content.lastIndex(of: 10) { content = content.prefix(through: lastLF) } else { continue }
                let hash = sha(content), copy = vault.appendingPathComponent("transcripts/\(id)/\(hash).jsonl")
                if !exists(copy) {
                    try atomicData(content, copy)
                }
            }
        }
        try compactArchivedTranscripts().checkFailures()
        try atomicJSON(index, vault.appendingPathComponent("index.json"))
        return index.keys.filter { deleted[$0.lowercased()] == nil }.count
    }
    func catalog(preferredOwners: Set<String> = []) throws -> [SessionInfo] {
        let deleted = try deletedSessions()
        let index = try readJSON(vault.appendingPathComponent("index.json"), optional: true)
        let ts = try transcripts()
        var infos: [String: SessionInfo] = [:]
        for (id, entry) in index {
            guard validSession(id), let e = entry as? [String: Any], let hash = e["hash"] as? String, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw SyncError("历史索引损坏") }
            if deleted[id.lowercased()] != nil { continue }
            let d = try readJSON(vault.appendingPathComponent("records/\(id)/\(hash).json"))
            infos[id] = info(d, ts)
        }
        var preferred = Set<String>()
        for (id, raw) in index {
            if let owner = (raw as? [String: Any])?["owner"] as? String, preferredOwners.contains(owner) { preferred.insert(id) }
        }
        for record in try records() {
            if deleted[record.id.lowercased()] != nil { continue }
            let activity = infos[record.id]?.lastActivity ?? -1
            if record.activity > activity || record.activity == activity && (!preferred.contains(record.id) || preferredOwners.contains(record.owner.key)) {
                infos[record.id] = info(record.value, ts)
                if preferredOwners.contains(record.owner.key) { preferred.insert(record.id) } else { preferred.remove(record.id) }
            }
        }
        return infos.values.sorted { $0.lastActivity > $1.lastActivity }
    }
    func info(_ d: [String: Any], _ ts: [String: URL]) -> SessionInfo {
        SessionInfo(id: d["sessionId"] as? String ?? "", title: d["title"] as? String ?? "未命名会话", project: d["originCwd"] as? String ?? d["cwd"] as? String ?? "", lastActivity: (d["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0, transcriptAvailable: ts[d["cliSessionId"] as? String ?? ""] != nil, archived: d["isArchived"] as? Bool ?? false, initializing: isInitializingCodeRecord(d), scheduledTaskID: d["scheduledTaskId"] as? String)
    }
    // Reconcile shared state independently from account-local settings and permissions.
    func merge(from sources: [Owner] = [], into targets: [Owner], transaction: Transaction) throws -> Int {
        let deleted = try deletedSessions()
        let index = try readJSON(vault.appendingPathComponent("index.json"), optional: true)
        let ts = try transcripts()
        let current = try records()
        let byID = Dictionary(grouping: current.filter { !$0.initializing }, by: \.id)
        let sourceKeys = Set(sources.map(\.key))
        let oldLedger = try readJSON(sessionStateFile, optional: true)
        var ledger = try SessionStateLedger(oldLedger)
        ledger.entries = ledger.entries.filter { deleted[$0.key.lowercased()] == nil }
        let lineage = SessionLineageResolver(vault: vault, records: current)
        let linked = Dictionary(grouping: current.filter { $0.value["scheduledTaskId"] is String }, by: \.id)
        var writes: [(target: URL, value: [String: Any], added: Bool, repaired: Bool)] = []
        var graphs: [Owner: [String: [String: Any]]] = [:], starts: [Owner: Set<String>] = [:]
        for record in current where deleted[record.id.lowercased()] == nil {
            graphs[record.owner, default: [:]][record.id.lowercased()] = record.value
        }
        let allowed: Set<String> = ["sessionId", "cliSessionId", "cwd", "originCwd", "title", "titleSource", "createdAt", "lastActivityAt", "model", "effort", "isArchived", "completedTurns", "priorCliSessionIds", "scheduledTaskId"]
        for (id, entry) in index.sorted(by: { $0.key < $1.key }) {
            guard validSession(id), let e = entry as? [String: Any], let hash = e["hash"] as? String, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw SyncError("历史索引损坏") }
            if deleted[id.lowercased()] != nil { continue }
            let bytes = try Data(contentsOf: vault.appendingPathComponent("records/\(id)/\(hash).json"))
            guard sha(bytes) == hash, var original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  original["sessionId"] as? String == id,
                  let archivedCLI = original["cliSessionId"] as? String, uuid(archivedCLI) else { continue }
            let copies = byID[id] ?? []
            let continuation = try SessionContinuation([original] + copies.map(\.value))
            if let trackedCLI = ledger.entries[id]?["cli"] as? String,
               try !continuation.includes(original["cliSessionId"] as! String, trackedCLI),
               let tracked = copies.first(where: { $0.value["cliSessionId"] as? String == trackedCLI }) {
                original = tracked.value
            }
            original = try continuation.latest(from: original)
            let cli = original["cliSessionId"] as! String
            let chain = try continuation.ancestors(of: cli)
            guard ts[cli] != nil else {
                if copies.contains(where: { record in
                    targets.contains(record.owner) && record.value["cliSessionId"] as? String != cli
                }) { throw SyncError("最新接续正文缺失，已保留旧会话，请先恢复正文后重试。") }
                continue
            }
            let eligible = try copies.filter { try continuation.includes(cli, $0.value["cliSessionId"] as! String) }
            let completeContinuation = chain.allSatisfy { ts[$0] != nil } && eligible.allSatisfy {
                $0.value["cliSessionId"] as? String == cli || $0.value["cwd"] as? String == original["cwd"] as? String
            }
            let relation: [String: Any]
            if ledger.entries[id] != nil {
                // The baseline already distinguishes a deliberate top-level state
                // from a legacy import. Stale archives cannot arbitrate it again.
                // Retain portable labels for new copies; resolve/apply below still
                // decides the shared parentage from the baseline and observed edits.
                relation = try SessionLineage.portable(original, session: id)
            } else {
                let preferredLineage = eligible.first { sourceKeys.contains($0.owner.key) && SessionLineage.hasMetadata($0.value) }
                relation = try preferredLineage.map { try SessionLineage.portable($0.value, session: id) }
                    ?? lineage.resolve(session: id, cli: cli)
            }
            var fallback = original
            for key in SessionLineage.keys { fallback.removeValue(forKey: key) }
            fallback.merge(relation) { _, new in new }
            let shared = try ledger.resolve(id: id, cli: cli, copies: eligible, sources: sourceKeys,
                                            fallback: SessionStateLedger.state(fallback, session: id), continuation: continuation)
            let taskIDs = Set((linked[id] ?? []).filter { $0.value["cliSessionId"] as? String == cli }.compactMap { $0.value["scheduledTaskId"] as? String })
            guard taskIDs.count <= 1 else { throw SyncError("会话 \(id) 的定时任务关联冲突，请先检查各账号记录。") }
            if let task = taskIDs.first { original["scheduledTaskId"] = task }
            for owner in targets {
                let target = owner.directory.appendingPathComponent(id + ".json")
                let tombstone = owner.directory.appendingPathComponent("deleted_" + id.dropFirst(6))
                if exists(tombstone) { continue }
                if exists(target) {
                    var existing = try readJSON(target)
                    guard existing["sessionId"] as? String == id,
                          let existingCLI = existing["cliSessionId"] as? String,
                          existing["sshHost"] == nil, existing["remoteSessionId"] == nil,
                          existing["environmentId"] == nil else { continue }
                    guard try continuation.includes(cli, existingCLI) else { continue }
                    let before = try jsonData(existing)
                    let oldRelation = try SessionStateLedger.relationship(existing, session: id)
                    if existingCLI != cli {
                        guard completeContinuation, existing["cwd"] as? String == original["cwd"] as? String else {
                            throw SyncError("会话接续正文不完整或项目路径已变化，未更新正文指向。")
                        }
                        existing["cliSessionId"] = cli
                        existing["priorCliSessionIds"] = chain
                        existing["lastActivityAt"] = max(existing["lastActivityAt"] as? Double ?? 0, original["lastActivityAt"] as? Double ?? 0)
                        if let turns = original["completedTurns"] { existing["completedTurns"] = turns }
                        transaction.continuationRepairs += 1
                    } else if !chain.isEmpty, existing["priorCliSessionIds"] as? [String] != chain {
                        guard completeContinuation else { throw SyncError("会话接续正文不完整或项目路径已变化，未更新历史链。") }
                        existing["priorCliSessionIds"] = chain
                    }
                    if existing["scheduledTaskId"] == nil, let task = original["scheduledTaskId"] as? String,
                       LocalSchedule.validID(task) {
                        existing["scheduledTaskId"] = task
                    }
                    try SessionStateLedger.apply(shared, to: &existing, id: id)
                    let repaired = try jsonData(oldRelation) != jsonData(SessionStateLedger.relationship(existing, session: id))
                    if try before != jsonData(existing) {
                        writes.append((target, existing, false, repaired))
                        graphs[owner, default: [:]][id.lowercased()] = existing
                        starts[owner, default: []].insert(id.lowercased())
                        transaction.sessionStateUpdates += 1
                    }
                    try ledger.record(id: id, owner: owner.key, value: existing)
                    continue
                }
                guard completeContinuation else { throw SyncError("会话接续正文不完整或项目路径已变化，未导入会话。") }
                var copy = original.filter { allowed.contains($0.key) }
                copy.merge(relation) { _, new in new }
                try SessionStateLedger.apply(shared, to: &copy, id: id)
                copy["permissionMode"] = "default"
                copy["remoteControlAutoEligible"] = false
                graphs[owner, default: [:]][id.lowercased()] = copy
                starts[owner, default: []].insert(id.lowercased())
                writes.append((target, copy, true, false))
                try ledger.record(id: id, owner: owner.key, value: copy)
            }
        }
        // Check each resulting workspace before writing any of its planned records. Missing
        // or deleted parents remain absent; a relationship never resurrects a deleted session.
        for owner in targets {
            try SessionLineage.validateGraph(graphs[owner] ?? [:], startingAt: starts[owner] ?? [])
        }
        for write in writes {
            try transaction.write(write.value, to: write.target)
            if write.repaired { transaction.lineageRepairs += 1 }
        }
        if !targets.isEmpty, try jsonData(oldLedger) != jsonData(ledger.document) {
            try transaction.write(ledger.document, to: sessionStateFile)
        }
        return writes.filter(\.added).count
    }
}
