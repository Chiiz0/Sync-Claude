import Foundation
import Glibc
import SyncCore

let help = """
Sync Claude · Ubuntu
  sync-claude --status                          查看配置、会话、工作区及恢复状态（JSON）
  sync-claude --archive                         归档本机 Code 记录
  sync-claude --compact-history                 精简重复的正文归档
  sync-claude --sync                            同步会话与定时任务，再启动 Claude
  sync-claude --switch ID                       切换到配置 ID，或 official
  sync-claude --new-login                       保存旧登录并打开新账号登录窗口
  sync-claude --save-account 名称               保存当前官方登录
  sync-claude --add-gateway                     从标准输入读取 API 配置 JSON
  sync-claude --alias account|gateway ID 名称   设置别名，空字符串恢复原名
  sync-claude --delete-profile account|gateway ID  预览删除所选配置
  sync-claude --repair-1m ID                      修复当前 API 的 1M 模型偏好
  sync-claude --clean-directory ID                预览清理账户目录，保留恢复副本
  sync-claude --delete-empty-directory ID         预览永久删除空目录
  sync-claude --restore-directory 备份ID          恢复已清理的目录
  sync-claude --purge-backups 备份ID[,ID]         预览永久清除恢复副本
  sync-claude --purge-empty-recovery              预览永久清除所有空恢复项
  sync-claude --recover                         恢复未完成的切换事务
  sync-claude --deleted-sessions                列出已删除会话
  sync-claude --preview-session-purge ID[,ID]   预览已删除会话的永久清理范围
  sync-claude --purge-sessions ID[,ID]          预览永久清理已删除的会话
  sync-claude --remove-runs ID[,ID]             预览移除定时任务运行记录
  sync-claude --resume-purge                    继续已确认但中断的永久清理
  sync-claude --scheduled-runs                  查看定时任务的运行记录
  sync-claude --self-test-keychain              检查桌面密钥环

预览后在原命令末尾追加 --confirm-fingerprint 指纹 执行；内容发生变化时需重新预览。
"""

struct GatewayInput: Decodable {
    let name: String
    let endpoint: String
    let key: String
    let auth: String
    let models: [String]?
    let prefer1m: Bool?
}

func json<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func review<T: Encodable>(_ preview: T, fingerprint: String, confirmation: ArraySlice<String>,
                          apply: () throws -> Outcome) throws {
    if confirmation.isEmpty {
        try json(preview)
    } else {
        guard Array(confirmation) == ["--confirm-fingerprint", fingerprint] else {
            throw SyncError("确认参数或指纹不匹配，请重新核对预览。")
        }
        print(try apply().message)
    }
}

