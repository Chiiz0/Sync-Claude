import Foundation

public struct ProfileDeletionPreview: Identifiable {
    public let id: String
    public let kind: String
    public let name: String
    public let fingerprint: String
}

extension Engine {
    func forgottenAccountIDs(in document: [String: Any]) throws -> Set<String> {
        guard let raw = document["forgottenAccounts"] else { return [] }
        guard let ids = raw as? [String], ids.allSatisfy({ uuid($0) }) else { throw SyncError("已删除账号索引格式错误") }
        return Set(ids)
    }

    func forgottenAccountIDs() throws -> Set<String> {
        try forgottenAccountIDs(in: readJSON(registry, optional: true))
    }

    public func profileDeletionPreview(id: String, kind: String) throws -> ProfileDeletionPreview {
        guard uuid(id), ["gateway", "account"].contains(kind) else { throw SyncError("配置 ID 或类型无效") }
        try checkCompatibility(configuration: kind == "gateway")
        guard !hasPendingOperation else { throw SyncError("需要先完成上次操作") }
        return try deletionPreview(id: id, kind: kind)
    }

    // Also called inside the transaction after Claude has stopped; a pending journal is then expected.
    func deletionPreview(id: String, kind: String) throws -> ProfileDeletionPreview {
        let meta = try metadata(), mode = try mode()
        let entries = try kind == "account" ? accounts() : meta["entries"] as? [[String: Any]] ?? []
        let matches = entries.filter { $0["id"] as? String == id }
        guard matches.count == 1, let entry = matches.first else { throw SyncError("配置不存在或索引重复，请刷新列表。") }
        let target: URL
        if kind == "account" {
            guard let account = entry["account"] as? String, uuid(account),
                  entries.filter({ $0["account"] as? String == account }).count == 1 else { throw SyncError("官方账号索引不明确，未删除。") }
            let retainedAccount = try accountID()
            guard !(mode == "1p" && account == retainedAccount) else { throw SyncError("此官方账号正在使用，请先切换到其他账号或 API 配置。") }
            target = state.appendingPathComponent("accounts/\(id)")
        } else {
            guard !(mode == "3p" && meta["appliedId"] as? String == id) else { throw SyncError("此 API 配置正在使用，请先切换到其他配置。") }
            target = library.appendingPathComponent(id + ".json")
        }
        let alias = try profileAliases()[aliasKey(id: id, kind: kind)]
        let name = alias ?? entry["name"] as? String ?? (kind == "account" ? "官方账号" : "API 配置")
        let contents = try exists(target) ? digestTree(target) : "missing"
        let fingerprint = try sha(jsonData(["entry": entry, "contents": contents, "name": name]))
        return ProfileDeletionPreview(id: id, kind: kind, name: name, fingerprint: fingerprint)
    }

    public func deleteProfile(_ preview: ProfileDeletionPreview, allowOpenSessions: Bool = false) throws -> Outcome {
        let current = try profileDeletionPreview(id: preview.id, kind: preview.kind)
        guard current.fingerprint == preview.fingerprint else { throw SyncError("配置已变化，请重新检查后删除。") }
        return try mutate("删除配置", configuration: preview.kind == "gateway", launch: false, allowOpenSessions: allowOpenSessions, countLabel: "移除配置", countUnit: "个") { tx in
            let current = try deletionPreview(id: preview.id, kind: preview.kind)
            guard current.fingerprint == preview.fingerprint else { throw SyncError("配置已变化，请重新检查后删除。") }
            if preview.kind == "account" {
                var document = try readJSON(registry)
                let entries = try accounts()
                guard let account = entries.first(where: { $0["id"] as? String == preview.id })?["account"] as? String else { throw SyncError("官方账号索引无效") }
                var forgotten = try forgottenAccountIDs(in: document)
                forgotten.insert(account)
                document["accounts"] = entries.filter { $0["id"] as? String != preview.id }
                document["forgottenAccounts"] = forgotten.sorted()
                try tx.write(document, to: registry)
                let snapshots = state.appendingPathComponent("accounts/\(preview.id)")
                if exists(snapshots) { try tx.replace(snapshots, with: nil) }
                if exists(usageCache) {
                    var usage = try cachedUsage(); usage.removeValue(forKey: account)
                    try tx.write(JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)), to: usageCache)
                }
            } else {
                var meta = try metadata()
                meta["entries"] = (meta["entries"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != preview.id }
                if meta["appliedId"] as? String == preview.id { meta.removeValue(forKey: "appliedId") }
                try tx.write(meta, to: library.appendingPathComponent("_meta.json"))
                let config = library.appendingPathComponent(preview.id + ".json")
                if exists(config) { try tx.replace(config, with: nil) }
            }
            if exists(aliasRegistry) {
                var document = try readJSON(aliasRegistry)
                var aliases = try profileAliases(in: document)
                aliases.removeValue(forKey: aliasKey(id: preview.id, kind: preview.kind))
                document["aliases"] = aliases
                try tx.write(document, to: aliasRegistry)
            }
            return 1
        }
    }
}
