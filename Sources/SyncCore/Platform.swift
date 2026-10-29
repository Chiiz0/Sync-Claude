import Foundation
import Security
import AppKit

public enum CredentialStore {
    private static let service = "com.syncclaude.gateway"
    public static func put(id: String, secret: String) throws {
        guard uuid(id), !secret.isEmpty, !secret.contains("\n"), secret.count <= 16384 else { throw SyncError("API Key 格式不正确") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        let value = Data(secret.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = value; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SyncError("钥匙串写入失败（\(added)）") }
        } else if status != errSecSuccess { throw SyncError("钥匙串写入失败（\(status)）") }
    }
    public static func get(id: String) throws -> String {
        guard uuid(id) else { throw SyncError("无效凭据 ID") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw SyncError("无法读取钥匙串凭据（\(status)）") }
        return key
    }
    public static func remove(id: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id] as CFDictionary) }
}

public protocol ClaudeProcess {
    var running: Bool { get }
    var workers: Int { get }
    func stop(allowOpenSessions: Bool) throws
    func start() throws
}
public final class MacClaudeProcess: ClaudeProcess {
    public init() {}
    private var apps: [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop") }
    public var running: Bool { !apps.isEmpty }
    public var workers: Int {
        // Conservative: an open Code agent may be idle or generating. Both must close before switching.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do {
            try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { return 1 }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").filter {
                let line = String($0).trimmingCharacters(in: .whitespaces)
                return line.contains("/Application Support/Claude") && (line.hasSuffix("/claude") || line.hasSuffix("/claude-code") || line.hasSuffix("/cli.js"))
            }.count
        } catch { return 1 }
    }
    public func stop(allowOpenSessions: Bool = false) throws {
        guard workers == 0 || allowOpenSessions else { throw SyncError("Claude 仍有 Code 会话进程。确认任务已完成后，可继续正常重开；工具不会强制终止进程。") }
        for app in apps { guard app.terminate() else { throw SyncError("Claude 拒绝退出，配置未修改。") } }
        let limit = Date().addingTimeInterval(20)
        while (running || workers > 0) && Date() < limit { Thread.sleep(forTimeInterval: 0.2) }
        guard !running, workers == 0 else { throw SyncError("Claude 尚未完全退出，配置未修改。") }
    }
    public func start() throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", "Claude"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SyncError("无法启动 Claude") }
        let limit = Date().addingTimeInterval(10)
        while !running && Date() < limit { Thread.sleep(forTimeInterval: 0.2) }
        guard running else { throw SyncError("Claude 未启动，请检查安装位置。") }
    }
}
