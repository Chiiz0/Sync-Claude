import Foundation
import Darwin

public struct RecordPurgePreview: Identifiable {
    public var id: String { fingerprint }
    public let directoryCount: Int
    public let recoveryCopyCount: Int
    public let fileCount: Int
    public let bytes: Int64
    public let emptyOnly: Bool
    public let deletesLiveDirectories: Bool
    public let fingerprint: String
    let recoveryIDs: [String]
    let livePreviews: [AccountRecordInfo]
}

struct PurgeScope: Codable, Hashable {
    let profile: String
    let account: String
    let organization: String
    var key: String { "\(profile)/\(account)/\(organization)" }
    init(_ entry: RemovedAccountRecord) { profile = entry.profile; account = entry.account; organization = entry.organization }
    init(_ entry: AccountRecordInfo) { profile = entry.profile; account = entry.account; organization = entry.organization }
    func target(_ support: URL) -> URL { support.appendingPathComponent("\(profile)/claude-code-sessions/\(account)/\(organization)") }
}

struct PurgeAction: Codable {
    let path: String
    let kind: String // file, directory, metadata
    let digest: String?
    let replacement: Data?
    let bytes: Int64
}

struct RecordPurgePlan: Codable {
    var version = 1
    var scopes: [PurgeScope]
    var live: Bool
    var restartClaude = false
    var recoveryCopies: Int
    var emptyOnly: Bool
    var actions: [PurgeAction]
    var fingerprint: String { get throws { try sha(jsonData(JSONSerialization.jsonObject(with: JSONEncoder().encode(self)))) } }
}

extension Engine {
    var pendingPurge: URL { state.appendingPathComponent("pending-purge.json") }
    var hasPendingOperation: Bool { exists(state.appendingPathComponent("pending.json")) || exists(pendingPurge) || exists(pendingSessionPurge) }

    func isEmptyRecordDirectory(_ root: URL) throws -> Bool {
        guard exists(root) else { return false }
        let files = try treeFiles(root), schedule = root.appendingPathComponent("scheduled-tasks.json")
        guard files.allSatisfy({ $0 == schedule }) else { return false }
        if !exists(schedule) { return true }
        let value = try readJSON(schedule)
        guard let tasks = value["scheduledTasks"] as? [Any], let skips = value["recordedSkips"] as? [String: Any] else { return false }
        for key in ["sundayAliasBoundaryStamped", "dayFieldsOrBoundaryStamped"] {
            if let raw = value[key] {
                guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
            }
        }
        return tasks.isEmpty && skips.isEmpty && Set(value.keys).isSubset(of: ["scheduledTasks", "recordedSkips", "sundayAliasBoundaryStamped", "dayFieldsOrBoundaryStamped"])
    }

    public func previewRecordPurge(ids: [String]) throws -> RecordPurgePreview {
        try locked(state) { try makePurgePreview(ids: ids, live: []) }
    }

    public func previewEmptyRecordDeletion(_ previews: [AccountRecordInfo]) throws -> RecordPurgePreview {
        try locked(state) { try makePurgePreview(ids: [], live: previews) }
    }

    func makePurgePreview(ids: [String], live: [AccountRecordInfo]) throws -> RecordPurgePreview {
        guard !hasPendingOperation else { throw SyncError("请先完成上次操作。") }
        let plan = try buildPurgePlan(ids: ids, live: live)
        return RecordPurgePreview(directoryCount: plan.scopes.count, recoveryCopyCount: plan.recoveryCopies,
            fileCount: plan.actions.filter { $0.kind == "file" }.count, bytes: plan.actions.reduce(0) { $0 + $1.bytes },
            emptyOnly: plan.emptyOnly, deletesLiveDirectories: plan.live, fingerprint: try plan.fingerprint, recoveryIDs: ids, livePreviews: live)
    }

