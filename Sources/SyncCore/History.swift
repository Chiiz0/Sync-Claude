import Foundation

public struct SessionInfo: Codable, Identifiable {
    public let id: String
    public let title: String
    public let project: String
    public let lastActivity: Double
    public let transcriptAvailable: Bool
    public let archived: Bool
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
}

func uuid(_ value: String) -> Bool { UUID(uuidString: value) != nil && !value.contains("/") }
func validSession(_ value: String) -> Bool { value.hasPrefix("local_") && uuid(String(value.dropFirst(6))) }

final class History {
    let support: URL
    let home: URL
    let vault: URL
    init(support: URL, home: URL, state: URL) {
        self.support = support; self.home = home; self.vault = state.appendingPathComponent("history")
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
                let value = try readJSON(file)
                guard let id = value["sessionId"] as? String, validSession(id), file.lastPathComponent == id + ".json",
                      let cli = value["cliSessionId"] as? String, uuid(cli), let cwd = value["cwd"] as? String, cwd.hasPrefix("/") else {
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
    func ingest() throws -> Int {
        let deleted = try rememberDeletions()
        let records = try records(), transcripts = try transcripts()
        try privateDir(vault)
        var index = try readJSON(vault.appendingPathComponent("index.json"), optional: true)
        for record in records {
            let bytes = try jsonData(record.value), hash = sha(bytes)
            let version = vault.appendingPathComponent("records/\(record.id)/\(hash).json")
            if !exists(version) { try atomicData(bytes, version) }
            let old = index[record.id] as? [String: Any]
            let last = old?["lastActivity"] as? Double ?? -1
            if record.activity >= last {
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
                if !exists(copy) { try atomicData(content, copy) }
            }
        }
        try atomicJSON(index, vault.appendingPathComponent("index.json"))
        return index.keys.filter { deleted[$0.lowercased()] == nil }.count
    }
    func catalog() throws -> [SessionInfo] {
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
        for record in try records() {
            if deleted[record.id.lowercased()] != nil { continue }
            if record.activity >= (infos[record.id]?.lastActivity ?? -1) { infos[record.id] = info(record.value, ts) }
        }
        return infos.values.sorted { $0.lastActivity > $1.lastActivity }
    }
    func info(_ d: [String: Any], _ ts: [String: URL]) -> SessionInfo {
        SessionInfo(id: d["sessionId"] as? String ?? "", title: d["title"] as? String ?? "未命名会话", project: d["originCwd"] as? String ?? d["cwd"] as? String ?? "", lastActivity: (d["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0, transcriptAvailable: ts[d["cliSessionId"] as? String ?? ""] != nil, archived: d["isArchived"] as? Bool ?? false)
    }
    // Existing records are never overwritten. Cross-account copies reset permissions and connector state.
    func merge(into targets: [Owner], transaction: Transaction) throws -> Int {
        let deleted = try deletedSessions()
        let index = try readJSON(vault.appendingPathComponent("index.json"), optional: true)
        let ts = try transcripts()
        var added = 0
        let allowed: Set<String> = ["sessionId", "cliSessionId", "cwd", "originCwd", "title", "titleSource", "createdAt", "lastActivityAt", "model", "effort", "isArchived", "completedTurns", "priorCliSessionIds"]
        for (id, entry) in index.sorted(by: { $0.key < $1.key }) {
            guard validSession(id), let e = entry as? [String: Any], let hash = e["hash"] as? String, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw SyncError("历史索引损坏") }
            if deleted[id.lowercased()] != nil { continue }
            let bytes = try Data(contentsOf: vault.appendingPathComponent("records/\(id)/\(hash).json"))
            guard sha(bytes) == hash, let original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let cli = original["cliSessionId"] as? String, ts[cli] != nil else { continue }
            for owner in targets {
                let target = owner.directory.appendingPathComponent(id + ".json")
                let tombstone = owner.directory.appendingPathComponent("deleted_" + id.dropFirst(6))
                if exists(target) || exists(tombstone) { continue }
                var copy = original.filter { allowed.contains($0.key) }
                copy["permissionMode"] = "default"
                copy["remoteControlAutoEligible"] = false
                try transaction.write(copy, to: target); added += 1
            }
        }
        return added
    }
}
