import Foundation

/// A Desktop session may continue in a new CLI transcript. Activity timestamps alone
/// cannot order that chain: an older account can reopen an ancestor after a switch.
struct SessionContinuation {
    let values: [[String: Any]]
    let parents: [String: [String]]

    init(_ values: [[String: Any]]) throws {
        self.values = values
        var parents: [String: [String]] = [:]
        for value in values {
            guard let cli = value["cliSessionId"] as? String, uuid(cli) else { continue }
            let prior: [String]
            if let raw = value["priorCliSessionIds"] {
                guard let ids = raw as? [String], ids.allSatisfy(uuid) else { throw SyncError("会话正文接续记录格式无效，已停止同步。") }
                prior = ids
            } else { prior = [] }
            for id in prior where !(parents[cli] ?? []).contains(id) { parents[cli, default: []].append(id) }
        }
        self.parents = parents
        for cli in parents.keys { _ = try ancestors(of: cli) }
    }

    func ancestors(of cli: String) throws -> [String] {
        var result: [String] = [], visiting = Set<String>(), visited = Set<String>()
        func visit(_ id: String) throws {
            guard !visiting.contains(id) else { throw SyncError("会话正文接续关系存在循环，已停止同步。") }
            guard visited.insert(id).inserted else { return }
            visiting.insert(id)
            for parent in parents[id] ?? [] {
                try visit(parent)
                if !result.contains(parent) { result.append(parent) }
            }
            visiting.remove(id)
        }
        try visit(cli)
        return result
    }

    func includes(_ descendant: String, _ ancestor: String) throws -> Bool {
        if descendant == ancestor { return true }
        return try ancestors(of: descendant).contains(ancestor)
    }

    func latest(from original: [String: Any]) throws -> [String: Any] {
        let base = original["cliSessionId"] as! String
        let baseFamily = Set(try ancestors(of: base) + [base])
        let candidates = try values.filter { value in
            guard let cli = value["cliSessionId"] as? String else { return false }
            // Include sibling continuations too. Starting from the newest timestamp
            // must not hide a parallel branch that descends from the same ancestor.
            return try !baseFamily.isDisjoint(with: Set(ancestors(of: cli) + [cli]))
        }
        let ids = Set(candidates.compactMap { $0["cliSessionId"] as? String })
        let tips = try ids.filter { id in
            for other in ids where other != id { if try includes(other, id) { return false } }
            return true
        }
        guard tips.count == 1, let tip = tips.first else { throw SyncError("同一会话存在多个正文接续分支，请先确认要继续的会话；原正文均保留。") }
        var result = candidates.filter { $0["cliSessionId"] as? String == tip }.max {
            ($0["lastActivityAt"] as? Double ?? 0) < ($1["lastActivityAt"] as? Double ?? 0)
        } ?? original
        let prior = try ancestors(of: tip)
        if !prior.isEmpty { result["priorCliSessionIds"] = prior }
        return result
    }
}

/// Only shared state is reconciled. The ledger contains IDs, flags and fingerprints;
/// it does not duplicate titles, prompts, credentials or transcript contents.
struct SessionStateLedger {
    var entries: [String: [String: Any]]