    func buildPurgePlan(ids: [String], live: [AccountRecordInfo]) throws -> RecordPurgePlan {
        guard (!ids.isEmpty) != (!live.isEmpty), Set(ids).count == ids.count, ids.allSatisfy({ uuid($0) }) else { throw SyncError("请选择需要永久清除的目录或恢复项。") }
        let entries = try cleanupEntries()
        var scopes = Set<PurgeScope>()
        if !live.isEmpty {
            try checkCompatibility(configuration: false)
            let current = try accountRecords()
            guard Set(live.map(\.id)).count == live.count else { throw SyncError("目录选择重复") }
            for preview in live {
                guard let item = current.first(where: { $0.id == preview.id }), item.fingerprint == preview.fingerprint,
                      item.canClean, item.empty else { throw SyncError("目录不再为空、正在使用或已发生变化，请重新检查。") }
                scopes.insert(PurgeScope(item))
            }
        } else {
            for id in ids {
                guard let entry = entries.first(where: { $0.id == id }) else { throw SyncError("恢复项已变化，请刷新后重试。") }
                scopes.insert(PurgeScope(entry))
            }
        }
        let related = entries.filter { scopes.contains(PurgeScope($0)) }
        var actions: [String: PurgeAction] = [:]
        var emptyOnly = true
        func removeTree(_ root: URL) throws {
            try safePath(root)
            guard exists(root) else { return }
            let type = try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType
            if type == .typeDirectory {
                for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) { try removeTree(child) }
                actions[root.path] = PurgeAction(path: root.path, kind: "directory", digest: nil, replacement: nil, bytes: 0)
            } else if type == .typeRegular {
                let data = try Data(contentsOf: root)
                actions[root.path] = PurgeAction(path: root.path, kind: "file", digest: sha(data), replacement: nil, bytes: Int64(data.count))
            } else { throw SyncError("恢复副本包含不支持的文件类型，未清除。") }
        }
        func rewrite(_ file: URL, _ data: Data) throws {
            try safePath(file)
            let before = try Data(contentsOf: file)
            guard before != data else { return }
            actions[file.path] = PurgeAction(path: file.path, kind: "metadata", digest: sha(before), replacement: data, bytes: 0)
        }
        func filteredIndex(_ file: URL) throws -> Data? {
            try safePath(file)
            guard let all = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] else { throw SyncError("旧清理索引格式无法识别") }
            let scopeKeys = Set(scopes.map(\.key))
            let kept = try all.filter { entry in
                guard let profile = entry["profile"] as? String, ["Claude", "Claude-3p"].contains(profile),
                      let account = entry["account"] as? String, uuid(account), let org = entry["organization"] as? String, uuid(org) else { throw SyncError("旧清理索引身份无效") }
                return !scopeKeys.contains("\(profile)/\(account)/\(org)")
            }
            guard kept.count != all.count else { return nil }
            return try jsonData(kept)
        }
        for entry in related {
            let folder = state.appendingPathComponent("removed-records/\(entry.id)")
            let content = folder.appendingPathComponent("content")
            if try treeFiles(folder).contains(where: { !$0.path.hasPrefix(content.path + "/") }) { emptyOnly = false }
            if exists(content) {
                guard try digestTree(content) == entry.digest else { throw SyncError("恢复副本已变化或校验失败，未清除。") }
                if try !isEmptyRecordDirectory(content) { emptyOnly = false }
            } else if entry.sessionCount > 0 { emptyOnly = false }
            try removeTree(folder)
        }
        if !live.isEmpty {
            for scope in scopes { try removeTree(scope.target(support)) }
            let targets = Set(scopes.map { $0.target(support).path })
            for parent in Set(scopes.map { $0.target(support).deletingLastPathComponent() }) {
                let children = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                if children.allSatisfy({ targets.contains($0.path) }) { try removeTree(parent) }
            }
        }
        // Prune only payloads whose journal destination belongs to these account/organization scopes.
        let backups = state.appendingPathComponent("backups")
        try safePath(backups)
        if exists(backups) {
            for folder in try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                guard folder.lastPathComponent.range(of: "^[0-9]+-[a-f0-9-]{36}$", options: .regularExpression) != nil else { continue }
                let manifest = folder.appendingPathComponent("manifest.json")
                guard exists(manifest) else { continue }
                var document = try readJSON(manifest)
                guard ["complete", "rolled-back", "purged"].contains(document["status"] as? String ?? ""),
                      var journalEntries = document["entries"] as? [[String: Any]] else { continue }
                var changed = false
                let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                for i in journalEntries.indices {
                    guard let destination = journalEntries[i]["destination"] as? String else { throw SyncError("操作备份索引格式错误") }
                    let payloads = children.filter {
                        let n = $0.lastPathComponent
                        return ["\(i)-before", "\(i)-displaced", "\(i)-new.json"].contains(n) || n.hasPrefix("\(i)-recovery-")
                    }
                    var pruned = false
                    for payload in payloads {
                        if destination == cleanupIndex.path {
                            if let data = try filteredIndex(payload) { try rewrite(payload, data); pruned = true }
                            continue
                        }
                        for scope in scopes {
                            let target = scope.target(support).path
                            if destination == target || destination.hasPrefix(target + "/") {
                                if destination == target {
                                    if try !isEmptyRecordDirectory(payload) { emptyOnly = false }
                                } else { emptyOnly = false }
                                try removeTree(payload); pruned = true
                            } else if target.hasPrefix(destination + "/") {
                                let suffix = String(target.dropFirst(destination.count + 1))
                                let nested = payload.appendingPathComponent(suffix)
                                if exists(nested) {
                                    if try !isEmptyRecordDirectory(nested) { emptyOnly = false }
                                    try removeTree(nested); pruned = true
                                }
                            }
                        }
                    }
                    if pruned {
                        // Completed journals are no longer rollback sources after explicit permanent deletion.
                        journalEntries[i].removeValue(forKey: "digest")
                        journalEntries[i]["permanentlyPruned"] = true
                        changed = true
                    }
                }
                if changed {
                    document["entries"] = journalEntries; document["status"] = "purged"
                    let prior = document["purgedScopes"] as? [String] ?? []
                    document["purgedScopes"] = Set(prior + scopes.map(\.key)).sorted()
                    try rewrite(manifest, jsonData(document))
                }
            }
        }
        if exists(cleanupIndex), let data = try filteredIndex(cleanupIndex) { try rewrite(cleanupIndex, data) }
        let ordered = actions.values.sorted {
            let rank: (PurgeAction) -> Int = { $0.kind == "file" ? 0 : $0.kind == "directory" ? 1 : 2 }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.kind == "directory", $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            // Remove index entries only after all payload files have gone.
            if $0.path == cleanupIndex.path { return false }
            if $1.path == cleanupIndex.path { return true }
            return $0.path < $1.path
        }
        return RecordPurgePlan(scopes: scopes.sorted { $0.key < $1.key }, live: !live.isEmpty, recoveryCopies: related.count, emptyOnly: emptyOnly, actions: ordered)
    }

    func validatePurgePlan(_ plan: RecordPurgePlan) throws {
        guard plan.version == 1, !plan.scopes.isEmpty, Set(plan.scopes).count == plan.scopes.count,
              plan.scopes.allSatisfy({ ["Claude", "Claude-3p"].contains($0.profile) && uuid($0.account) && uuid($0.organization) }),
              Set(plan.actions.map(\.path)).count == plan.actions.count else { throw SyncError("永久清除清单格式无效") }
        for action in plan.actions {
            let file = URL(fileURLWithPath: action.path)
            guard file.standardizedFileURL.path == action.path else { throw SyncError("永久清除清单路径无效") }
            try safePath(file)
            let removedPrefix = state.appendingPathComponent("removed-records").path + "/"
            let backupPrefix = state.appendingPathComponent("backups").path + "/"
            var allowed = false
            if action.path.hasPrefix(removedPrefix) {
                let parts = String(action.path.dropFirst(removedPrefix.count)).split(separator: "/")
                allowed = parts.first.map { uuid(String($0)) } == true && action.kind != "metadata"
                if action.path == cleanupIndex.path { allowed = action.kind == "metadata" }
            } else if action.path.hasPrefix(backupPrefix) {
                let parts = String(action.path.dropFirst(backupPrefix.count)).split(separator: "/")
                allowed = parts.count >= 2 && String(parts[0]).range(of: "^[0-9]+-[a-f0-9-]{36}$", options: .regularExpression) != nil
            } else if plan.live, action.kind != "metadata" {
                allowed = plan.scopes.contains {
                    let target = $0.target(support).path
                    return action.kind == "directory" ? action.path == target || action.path.hasPrefix(target + "/") || action.path == $0.target(support).deletingLastPathComponent().path : action.path == target + "/scheduled-tasks.json"
                }
            }
            guard allowed, ["file", "directory", "metadata"].contains(action.kind),
                  action.kind == "directory" || action.digest?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  (action.kind == "metadata") == (action.replacement != nil) else { throw SyncError("永久清除清单包含范围外操作") }
        }
    }

    func executePurgePlan(_ plan: RecordPurgePlan, beforeAction: (() throws -> Void)? = nil) throws {
        try validatePurgePlan(plan)
        // Validate every surviving file before doing more work on an interrupted request.
        for action in plan.actions where action.kind != "directory" {
            let file = URL(fileURLWithPath: action.path)
            if !exists(file) {
                guard action.kind == "file" else { throw SyncError("清除期间索引被移除，已停止。") }
                continue
            }
            let digest = try sha(Data(contentsOf: file))
            guard digest == action.digest || action.replacement.map({ sha($0) }) == digest else { throw SyncError("清除期间文件发生变化，已停止，未覆盖新内容。") }
        }
        for action in plan.actions {
            try beforeAction?()
            if plan.live { guard !process.running, process.workers == 0 else { throw SyncError("Claude 已重新启动，请退出后继续清除。") } }
            let file = URL(fileURLWithPath: action.path)
            try safePath(file)
            if action.kind == "metadata", let data = action.replacement {
                let digest = try sha(Data(contentsOf: file))
                if digest == sha(data) { continue }
                guard digest == action.digest else { throw SyncError("索引已变化，停止清除。") }
                try atomicData(data, file)
            } else if exists(file) {
                let type = try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
                if action.kind == "directory" {
                    guard type == .typeDirectory, try fm.contentsOfDirectory(atPath: file.path).isEmpty else { throw SyncError("目录出现新内容，停止清除。") }
                } else {
                    guard type == .typeRegular, try sha(Data(contentsOf: file)) == action.digest else { throw SyncError("文件已变化，停止清除。") }
                }
                try fm.removeItem(at: file)
                let fd = open(file.deletingLastPathComponent().path, O_RDONLY)
                if fd >= 0 { _ = fsync(fd); close(fd) }
            }
        }
        try fm.removeItem(at: pendingPurge)
    }

    public func purgeRecords(_ preview: RecordPurgePreview, allowOpenSessions: Bool = false) throws -> Outcome {
        try locked(state) {
            guard !hasPendingOperation else { throw SyncError("请先完成上次操作。") }
            var plan = try buildPurgePlan(ids: preview.recoveryIDs, live: preview.livePreviews)
            guard try plan.fingerprint == preview.fingerprint else { throw SyncError("清除范围或内容已变化，请重新预览。") }
            let wasRunning = process.running
            if plan.live { try process.stop(allowOpenSessions: allowOpenSessions) }
            do {
                plan = try buildPurgePlan(ids: preview.recoveryIDs, live: preview.livePreviews)
                guard try plan.fingerprint == preview.fingerprint else { throw SyncError("目录已变化，请重新预览。") }
                plan.restartClaude = plan.live && wasRunning
                try validatePurgePlan(plan)
                // Only paths, hashes, and sanitized indexes are persisted. Never back up deleted payloads.
                try atomicData(JSONEncoder().encode(plan), pendingPurge)
                try executePurgePlan(plan)
            } catch {
                if exists(pendingPurge) { throw SyncError("永久清除尚未完成。已保留执行清单，请点击“继续永久清除”；已删除的副本不会恢复。\n\(error.localizedDescription)") }
                if plan.live && wasRunning { try? process.start() }
                throw error
            }
            if plan.restartClaude {
                do { try process.start() }
                catch { return Outcome(message: "永久清除已完成；Claude 未能重新启动，请手动打开。", added: plan.scopes.count) }
            }
            return Outcome(message: "已永久清除 \(plan.scopes.count) 个目录的恢复副本及关联操作备份；共享会话正文和历史归档保留。", added: plan.scopes.count)
        }
    }

    public func resumeRecordPurge(allowOpenSessions: Bool = false) throws -> Outcome {
        if exists(pendingSessionPurge) { return try resumeSessionPurge(allowOpenSessions: allowOpenSessions) }
        return try locked(state) {
            guard !exists(state.appendingPathComponent("pending.json")) else { throw SyncError("请先恢复原有事务。") }
            try safePath(pendingPurge)
            let plan = try JSONDecoder().decode(RecordPurgePlan.self, from: Data(contentsOf: pendingPurge))
            try validatePurgePlan(plan)
            let wasRunning = process.running
            if plan.live { try process.stop(allowOpenSessions: allowOpenSessions) }
            try executePurgePlan(plan)
            if plan.live && (wasRunning || plan.restartClaude) {
                do { try process.start() }
                catch { return Outcome(message: "永久清除已完成；Claude 未能重新启动，请手动打开。", added: plan.scopes.count) }
            }
            return Outcome(message: "永久清除已完成。共享会话正文和历史归档保留。", added: plan.scopes.count)
        }
    }
}
