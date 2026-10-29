import Foundation

public struct ModelSelectionInfo: Codable, Identifiable {
    public let id: String
    public let model: String
    public let issue: String?
}
public struct GatewayContextInfo: Codable, Identifiable {
    public let id: String
    public let defaultModel: String?
    public let prefers1m: Bool
    public let supports1m: Bool
    public let fixedDefault: Bool
    public let selections: [ModelSelectionInfo]
    public let issues: [String]
    public let repairBlockedReason: String?
    public let fingerprint: String
}

extension Engine {
    func modelEntries(_ config: [String: Any]) -> [[String: Any]] {
        (config["inferenceModels"] as? [Any] ?? []).compactMap { value in
            if let name = value as? String { return ["name": name] }
            return value as? [String: Any]
        }
    }
    func supports1m(_ model: [String: Any]) -> Bool {
        model["supports1m"] as? Bool == true || (model["name"] as? String)?.hasSuffix("[1m]") == true
    }
    func bareModel(_ name: String) -> String { name.hasSuffix("[1m]") ? String(name.dropLast(4)) : name }
    func gatewaySelectionFiles() throws -> [URL] {
        let config = try readJSON(third.appendingPathComponent("config.json"), optional: true)
        guard let account = config["lastKnownAccountUuid"] as? String, uuid(account) else { return [] }
        let root = third.appendingPathComponent("local-agent-mode-sessions/\(account)")
        try safePath(root)
        guard exists(root) else { return [] }
        var files: [URL] = []
        for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where uuid(directory.lastPathComponent) {
            let file = directory.appendingPathComponent("cowork_account_settings.json")
            try safePath(file)
            if exists(file) { files.append(file) }
        }
        return files.sorted { $0.path < $1.path }
    }
    func selectionIssue(_ selected: String, models: [[String: Any]], globalPreference: Bool) -> String? {
        let bare = bareModel(selected)
        guard let model = models.first(where: { bareModel($0["name"] as? String ?? "") == bare }) else { return "保存的模型已不在当前配置列表中" }
        if supports1m(model), (globalPreference || model["prefer1m"] as? Bool == true || (model["name"] as? String)?.hasSuffix("[1m]") == true), !selected.hasSuffix("[1m]") {
            return "保存的标准版选择可能覆盖 1M 默认值"
        }
        return nil
    }
    func gatewayContext(id: String) throws -> GatewayContextInfo {
        guard uuid(id) else { throw SyncError("API 配置 ID 无效") }
        let configFile = library.appendingPathComponent(id + ".json"), config = try readJSON(configFile)
        let models = modelEntries(config), first = models.first
        let capable = first.map { supports1m($0) } ?? false
        let global = config["modelPrefer1mContext"] as? Bool == true
        let preferred = capable && (global || first?["prefer1m"] as? Bool == true || (first?["name"] as? String)?.hasSuffix("[1m]") == true)
        let active = try mode() == "3p" && metadata()["appliedId"] as? String == id
        let files = active ? try gatewaySelectionFiles() : []
        var selections: [ModelSelectionInfo] = [], issues: [String] = [], fingerprints = [try digestTree(configFile)]
        if !capable { issues.append("默认模型未声明支持 1M；需先确认服务能力，不能盲目强制。") }
        else if !preferred { issues.append("默认模型支持 1M，但尚未优先使用。") }
        for file in files {
            fingerprints.append(try digestTree(file))
            let settings = try readJSON(file)
            if let raw = settings["__model_selector_state"], !(raw is [String: Any]) { throw SyncError("账号模型选择格式无法识别") }
            let state = settings["__model_selector_state"] as? [String: Any] ?? [:]
            for surface in ["code", "cowork", "chat"] {
                guard let row = state[surface] as? [String: Any], let model = row["model"] as? String else { continue }
                let issue = models.isEmpty ? nil : selectionIssue(model, models: models, globalPreference: global)
                selections.append(ModelSelectionInfo(id: file.deletingLastPathComponent().lastPathComponent + "/" + surface, model: model, issue: issue))
                if let issue { issues.append("\(surface.capitalized)：\(issue)") }
            }
        }
        let blocked: String? = !active ? "切换到此 API 配置后才能检查和修复账号选择。" : files.count > 1 ? "此 API 账号有多个组织设置，无法确定修改目标。" : !capable ? "仅能修复已声明支持 1M 的默认模型。" : nil
        return GatewayContextInfo(id: id, defaultModel: first?["name"] as? String, prefers1m: preferred, supports1m: capable,
            fixedDefault: config["alwaysStartWithDefaultModel"] as? Bool == true, selections: selections, issues: issues,
            repairBlockedReason: blocked, fingerprint: sha(Data(fingerprints.joined(separator: "\n").utf8)))
    }
    public func repairGatewayContext(_ preview: GatewayContextInfo, allowOpenSessions: Bool = false) throws -> Outcome {
        try mutate("修复默认 1M", allowOpenSessions: allowOpenSessions, countLabel: "修正设置", countUnit: "项") { tx in
            let current = try gatewayContext(id: preview.id)
            guard current.fingerprint == preview.fingerprint else { throw SyncError("模型配置已变化，请刷新检查后再修复。") }
            guard current.repairBlockedReason == nil else { throw SyncError(current.repairBlockedReason!) }
            let file = library.appendingPathComponent(preview.id + ".json")
            var config = try readJSON(file), changed = 0
            let models = modelEntries(config)
            if config["modelPrefer1mContext"] as? Bool != true {
                config["modelPrefer1mContext"] = true
                try tx.write(config, to: file); changed += 1
            }
            for settingsFile in try gatewaySelectionFiles() {
                var settings = try readJSON(settingsFile), state = settings["__model_selector_state"] as? [String: Any] ?? [:], touched = false
                for surface in ["code", "cowork", "chat"] {
                    guard var row = state[surface] as? [String: Any], let model = row["model"] as? String,
                          selectionIssue(model, models: models, globalPreference: true) != nil else { continue }
                    row.removeValue(forKey: "model")
                    if row.isEmpty { state.removeValue(forKey: surface) } else { state[surface] = row }
                    touched = true; changed += 1
                }
                if touched { settings["__model_selector_state"] = state; try tx.write(settings, to: settingsFile) }
            }
            return changed
        }
    }
    func newGatewayModels(_ models: [String], prefer1m: Bool) -> [String: Any] {
        var config: [String: Any] = ["modelDiscoveryEnabled": models.isEmpty]
        if prefer1m { config["modelPrefer1mContext"] = true }
        if !models.isEmpty {
            config["inferenceModels"] = models.map { name -> [String: Any] in
                var row: [String: Any] = ["name": name]
                if prefer1m { row["supports1m"] = true; row["prefer1m"] = true }
                return row
            }
        }
        return config
    }
}
