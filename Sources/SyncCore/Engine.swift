import Foundation

public struct ProfileInfo: Codable, Identifiable {
    public var id: String
    public var name: String
    public var originalName: String
    public var alias: String? = nil
    public var kind: String
    public var detail: String
    public var active: Bool
    public var context: GatewayContextInfo? = nil
}
public struct Status: Codable {
    public let version: String
    public let compatible: Bool
    public let running: Bool
    public let workers: Int
    public let mode: String
    public let profiles: [ProfileInfo]
    public let sessions: [SessionInfo]
    public let ownerCount: Int
    public let pendingRecovery: Bool
    public let pendingPurge: Bool
    public let statePath: String
    public let accountRecords: [AccountRecordInfo]
    public let removedAccountRecords: [RemovedAccountRecord]
    public let restoredAccountBackups: [RemovedAccountRecord]
    public let officialUsage: [OfficialUsage]
    public let canSaveOfficialAccount: Bool
}
public struct Outcome: Codable {
    public let message: String
    public let added: Int
}

public final class Engine {
    public let home: URL
    public let support: URL
    public let state: URL
    let process: ClaudeProcess
    let installedVersion: String?
    let history: History
    var first: URL { support.appendingPathComponent("Claude") }
    var third: URL { support.appendingPathComponent("Claude-3p") }
    var library: URL { third.appendingPathComponent("configLibrary") }
    var registry: URL { state.appendingPathComponent("accounts.json") }
    static let identityFiles = ["Cookies", "Cookies-journal", "Network", "Local State", "Local Storage", "Session Storage", "IndexedDB", "WebStorage", "Service Worker", "Partitions", "config.json", "config.json.journal", "Preferences"]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, process: ClaudeProcess = MacClaudeProcess(), version: String? = nil) {
        self.home = home; self.support = home.appendingPathComponent("Library/Application Support")
        self.state = support.appendingPathComponent("SyncClaude")
        self.process = process; self.installedVersion = version
        self.history = History(support: support, home: home, state: state)
    }
    public var version: String {
        if let installedVersion { return installedVersion }
        for path in ["/Applications/Claude.app/Contents/Info.plist", home.appendingPathComponent("Applications/Claude.app/Contents/Info.plist").path] {
            if let data = fm.contents(atPath: path), let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let v = p["CFBundleShortVersionString"] as? String { return v }
        }
        return "未安装"
    }
    func mode() throws -> String { try readJSON(third.appendingPathComponent("claude_desktop_config.json"), optional: true)["deploymentMode"] as? String ?? "1p" }
    func accountID() throws -> String? {
        let d = try readJSON(first.appendingPathComponent("config.json"), optional: true)
        guard let id = d["lastKnownAccountUuid"] as? String, uuid(id) else { return nil }
        return id
    }
    func syncTargets() throws -> [Owner] {
        let profile = try mode() == "3p" ? "Claude-3p" : "Claude"
        let config = try readJSON(support.appendingPathComponent(profile + "/config.json"), optional: true)
        guard let account = config["lastKnownAccountUuid"] as? String, uuid(account) else { return [] }
        let targets = try history.owners().filter { $0.profile == profile && $0.account == account }
        guard targets.count <= 1 else {
            throw SyncError("当前账号有多个组织目录，无法可靠识别正在使用的组织；已停止同步，原始记录保留。")
        }
        return targets
    }
    func accounts() throws -> [[String: Any]] { try readJSON(registry, optional: true)["accounts"] as? [[String: Any]] ?? [] }
    func metadata() throws -> [String: Any] { try readJSON(library.appendingPathComponent("_meta.json"), optional: true) }
    public func status() throws -> Status {
        let mode = try mode(), meta = try metadata(), currentAccount = try accountID(), aliases = try profileAliases()
        var profiles: [ProfileInfo] = []
        for entry in meta["entries"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, uuid(id) else { throw SyncError("原生配置库包含无效 ID") }
            let config = try readJSON(library.appendingPathComponent(id + ".json"))
            let endpoint = config["inferenceGatewayBaseUrl"] as? String ?? ""
            // Display the host only; endpoints may contain credentials in paths or queries.
            let detail = URL(string: endpoint)?.host ?? config["inferenceProvider"] as? String ?? "原生配置"
            let originalName = entry["name"] as? String ?? "API 配置", alias = aliases[aliasKey(id: id, kind: "gateway")]
            profiles.append(ProfileInfo(id: id, name: alias ?? originalName, originalName: originalName, alias: alias, kind: "gateway", detail: detail, active: mode == "3p" && meta["appliedId"] as? String == id, context: try gatewayContext(id: id)))
        }
        for a in try accounts() {
            guard let id = a["id"] as? String, uuid(id), let account = a["account"] as? String else { throw SyncError("账号索引格式错误") }
            let originalName = a["name"] as? String ?? "官方账号", alias = aliases[aliasKey(id: id, kind: "account")]
            profiles.append(ProfileInfo(id: id, name: alias ?? originalName, originalName: originalName, alias: alias, kind: "account", detail: "官方账号 · 本机登录快照", active: mode == "1p" && currentAccount == account))
        }
        return Status(version: version, compatible: version == "4.29.0", running: process.running, workers: process.workers, mode: mode, profiles: profiles, sessions: try history.catalog(), ownerCount: try history.owners().count, pendingRecovery: hasPendingOperation, pendingPurge: exists(pendingPurge), statePath: state.path, accountRecords: try accountRecords(), removedAccountRecords: try removedAccountRecords(), restoredAccountBackups: try restoredAccountBackups(), officialUsage: try officialUsage(), canSaveOfficialAccount: mode == "1p" && currentAccount != nil)
    }
    public func archive() throws -> Outcome {
        try locked(state) {
            guard !hasPendingOperation else { throw SyncError("需要先完成上次操作") }
            let count = try history.ingest()
            return Outcome(message: "已归档 \(count) 条本地 Code 记录。Claude 原始文件未修改。", added: count)
        }
    }
    func checkCompatibility(configuration: Bool) throws {
        guard version == "4.29.0" else { throw SyncError("当前适配 Claude 4.29.0；检测到 \(version)。只读归档可用，写入需先验证新版格式。") }
        if configuration {
            let managed = URL(fileURLWithPath: "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist")
            if exists(managed) { throw SyncError("检测到 MDM 管理配置；请通过组织配置管理切换。") }
            if try metadata()["hybridPointer"] != nil { throw SyncError("配置由组织账号下发，不能通过本地文件覆盖。") }
        }
    }
    func mutate(_ operation: String, configuration: Bool = true, launch: Bool = true, allowOpenSessions: Bool = false, countLabel: String = "新增共享记录", countUnit: String = "条", body: (Transaction) throws -> Int) throws -> Outcome {
        try locked(state) {
            try checkCompatibility(configuration: configuration)
            guard !hasPendingOperation else { throw SyncError("请先完成上次操作。") }
            let wasRunning = process.running
            try process.stop(allowOpenSessions: allowOpenSessions)
            let transaction: Transaction
            do { transaction = try Transaction(root: state, operation: operation) }
            catch { if wasRunning { try? process.start() }; throw error }
            transaction.beforeWrite = { [process] in
                guard !process.running, process.workers == 0 else { throw SyncError("Claude 重新启动，已停止写入。") }
            }
            do {
                _ = try history.ingest()
                let added = try body(transaction)
                guard !process.running, process.workers == 0 else { throw SyncError("Claude 在操作期间重新启动，停止写入并准备恢复。") }
                try transaction.commit()
                if launch || wasRunning {
                    do { try process.start() }
                    catch { return Outcome(message: "\(operation)已保存；Claude 未能启动。备份已保留，可手动打开 Claude。", added: added) }
                }
                let suffix = (launch || wasRunning) ? "Claude 已重新打开；登录及 API 可用性请在客户端确认。" : "将在下次切换配置时生效。"
                return Outcome(message: "\(operation)完成，\(countLabel) \(added) \(countUnit)。\(suffix)", added: added)
            } catch {
                if process.running {
                    throw SyncError("Claude 意外重新启动；已保留恢复日志。请退出 Claude 后点击“恢复未完成操作”。")
                }
                do { try transaction.rollback() }
                catch { throw SyncError("恢复未完成，备份已保留。请使用“恢复未完成操作”。") }
                if wasRunning { try? process.start() }
                throw error
            }
        }
    }
    func setMode(_ newMode: String, _ tx: Transaction) throws {
        for root in [first, third] {
            let file = root.appendingPathComponent("claude_desktop_config.json")
            var config = try readJSON(file, optional: true)
            config["deploymentMode"] = newMode
            try tx.write(config, to: file)
        }
    }
    func snapshot(name: String?, tx: Transaction, requireLogin: Bool) throws {
        guard let account = try accountID() else {
            if requireLogin { throw SyncError("还没有识别到官方账号。请先在官方模式登录，并进入一次 Code 页面后再保存。") }
            return
        }
        var document = try readJSON(registry, optional: true)
        var forgotten = try forgottenAccountIDs(in: document)
        // An explicit deletion must survive automatic snapshots during later switches/new logins.
        if !requireLogin && forgotten.contains(account) { return }
        var entries = try accounts()
        let index = entries.firstIndex { $0["account"] as? String == account }
        let id = index.flatMap { entries[$0]["id"] as? String } ?? UUID().uuidString.lowercased()
        let snapshotID = UUID().uuidString.lowercased()
        let folder = state.appendingPathComponent("accounts/\(id)/\(snapshotID)")
        try privateDir(folder)
        var files: [String: String] = [:]
        for name in Self.identityFiles {
            let source = first.appendingPathComponent(name)
            if exists(source) { let copy = folder.appendingPathComponent(name); try privateCopy(source, copy); files[name] = try digestTree(copy) }
        }
        // Validate the recorded account independently from the registry before every restoration.
        try atomicJSON(["account": account, "files": files], folder.appendingPathComponent("manifest.json"))
        let previousName = index.flatMap { entries[$0]["name"] as? String }
        let entry: [String: Any] = ["id": id, "name": name ?? previousName ?? "官方账号 \(account.prefix(6))", "account": account, "snapshot": snapshotID, "savedAt": Date().timeIntervalSince1970]
        if let index { entries[index] = entry } else { entries.append(entry) }
        document["accounts"] = entries
        if forgotten.remove(account) != nil { document["forgottenAccounts"] = forgotten.sorted() }
        try tx.write(document, to: registry)
    }
    func restoreAccount(_ id: String, _ tx: Transaction) throws {
        guard let a = try accounts().first(where: { $0["id"] as? String == id }),
              let snapshot = a["snapshot"] as? String, uuid(snapshot), let account = a["account"] as? String else { throw SyncError("未找到保存的账号") }
        let folder = state.appendingPathComponent("accounts/\(id)/\(snapshot)")
        let manifest = try readJSON(folder.appendingPathComponent("manifest.json"))
        let config = try readJSON(folder.appendingPathComponent("config.json"))
        guard manifest["account"] as? String == account, config["lastKnownAccountUuid"] as? String == account,
              let files = manifest["files"] as? [String: String], Set(files.keys).isSubset(of: Set(Self.identityFiles)) else { throw SyncError("账号快照身份校验失败") }
        for (name, hash) in files { guard try digestTree(folder.appendingPathComponent(name)) == hash else { throw SyncError("账号快照校验失败，未切换。") } }
        for name in Self.identityFiles {
            try tx.replace(first.appendingPathComponent(name), with: files[name] == nil ? nil : folder.appendingPathComponent(name))
        }
    }
    public func saveAccount(name: String, allowOpenSessions: Bool = false) throws -> Outcome {
        let name = try validName(name)
        guard try mode() == "1p" else { throw SyncError("当前是第三方 API 模式。请先切到官方登录、登录账号后保存。") }
        return try mutate("保存账号", configuration: false, allowOpenSessions: allowOpenSessions) { tx in try snapshot(name: name, tx: tx, requireLogin: true); return 0 }
    }
    public func switchProfile(id: String, allowOpenSessions: Bool = false) throws -> Outcome {
        guard id == "official" || uuid(id) else { throw SyncError("配置 ID 无效") }
        return try mutate("切换配置", allowOpenSessions: allowOpenSessions) { tx in
            if try mode() == "1p" { try snapshot(name: nil, tx: tx, requireLogin: false) }
            if id == "official" { try setMode("1p", tx) }
            else if try accounts().contains(where: { $0["id"] as? String == id }) { try restoreAccount(id, tx); try setMode("1p", tx) }
            else {
                var meta = try metadata()
                guard (meta["entries"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == id }) else { throw SyncError("配置不存在") }
                _ = try readJSON(library.appendingPathComponent(id + ".json"))
                meta["appliedId"] = id
                try tx.write(meta, to: library.appendingPathComponent("_meta.json"))
                try setMode("3p", tx)
            }
            return try history.merge(into: syncTargets(), transaction: tx)
        }
    }
    public func newLogin(allowOpenSessions: Bool = false) throws -> Outcome {
        try mutate("准备新账号登录", allowOpenSessions: allowOpenSessions) { tx in
            // The first-party slot is backed up even when coming from 3P.
            try snapshot(name: nil, tx: tx, requireLogin: false)
            for name in Self.identityFiles { try tx.replace(first.appendingPathComponent(name), with: nil) }
            try setMode("1p", tx)
            return 0
        }
    }
    public func sync(allowOpenSessions: Bool = false) throws -> Outcome {
        try mutate("同步并重载", configuration: false, allowOpenSessions: allowOpenSessions) { tx in try history.merge(into: syncTargets(), transaction: tx) }
    }
    public func recover() throws -> Outcome {
        try locked(state) {
            guard exists(state.appendingPathComponent("pending.json")) else { return Outcome(message: "没有待恢复的操作", added: 0) }
            try process.stop(allowOpenSessions: false); try Transaction.recover(root: state); try process.start()
            return Outcome(message: "已恢复操作前的配置和登录状态。", added: 0)
        }
    }
    public func addGateway(name: String, endpoint: String, models: [String], auth: String, key: String, helper: String, prefer1m: Bool = false, allowOpenSessions: Bool = false) throws -> Outcome {
        let name = try validName(name)
        guard let url = URLComponents(string: endpoint), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else { throw SyncError("请填写 HTTPS API 地址（本机回环地址可用 HTTP），不要包含用户名、密码或查询参数。") }
        guard ["bearer", "x-api-key"].contains(auth) else { throw SyncError("认证方式无效") }
        guard models.count <= 200, models.allSatisfy({ $0.range(of: "^(anthropic/)?claude-(sonnet|opus|haiku|fable)-[A-Za-z0-9._:-]+$", options: .regularExpression) != nil }) else { throw SyncError("模型名需使用 Claude 桌面端支持的 claude-sonnet/opus/haiku/fable-* 格式。其他模型请先通过兼容网关映射。") }
        guard helper.hasPrefix("/"), fm.isExecutableFile(atPath: helper) else { throw SyncError("凭据助手不可用，请从安装后的 Sync Claude.app 添加配置。") }
        let id = UUID().uuidString.lowercased()
        try CredentialStore.put(id: id, secret: key)
        do {
            return try mutate("添加 API 配置", launch: false, allowOpenSessions: allowOpenSessions) { tx in
                let config: [String: Any] = ["inferenceProvider": "gateway", "inferenceGatewayBaseUrl": endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "inferenceGatewayAuthScheme": auth, "inferenceCredentialKind": "helper-script", "inferenceCredentialHelper": helper, "inferenceCredentialHelperArgs": ["--credential", id], "inferenceCredentialHelperTtlSec": 300, "modelDiscoveryEnabled": models.isEmpty]
                var full = config
                full.merge(newGatewayModels(models, prefer1m: prefer1m)) { _, new in new }
                try tx.write(full, to: library.appendingPathComponent(id + ".json"))
                var meta = try metadata(), entries = meta["entries"] as? [[String: Any]] ?? []
                entries.append(["id": id, "name": name]); meta["entries"] = entries
                try tx.write(meta, to: library.appendingPathComponent("_meta.json"))
                return 0
            }
        } catch { CredentialStore.remove(id: id); throw error }
    }
    func validName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SyncError("名称需为 1–80 个字符") }
        return value
    }
}
