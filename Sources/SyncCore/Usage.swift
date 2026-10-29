import Foundation
import Security
import LocalAuthentication
import CommonCrypto

public struct UsageWindow: Codable, Identifiable {
    public let id: String
    public let label: String
    public let utilization: Double?
    public let resetsAt: Double?
}
public struct OfficialUsage: Codable, Identifiable {
    public let id: String
    public var name: String
    public var plan: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Double?
    public var attemptedAt: Double?
    public var error: String?
}
struct UsageCredential {
    let token: String
    let plan: String?
}

// Electron's macOS v10 safeStorage format. Secrets are read only in memory, never cached here.
enum DesktopTokenReader {
    static func storagePassword() throws -> Data {
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage", kSecAttrAccount as String: "Claude Key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let bytes = result as? Data else {
            throw SyncError("无法读取 Claude 钥匙串，请先解锁系统钥匙串并允许此应用读取。")
        }
        return bytes
    }
    static func decrypt(_ encoded: String, password: Data) throws -> [String: Any] {
        guard let data = Data(base64Encoded: encoded), data.starts(with: Data("v10".utf8)), data.count > 3,
              (data.count - 3) % 16 == 0, !password.isEmpty else { throw SyncError("官方登录加密格式未适配，未读取凭据。") }
        var salt = Array("saltysalt".utf8), key = [UInt8](repeating: 0, count: 16)
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                &salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { throw SyncError("官方登录解密失败") }
        let encrypted = Data(data.dropFirst(3))
        var plain = [UInt8](repeating: 0, count: encrypted.count + 16), written = 0, iv = [UInt8](repeating: 32, count: 16)
        defer { _ = plain.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let result = encrypted.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), &key, key.count, &iv,
                bytes.baseAddress, encrypted.count, &plain, plain.count, &written)
        }
        guard result == kCCSuccess,
              let object = try? JSONSerialization.jsonObject(with: Data(plain.prefix(written))) as? [String: Any] else { throw SyncError("官方登录解密失败") }
        return object
    }
    static func credential(_ entries: [String: Any], account: String, now: Double = Date().timeIntervalSince1970) throws -> UsageCredential {
        guard uuid(account) else { throw SyncError("官方账号标识无效") }
        let prefix = "acct:\(account)|9d1c250a-e61b-44d9-88ed-5944d1962f5e:"
        var candidates: [(UsageCredential, Bool, Double)] = []
        for (scope, value) in entries where scope.hasPrefix(prefix) {
            let remainder = String(scope.dropFirst(prefix.count)), parts = remainder.components(separatedBy: ":https://api.anthropic.com:")
            guard parts.count == 2, uuid(parts[0]), let entry = value as? [String: Any] else { continue }
            let scopes = Set(parts[1].split(separator: " ").map(String.init))
            guard scopes.contains("user:profile"), scopes.contains("user:inference"),
                  let token = entry["token"] as? String, !token.isEmpty,
                  let expires = entry["expiresAt"] as? Double, expires.isFinite, expires / 1000 > now + 30 else { continue }
            candidates.append((UsageCredential(token: token, plan: entry["subscriptionType"] as? String), scopes.contains("user:sessions:claude_code"), expires))
        }
        guard let best = candidates.sorted(by: { $0.1 != $1.1 ? $0.1 : $0.2 > $1.2 }).first else {
            throw SyncError("登录凭据不可用或已过期；切回此账号进入 Code 后，再保存并刷新。")
        }
        return best.0
    }
}

enum UsageParser {
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    static func timestamp(_ value: Any?) -> Double? {
        if let number = number(value), number > 0 { return number }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)?.timeIntervalSince1970
    }
    static func parse(_ bytes: Data) throws -> [UsageWindow] {
        guard let data = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw SyncError("用量响应格式无法识别") }
        var windows: [UsageWindow] = []
        for (key, label) in [("five_hour", "五小时用量"), ("seven_day", "每周 · 全部模型"), ("seven_day_sonnet", "每周 · Sonnet"), ("seven_day_opus", "每周 · Opus"), ("seven_day_oauth_apps", "每周 · OAuth 应用"), ("seven_day_cowork", "每周 · Cowork")] {
            guard let row = data[key] as? [String: Any] else { continue }
            let percent = number(row["utilization"]), reset = timestamp(row["resets_at"])
            if percent != nil || reset != nil { windows.append(UsageWindow(id: key, label: label, utilization: percent, resetsAt: reset)) }
        }
        for (index, row) in (data["limits"] as? [[String: Any]] ?? []).enumerated() {
            let kind = row["kind"] as? String ?? ""
            if kind == "session" || kind == "weekly_all" {
                let key = kind == "session" ? "five_hour" : "seven_day"
                if windows.contains(where: { $0.id == key }) { continue }
                if number(row["percent"]) != nil || timestamp(row["resets_at"]) != nil {
                    windows.append(UsageWindow(id: key, label: kind == "session" ? "五小时用量" : "每周 · 全部模型", utilization: number(row["percent"]), resetsAt: timestamp(row["resets_at"])))
                }
            } else if kind == "weekly_scoped" {
                let scope = row["scope"] as? [String: Any] ?? [:]
                let names = ["model", "surface"].compactMap { (scope[$0] as? [String: Any])?["display_name"] as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !names.isEmpty else { continue }
                let label = "每周 · " + names.joined(separator: " / ")
                guard !windows.contains(where: { $0.label == label }), number(row["percent"]) != nil || timestamp(row["resets_at"]) != nil else { continue }
                windows.append(UsageWindow(id: "scoped_\(index)", label: label, utilization: number(row["percent"]), resetsAt: timestamp(row["resets_at"])))
            }
        }
        guard !windows.isEmpty else { throw SyncError("服务未返回可显示的订阅用量；不将未知数据视为 0%。") }
        return windows
    }
}