func run(_ arguments: [String]) throws {
    let engine = Engine()
    switch (arguments.first, arguments.count) {
    case (nil, 0), ("--help", 1), ("-h", 1): print(help)
    case ("--credential", 2): print(try CredentialStore.get(id: arguments[1]))
    case ("--status", 1): try json(engine.status())
    case ("--archive", 1): print(try engine.archive().message)
    case ("--compact-history", 1):
        let result = try engine.compactHistory()
        print(result.message)
        if !result.failures.isEmpty { throw SyncError(result.failures.joined(separator: "\n")) }
    case ("--sync", 1): print(try engine.sync().message)
    case ("--switch", 2): print(try engine.switchProfile(id: arguments[1]).message)
    case ("--new-login", 1): print(try engine.newLogin().message)
    case ("--save-account", 2): print(try engine.saveAccount(name: arguments[1]).message)
    case ("--alias", 4):
        print(try engine.setProfileAlias(id: arguments[2], kind: arguments[1],
                                         alias: arguments[3].isEmpty ? nil : arguments[3]).message)
    case ("--add-gateway", 1):
        guard isatty(STDIN_FILENO) == 0 else { throw SyncError("请通过图形界面添加 API，或从管道输入 JSON 配置。") }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let config = try? JSONDecoder().decode(GatewayInput.self, from: input) else { throw SyncError("API 配置 JSON 格式错误。") }
        let helper = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        print(try engine.addGateway(name: config.name, endpoint: config.endpoint, models: config.models ?? [],
                                    auth: config.auth, key: config.key, helper: helper, prefer1m: config.prefer1m ?? false).message)
    case ("--delete-profile", 3), ("--delete-profile", 5):
        let preview = try engine.profileDeletionPreview(id: arguments[2], kind: arguments[1])
        try review(preview, fingerprint: preview.fingerprint, confirmation: arguments.dropFirst(3)) {
            try engine.deleteProfile(preview)
        }
    case ("--repair-1m", 2):
        guard let context = try engine.status().profiles.first(where: { $0.id == arguments[1] })?.context else {
            throw SyncError("未找到 API 配置。")
        }
        print(try engine.repairGatewayContext(context).message)
    case ("--clean-directory", 2), ("--clean-directory", 4),
         ("--delete-empty-directory", 2), ("--delete-empty-directory", 4):
        guard let item = try engine.accountRecords().first(where: { $0.id == arguments[1] }) else {
            throw SyncError("未找到所选账户目录。")
        }
        if arguments[0] == "--clean-directory" {
            try review(item, fingerprint: item.fingerprint, confirmation: arguments.dropFirst(2)) {
                try engine.cleanAccountRecords([item])
            }
        } else {
            let preview = try engine.previewEmptyRecordDeletion([item])
            try review(preview, fingerprint: preview.fingerprint, confirmation: arguments.dropFirst(2)) {
                try engine.purgeRecords(preview)
            }
        }
    case ("--restore-directory", 2): print(try engine.restoreAccountRecords(id: arguments[1]).message)
    case ("--purge-empty-recovery", 1), ("--purge-empty-recovery", 3):
        let ids = try engine.removedAccountRecords().filter { $0.sessionCount == 0 }.map(\.id)
        guard !ids.isEmpty else { print("没有空恢复项"); return }
        let preview = try engine.previewRecordPurge(ids: ids)
        guard preview.emptyOnly else { throw SyncError("恢复副本含有效或未知内容，请逐项预览。") }
        try review(preview, fingerprint: preview.fingerprint, confirmation: arguments.dropFirst()) {
            try engine.purgeRecords(preview)
        }
    case ("--purge-backups", 2), ("--purge-backups", 4):
        let preview = try engine.previewRecordPurge(ids: arguments[1].components(separatedBy: ","))
        try review(preview, fingerprint: preview.fingerprint, confirmation: arguments.dropFirst(2)) {
            try engine.purgeRecords(preview)
        }
    case ("--purge-sessions", 2), ("--purge-sessions", 4):
        let preview = try engine.previewSessionPurge(ids: arguments[1].components(separatedBy: ","))
        try review(preview, fingerprint: preview.fingerprint, confirmation: arguments.dropFirst(2)) {
            try engine.purgeDeletedSessions(preview)
        }
    case ("--remove-runs", 2), ("--remove-runs", 4):
        let preview = try engine.previewScheduledRunRemoval(ids: arguments[1].components(separatedBy: ","))
        try review(preview, fingerprint: preview.fingerprint, confirmation: arguments.dropFirst(2)) {
            try engine.removeScheduledRuns(preview)
        }
    case ("--resume-purge", 1): print(try engine.resumeRecordPurge().message)
    case ("--recover", 1): print(try engine.recover().message)
    case ("--deleted-sessions", 1): try json(engine.deletedSessionRecords())
    case ("--preview-session-purge", 2): try json(engine.previewSessionPurge(ids: arguments[1].components(separatedBy: ",")))
    case ("--scheduled-runs", 1): try json(engine.scheduledRuns())
    case ("--self-test-keychain", 1):
        let id = UUID().uuidString.lowercased(), key = UUID().uuidString
        try CredentialStore.put(id: id, secret: key)
        defer { CredentialStore.remove(id: id) }
        guard try CredentialStore.get(id: id) == key else { throw SyncError("密钥环读写校验失败。") }
        print("密钥环读写成功。")
    default: throw SyncError("参数无效，请运行 sync-claude --help。")
    }
}

do { try run(Array(CommandLine.arguments.dropFirst())) }
catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
