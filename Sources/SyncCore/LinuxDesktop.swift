#if os(Linux)
import Foundation
import Glibc

enum LinuxDesktop {
    static let executable = "/usr/lib/claude-desktop/claude-desktop"
    static func home(in environment: [String: String]) -> URL {
        if let home = environment["HOME"], home.hasPrefix("/") { return URL(fileURLWithPath: home) }
        return fm.homeDirectoryForCurrentUser
    }
    static func config(home: URL, xdg: String?) -> URL {
        if let xdg, xdg.hasPrefix("/") { return URL(fileURLWithPath: xdg) }
        return home.appendingPathComponent(".config")
    }

    static var version: String {
        guard fm.isExecutableFile(atPath: executable),
              let data = try? command("/usr/bin/dpkg-query", ["-W", "-f=${db:Status-Status} ${Version}", "claude-desktop"]),
              let line = String(data: data, encoding: .utf8), line.hasPrefix("installed ") else { return "未安装" }
        return String(line.dropFirst("installed ".count))
    }

    // All arguments go directly to the executable. Secret Service accepts secrets on stdin.
    static func command(_ path: String, _ arguments: [String], input: Data? = nil) throws -> Data {
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        try process.run()
        if let input {
            defer { try? stdin.fileHandleForWriting.close() }
            try stdin.fileHandleForWriting.write(contentsOf: input)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SyncError("命令未完成：\(URL(fileURLWithPath: path).lastPathComponent)") }
        return data
    }
}

public enum CredentialStore {
    private static func run(_ action: [String], id: String, input: Data? = nil) throws -> Data {
        guard uuid(id) else { throw SyncError("无效凭据 ID") }
        do {
            return try LinuxDesktop.command("/usr/bin/secret-tool", action + ["service", "com.syncclaude.gateway", "account", id], input: input)
        } catch { throw SyncError("无法访问 Secret Service，请安装 libsecret-tools 并解锁桌面密钥环。") }
    }
    public static func put(id: String, secret: String) throws {
        guard !secret.isEmpty, secret.utf8.count <= 16384, !secret.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SyncError("API Key 格式不正确")
        }
        _ = try run(["store", "--label=Sync Claude API"], id: id, input: Data(secret.utf8))
    }
    public static func get(id: String) throws -> String {
        let data = try run(["lookup"], id: id)
        guard var key = String(data: data, encoding: .utf8) else { throw SyncError("密钥环数据格式无效") }
        if key.last == "\n" { key.removeLast() }
        guard !key.isEmpty else { throw SyncError("密钥环中的 API Key 为空") }
        return key
    }
    public static func remove(id: String) { _ = try? run(["clear"], id: id) }
}

public final class DesktopProcess: ClaudeProcess {
    private let proc: URL
    private let support: URL

    public convenience init() {
        let env = ProcessInfo.processInfo.environment
        self.init(proc: URL(fileURLWithPath: "/proc"),
                  support: LinuxDesktop.config(home: LinuxDesktop.home(in: env), xdg: env["XDG_CONFIG_HOME"]))
    }
    init(proc: URL, support: URL) {
        self.proc = proc
        self.support = support
    }

    // Match this user's packaged Desktop and its downloaded Code executables.
    // Standalone Claude Code and unrelated Electron applications may be running too.
    private func processes() throws -> (desktop: Set<Int32>, workers: Int) {
        var desktop = Set<Int32>(), workers = 0
        let roots = ["Claude", "Claude-3p"].map { support.appendingPathComponent($0).path + "/" }
        for pid in try fm.contentsOfDirectory(atPath: proc.path) {
            guard let number = Int32(pid) else { continue }
            let path = proc.appendingPathComponent(pid).path
            guard let exe = try? fm.destinationOfSymbolicLink(atPath: path + "/exe") else {
                // A sandbox or /proc permission can hide exe for a live process.
                if let name = try? String(contentsOfFile: path + "/comm").trimmingCharacters(in: .newlines),
                   ["claude-desktop", "claude", "claude-code"].contains(name),
                   let uid = try? fm.attributesOfItem(atPath: path)[.ownerAccountID] as? NSNumber,
                   uid.uint32Value == getuid(),
                   let stat = try? String(contentsOfFile: path + "/stat"), !stat.contains(") Z ") {
                    // A process can lose exe just before becoming a zombie. Keep
                    // waiting for it; mainPID independently verifies any signal target.
                    if name == "claude-desktop" { desktop.insert(number) } else { workers += 1 }
                }
                continue
            }
            let executable = exe.hasSuffix(" (deleted)") ? String(exe.dropLast(10)) : exe
            let isDesktop = executable == LinuxDesktop.executable
            let isWorker = roots.contains(where: { executable.hasPrefix($0) }) &&
                ["claude", "claude-code"].contains(URL(fileURLWithPath: executable).lastPathComponent)
            guard isDesktop || isWorker, let uid = try? fm.attributesOfItem(atPath: path)[.ownerAccountID] as? NSNumber,
                  uid.uint32Value == getuid() else { continue }
            if isDesktop { desktop.insert(number) } else { workers += 1 }
        }
        return (desktop, workers)
    }
    public var running: Bool { (try? processes().desktop.isEmpty) != true }
    public var workers: Int { (try? processes().workers) ?? 1 }

    private func mainPID(in desktop: Set<Int32>) -> Int32? {
        let host = ProcessInfo.processInfo.hostName + "-"
        let holders = Set(["Claude", "Claude-3p"].compactMap { profile -> Int32? in
            let path = support.appendingPathComponent(profile + "/SingletonLock").path
            guard let lock = try? fm.destinationOfSymbolicLink(atPath: path), lock.hasPrefix(host),
                  let pid = Int32(lock.dropFirst(host.count)), desktop.contains(pid) else { return nil }
            return pid
        })
        guard holders.count == 1, let pid = holders.first,
              let args = try? Data(contentsOf: proc.appendingPathComponent("\(pid)/cmdline")),
              !args.split(separator: 0).contains(where: { $0.starts(with: "--type=".utf8) }),
              (try? fm.destinationOfSymbolicLink(atPath: proc.appendingPathComponent("\(pid)/exe").path)) == LinuxDesktop.executable else { return nil }
        return pid
    }

    public func stop(allowOpenSessions: Bool) throws {
        let active = try processes()
        guard active.workers == 0 || allowOpenSessions else {
            throw SyncError("Claude 有打开的 Code 会话。请先完成任务并退出 Claude 后重试。")
        }
        if !active.desktop.isEmpty {
            // Electron installs SIGTERM as Browser::Quit. Only address the browser
            // holding the current profile's singleton lock, never helpers or other apps.
            guard let pid = mainPID(in: active.desktop), kill(pid, SIGTERM) == 0 else {
                throw SyncError("无法确认 Claude 主进程，请在 Claude 菜单中选择退出后重试。")
            }
        }
        let limit = Date().addingTimeInterval(20)
        while true {
            let remaining = try processes()
            if remaining.desktop.isEmpty && remaining.workers == 0 { return }
            guard Date() < limit else { throw SyncError("Claude 或 Code 会话尚未退出，请检查客户端。") }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
    public func start() throws {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/gtk-launch")
        launcher.arguments = ["com.anthropic.Claude"]
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()
        launcher.waitUntilExit()
        guard launcher.terminationStatus == 0 else { throw SyncError("无法启动 Claude，请检查图形会话。") }
        let limit = Date().addingTimeInterval(10)
        while mainPID(in: try processes().desktop) == nil {
            guard Date() < limit else { throw SyncError("Claude 未启动，请从应用菜单打开。") }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
#endif