final class UsageHTTPClient: NSObject, URLSessionTaskDelegate {
    // A fixed first-party endpoint, no cookies, redirects, token renewal or inference requests.
    func fetch(_ token: String) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SyncError("用量查询网络失败或超时，稍后重试。") }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: guard data.count <= 1024 * 1024 else { throw SyncError("用量响应超出预期大小") }; return data
        case 401, 403: throw SyncError("登录已失效或无用量权限；切回此账号进入 Code 后重新保存。")
        case 429: throw SyncError("官方用量查询暂时限流，请稍后刷新。")
        default: throw SyncError("官方用量服务暂不可用，保留上次成功数据。")
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

extension Engine {
    var usageCache: URL { state.appendingPathComponent("usage.json") }
    func usageAccounts() throws -> [String: String] {
        var result: [String: String] = [:]
        let aliases = try profileAliases()
        for entry in try accounts() {
            guard let account = entry["account"] as? String, uuid(account), let id = entry["id"] as? String, uuid(id) else { throw SyncError("保存的官方账号索引无效") }
            result[account] = aliases[aliasKey(id: id, kind: "account")] ?? entry["name"] as? String ?? "官方账号 \(account.prefix(6))"
        }
        if let account = try accountID(), result[account] == nil, try !forgottenAccountIDs().contains(account) { result[account] = "当前官方账号 \(account.prefix(6))" }
        return result
    }
    func cachedUsage() throws -> [String: OfficialUsage] {
        try safePath(usageCache)
        guard exists(usageCache) else { return [:] }
        let cached = try JSONDecoder().decode([String: OfficialUsage].self, from: Data(contentsOf: usageCache))
        guard cached.allSatisfy({ uuid($0.key) && $0.value.id == $0.key }) else { throw SyncError("用量缓存索引无效") }
        return cached
    }
    public func officialUsage() throws -> [OfficialUsage] {
        let cached = try cachedUsage()
        return try usageAccounts().map { id, name in
            var value = cached[id] ?? OfficialUsage(id: id, name: name, windows: [])
            value.name = name; return value
        }.sorted { $0.name < $1.name }
    }
    func usageCredential(_ account: String) throws -> UsageCredential {
        let config: [String: Any]
        if try accountID() == account {
            config = try readJSON(first.appendingPathComponent("config.json"))
        } else {
            guard let entry = try accounts().first(where: { $0["account"] as? String == account }),
                  let id = entry["id"] as? String, uuid(id), let snapshot = entry["snapshot"] as? String, uuid(snapshot) else { throw SyncError("未找到官方账号快照") }
            let folder = state.appendingPathComponent("accounts/\(id)/\(snapshot)")
            let manifest = try readJSON(folder.appendingPathComponent("manifest.json"))
            let file = folder.appendingPathComponent("config.json")
            guard manifest["account"] as? String == account,
                  let hash = (manifest["files"] as? [String: String])?["config.json"], exists(file), try digestTree(file) == hash else { throw SyncError("账号快照校验失败，未读取用量凭据。") }
            config = try readJSON(file)
        }
        guard config["lastKnownAccountUuid"] as? String == account, let encrypted = config["oauth:tokenCacheV2"] as? String else { throw SyncError("官方登录尚无 Code 凭据，请进入 Code 后保存账号。") }
        let entries = try DesktopTokenReader.decrypt(encrypted, password: DesktopTokenReader.storagePassword())
        return try DesktopTokenReader.credential(entries, account: account)
    }
    public func refreshUsage() async throws -> Outcome {
        try await refreshUsage(credential: { try self.usageCredential($0) }, fetch: { try await UsageHTTPClient().fetch($0) })
    }
    func refreshUsage(credential: (String) throws -> UsageCredential, fetch: (String) async throws -> Data) async throws -> Outcome {
        guard version == "4.29.0" else { throw SyncError("此版本的登录格式尚未适配，用量缓存仍可查看。") }
        let previous = try locked(state) { try officialUsage() }
        var updates: [String: OfficialUsage] = [:], succeeded = 0
        for var row in previous {
            row.attemptedAt = Date().timeIntervalSince1970
            do {
                let auth = try credential(row.id)
                let windows = try UsageParser.parse(await fetch(auth.token))
                row.plan = auth.plan; row.windows = windows; row.fetchedAt = Date().timeIntervalSince1970; row.error = nil
                succeeded += 1
            } catch {
                // Never store raw transport bodies or arbitrary error descriptions containing credentials.
                row.error = (error as? SyncError)?.message ?? "用量读取失败，保留上次成功数据。"
            }
            updates[row.id] = row
        }
        try locked(state) {
            guard !exists(state.appendingPathComponent("pending.json")) else { throw SyncError("需要先恢复未完成的操作") }
            let eligible = try usageAccounts()
            var cached = try cachedUsage()
            cached = cached.filter { eligible[$0.key] != nil }
            for (id, row) in updates where eligible[id] != nil && (row.attemptedAt ?? 0) >= (cached[id]?.attemptedAt ?? 0) { cached[id] = row }
            succeeded = updates.values.filter { eligible[$0.id] != nil && $0.error == nil }.count
            try atomicData(JSONEncoder().encode(cached), usageCache)
        }
        return Outcome(message: "已更新 \(succeeded) 个官方账号用量\(succeeded < previous.count ? "，\(previous.count - succeeded) 个暂不可用，请查看账号提示" : "")。", added: succeeded)
    }
}
