import Foundation

extension Engine {
    var aliasRegistry: URL { state.appendingPathComponent("aliases.json") }

    func aliasKey(id: String, kind: String) -> String { "\(kind):\(id.lowercased())" }

    func profileAliases(in document: [String: Any]) throws -> [String: String] {
        guard let raw = document["aliases"] else { return [:] }
        guard let aliases = raw as? [String: String] else { throw SyncError("配置别名文件格式错误") }
        for (key, name) in aliases {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, ["gateway", "account"].contains(String(parts[0])), uuid(String(parts[1])),
                  try validName(name) == name else { throw SyncError("配置别名文件格式错误") }
        }
        return aliases
    }

    func profileAliases() throws -> [String: String] {
        try profileAliases(in: readJSON(aliasRegistry, optional: true))
    }

    /// App-local display metadata only. Never stop Claude or write its native files.
    public func setProfileAlias(id: String, kind: String, alias: String?) throws -> Outcome {
        guard uuid(id), ["gateway", "account"].contains(kind) else { throw SyncError("配置 ID 或类型无效") }
        let name = try alias.map { try validName($0) }
        return try locked(state) {
            guard !hasPendingOperation else { throw SyncError("需要先完成上次操作") }
            let entries = try kind == "account" ? accounts() : metadata()["entries"] as? [[String: Any]] ?? []
            guard entries.contains(where: { $0["id"] as? String == id }) else { throw SyncError("配置已不存在，请刷新列表后重试。") }
            var document = try readJSON(aliasRegistry, optional: true)
            var aliases = try profileAliases(in: document)
            aliases[aliasKey(id: id, kind: kind)] = name
            document["aliases"] = aliases
            // A single atomic write under the shared lock needs no Claude restart or multi-file journal.
            try atomicJSON(document, aliasRegistry)
            return Outcome(message: name == nil ? "已恢复原名称，立即生效。" : "配置别名已保存，立即生效。", added: 0)
        }
    }
}