    init(_ document: [String: Any]) throws {
        guard document.isEmpty || document["version"] as? Int == 1 && document["sessions"] is [String: [String: Any]] else {
            throw SyncError("会话状态同步基线无法识别，已停止同步。")
        }
        entries = document["sessions"] as? [String: [String: Any]] ?? [:]
        for (id, entry) in entries {
            guard validSession(id), let cli = entry["cli"] as? String, uuid(cli),
                  LocalSchedule.bool(entry["archived"]), let lineage = entry["lineage"] as? [String: Any],
                  let copies = entry["copies"] as? [String: [String: String]],
                  copies.allSatisfy({ owner, fields in
                      let parts = owner.split(separator: "/").map(String.init)
                      return parts.count == 3 && ["Claude", "Claude-3p"].contains(parts[0]) && uuid(parts[1]) && uuid(parts[2])
                          && Set(fields.keys) == ["archived", "lineage"]
                          && fields.values.allSatisfy { $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
                  }) else { throw SyncError("会话状态同步基线损坏，已停止同步。") }
            _ = try Self.relationship(lineage, session: id)
        }
    }

    var document: [String: Any] { ["version": 1, "sessions": entries] }

    static func relationship(_ value: [String: Any], session: String) throws -> [String: Any] {
        var result = try SessionLineage.portable(value, session: session)
        if result["lineageDetached"] as? Bool == false { result.removeValue(forKey: "lineageDetached") }
        if var link = result["spawnedFrom"] as? [String: Any] {
            link.removeValue(forKey: "title"); link.removeValue(forKey: "name")
            for key in SessionLineage.flags where link[key] as? Bool == false { link.removeValue(forKey: key) }
            if var deleted = link["deletedParent"] as? [String: Any] { deleted.removeValue(forKey: "title"); link["deletedParent"] = deleted }
            result["spawnedFrom"] = link
        }
        return result
    }

    static func state(_ value: [String: Any], session: String) throws -> [String: Any] {
        if let archived = value["isArchived"], !LocalSchedule.bool(archived) { throw SyncError("会话归档状态格式无效，已停止同步。") }
        return ["archived": value["isArchived"] as? Bool ?? false, "lineage": try relationship(value, session: session)]
    }

    static func fingerprints(_ state: [String: Any]) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: ["archived", "lineage"].map { ($0, try sha(jsonData([$0: state[$0]!]))) })
    }

    mutating func resolve(id: String, cli: String, copies: [Record], sources: Set<String>,
                          fallback: [String: Any], continuation: SessionContinuation) throws -> [String: Any] {
        let observations = try copies.map { ($0.owner.key, try Self.state($0.value, session: id)) }
        let previous = entries[id]
        if let oldCLI = previous?["cli"] as? String, try !continuation.includes(cli, oldCLI) {
            throw SyncError("会话正文与已同步的接续链冲突，已保留各账号记录。")
        }
        let baselines = previous?["copies"] as? [String: [String: String]] ?? [:]
        var resolved: [String: Any] = [:]
        for field in ["archived", "lineage"] {
            var changes: [String: Any] = [:]
            if let previous {
                for (owner, state) in observations {
                    let hash = try Self.fingerprints(state)[field]!
                    // Newly discovered/restored account copies are not evidence of a new edit.
                    if let baseline = baselines[owner]?[field], baseline != hash { changes[hash] = state[field]! }
                }
                guard changes.count <= 1 else { throw SyncError("会话 \(id) 的\(field == "archived" ? "归档状态" : "父子关联")在多个工作区有冲突修改；请在 Claude 中统一后重试。") }
                resolved[field] = changes.values.first ?? previous[field]!
            } else {
                var preferred = observations.filter { sources.contains($0.0) }
                // On migration, a legacy copy with all relationship fields stripped is
                // unknown; recover its verified relation as older releases already did.
                if field == "lineage" { preferred = preferred.filter { !($0.1[field] as! [String: Any]).isEmpty } }
                for (_, state) in preferred { changes[try Self.fingerprints(state)[field]!] = state[field]! }
                guard changes.count <= 1 else { throw SyncError("源账号多个工作区的会话状态不同，请先统一归档状态或父子关联。") }
                resolved[field] = changes.values.first ?? fallback[field]!
            }
        }
        var observed = baselines
        for (owner, state) in observations { observed[owner] = try Self.fingerprints(state) }
        entries[id] = ["cli": cli, "archived": resolved["archived"]!, "lineage": resolved["lineage"]!, "copies": observed]
        return resolved
    }

    mutating func record(id: String, owner: String, value: [String: Any]) throws {
        guard var entry = entries[id] else { return }
        var copies = entry["copies"] as! [String: [String: String]]
        copies[owner] = try Self.fingerprints(Self.state(value, session: id))
        entry["copies"] = copies; entries[id] = entry
    }

    static func apply(_ state: [String: Any], to value: inout [String: Any], id: String) throws {
        let archived = state["archived"] as! Bool
        if (value["isArchived"] as? Bool ?? false) != archived { value["isArchived"] = archived }
        let relation = state["lineage"] as! [String: Any]
        guard try jsonData(relationship(value, session: id)) != jsonData(relation) else { return }
        // Keep the destination's own nonportable runtime fields and cosmetic labels
        // only when the parent is unchanged; never import them from another account.
        var portable = relation
        if var link = relation["spawnedFrom"] as? [String: Any], let old = value["spawnedFrom"] as? [String: Any],
           link["sessionId"] as? String == old["sessionId"] as? String {
            let shared = Set(["sessionId", "taskId", "deletedParent"] + SessionLineage.flags)
            for (key, item) in old where !shared.contains(key) { link[key] = item }
            portable["spawnedFrom"] = link
        }
        for key in SessionLineage.keys { value.removeValue(forKey: key) }
        value.merge(portable) { _, new in new }
    }
}

extension History {
    var sessionStateFile: URL { vault.appendingPathComponent("session-state.json") }

    /// A directory restoration is not a new archive/reparent action. Rebase its
    /// observed fingerprints while retaining the canonical state for the next sync.
    func noteRestoredState(ownerKey: String, transaction: Transaction) throws {
        guard exists(sessionStateFile) else { return }
        let before = try readJSON(sessionStateFile)
        var ledger = try SessionStateLedger(before)
        for record in try records() where record.owner.key == ownerKey && !record.initializing {
            try ledger.record(id: record.id, owner: ownerKey, value: record.value)
        }
        if try jsonData(before) != jsonData(ledger.document) { try transaction.write(ledger.document, to: sessionStateFile) }
    }
}
