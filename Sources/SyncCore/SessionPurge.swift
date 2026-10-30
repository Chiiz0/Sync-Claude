import Foundation
import CryptoKit
import Darwin

public struct DeletedSessionInfo: Codable, Identifiable {
    public let id: String
    public let title: String
    public let project: String
    public let deletedAt: Double
    public let nativeCopies: Int
    public let archiveVersions: Int
    public let backupCopies: Int
    public let transcriptCopies: Int
}

public struct SessionPurgeFile: Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let category: String
    public let bytes: Int64
}

public struct SessionPurgePreview: Codable, Identifiable {
    public var id: String { fingerprint }
    public let sessions: [DeletedSessionInfo]
    public let files: [SessionPurgeFile]
    public let updatedIndexes: Int
    public let fingerprint: String
    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

struct SessionPurgePlan: Codable {
    var version = 1
    let ids: [String]
    let cliIDs: [String]
    let actions: [PurgeAction]
    var restartClaude = false
    var fingerprint: String { get throws { try sha(jsonData(JSONSerialization.jsonObject(with: JSONEncoder().encode(self)))) } }
}

private struct SessionPayload {
    let file: URL
    let value: [String: Any]
    let category: String
    var id: String { (value["sessionId"] as! String).lowercased() }
    var cliIDs: Set<String> {
        Set(([value["cliSessionId"] as! String] + (value["priorCliSessionIds"] as? [String] ?? [])).map { $0.lowercased() })
    }
}

extension Engine {
    var pendingSessionPurge: URL { state.appendingPathComponent("pending-session-purge.json") }

    /// Resolve a journal destination to a local Code metadata ID, never by payload contents alone.
    private func nativeSessionID(_ file: URL) -> String? {
        for profile in ["Claude", "Claude-3p"] {
            let prefix = support.appendingPathComponent(profile + "/claude-code-sessions").path + "/"
            guard file.path.hasPrefix(prefix) else { continue }
            let parts = String(file.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
            guard parts.count == 3, uuid(parts[0]), uuid(parts[1]), parts[2].hasSuffix(".json") else { return nil }
            let id = String(parts[2].dropLast(5))
            return validSession(id) ? id.lowercased() : nil
        }
        return nil
    }

    private func backupPayloads(_ folder: URL, index: Int) throws -> [URL] {
        try safePath(folder)
        return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter {
            let name = $0.lastPathComponent
            return ["\(index)-before", "\(index)-displaced", "\(index)-new.json"].contains(name) || name.hasPrefix("\(index)-recovery-")
        }.sorted { $0.path < $1.path }
    }

    private func backupManifests() throws -> [URL] {
        let root = state.appendingPathComponent("backups")
        try safePath(root)
        guard exists(root) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }.compactMap { folder in
            guard folder.lastPathComponent.range(of: "^[0-9]+-[a-f0-9-]{36}$", options: .regularExpression) != nil else { return nil }
            let manifest = folder.appendingPathComponent("manifest.json")
            guard exists(manifest) else { return nil }
            let document = try readJSON(manifest)
            guard ["complete", "rolled-back", "purged"].contains(document["status"] as? String ?? "") else {
                throw SyncError("发现未完成的旧操作备份，请先处理后再永久清理。")
            }
            return manifest
        }
    }

    /// Includes nondeleted records in all managed copies so shared transcripts are protected.
    private func sessionPayloads(validateRecoveryDigests: Bool = true) throws -> [SessionPayload] {
        var result: [SessionPayload] = []
        func append(_ file: URL, expected: String, category: String, archive: Bool = false) throws {
            let value = try readJSON(file)
            guard let id = value["sessionId"] as? String, validSession(id), id.lowercased() == expected,
                  let cli = value["cliSessionId"] as? String, uuid(cli),
                  value["priorCliSessionIds"] == nil || (value["priorCliSessionIds"] as? [String])?.allSatisfy({ uuid($0) }) == true else {
                throw SyncError("会话副本格式无法识别，已停止准备清理：\(file.lastPathComponent)")
            }
            if archive {
                guard file.deletingPathExtension().lastPathComponent == sha(try Data(contentsOf: file)) else { throw SyncError("会话归档校验失败") }
            }
            result.append(SessionPayload(file: file, value: value, category: category))
        }
        for owner in try history.owners() {
            for file in try fm.contentsOfDirectory(at: owner.directory, includingPropertiesForKeys: nil) {
                if let id = nativeSessionID(file) { try append(file, expected: id, category: "账号记录") }
            }
        }
        let archive = history.vault.appendingPathComponent("records")
        try safePath(archive)
        if exists(archive) {
            for folder in try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil) where validSession(folder.lastPathComponent) {
                for file in try treeFiles(folder) {
                    guard file.deletingLastPathComponent() == folder, file.pathExtension == "json" else { throw SyncError("归档中存在未知内容，已停止清理") }
                    try append(file, expected: folder.lastPathComponent.lowercased(), category: "元数据归档", archive: true)
                }
            }
        }
        for entry in try cleanupEntries() {
            let content = state.appendingPathComponent("removed-records/\(entry.id)/content")
            if validateRecoveryDigests && exists(content) { guard try digestTree(content) == entry.digest else { throw SyncError("账户恢复副本校验失败") } }
            for file in try treeFiles(content) where file.deletingLastPathComponent() == content && file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                if validSession(id) { try append(file, expected: id.lowercased(), category: "账户恢复副本") }
            }
        }
        for manifest in try backupManifests() {
            let document = try readJSON(manifest)
            guard let entries = document["entries"] as? [[String: Any]] else { throw SyncError("操作备份索引格式错误") }
            for (i, entry) in entries.enumerated() {
                guard let destination = entry["destination"] as? String else { throw SyncError("操作备份缺少目标路径") }
                // No login snapshots, API configuration or project source files are inspected.
                guard ["Claude", "Claude-3p"].contains(where: { destination == support.appendingPathComponent($0 + "/claude-code-sessions").path || destination.hasPrefix(support.appendingPathComponent($0 + "/claude-code-sessions").path + "/") }) else { continue }
                for payload in try backupPayloads(manifest.deletingLastPathComponent(), index: i) {
                    for file in try treeFiles(payload) {
                        let relative = String(file.path.dropFirst(payload.path.count))
                        if let id = nativeSessionID(URL(fileURLWithPath: destination + relative)) {
                            try append(file, expected: id, category: "操作备份")
                        }
                    }
                }
            }
        }
        return result.sorted { $0.file.path < $1.file.path }
    }

    private func transcriptRoots(_ ids: Set<String>) throws -> [(URL, String)] {
        var roots: [(URL, String)] = []
        let projects = home.appendingPathComponent(".claude/projects")
        try safePath(projects)
        if exists(projects) {
            for project in try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) {
                try safePath(project)
                guard (try fm.attributesOfItem(atPath: project.path)[.type] as? FileAttributeType) == .typeDirectory else { continue }
                for file in try fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) {
                    if ids.contains(file.deletingPathExtension().lastPathComponent.lowercased()), file.pathExtension == "jsonl" {
                        roots.append((file, "本机正文"))
                    } else if ids.contains(file.lastPathComponent.lowercased()) {
                        roots.append((file, "会话附件与子任务"))
                    }
                }
            }
        }
        for id in ids.sorted() {
            let folder = history.vault.appendingPathComponent("transcripts/" + id)
            try safePath(folder)
            if exists(folder) { roots.append((folder, "正文归档")) }
        }
        return roots
    }

    public func deletedSessionRecords() throws -> [DeletedSessionInfo] {
        try locked(state) {
            guard !hasPendingOperation else { throw SyncError("请先完成上次操作。") }
            return try deletedSessionRecords(payloads: sessionPayloads())
        }
    }

    private func deletedSessionRecords(payloads: [SessionPayload]) throws -> [DeletedSessionInfo] {
        let deleted = try history.deletedSessions()
        return try Dictionary(grouping: payloads, by: \.id).compactMap { id, copies in
            guard let timestamp = deleted[id] else { return nil }
            let value = copies.max { ($0.value["lastActivityAt"] as? Double ?? 0) < ($1.value["lastActivityAt"] as? Double ?? 0) }!.value
            let cli = copies.reduce(into: Set<String>()) { $0.formUnion($1.cliIDs) }
            let bodies = try transcriptRoots(cli).reduce(0) { try $0 + treeFiles($1.0).count }
            return DeletedSessionInfo(id: id, title: value["title"] as? String ?? "未命名会话", project: value["originCwd"] as? String ?? value["cwd"] as? String ?? "", deletedAt: Double(timestamp) / 1000,
                nativeCopies: copies.filter { $0.category == "账号记录" }.count,
                archiveVersions: copies.filter { $0.category == "元数据归档" }.count,
                backupCopies: copies.filter { ["操作备份", "账户恢复副本"].contains($0.category) }.count, transcriptCopies: bodies)
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    public func previewSessionPurge(ids: [String]) throws -> SessionPurgePreview {
        try locked(state) {
            guard !hasPendingOperation else { throw SyncError("请先完成上次操作。") }
            let (plan, sessions, files) = try buildSessionPurge(ids: ids)
            return SessionPurgePreview(sessions: sessions, files: files, updatedIndexes: plan.actions.filter { $0.kind == "metadata" }.count, fingerprint: try plan.fingerprint)
        }
    }

    private func ensureExclusiveTranscripts(_ cli: Set<String>, selected: Set<String>, payloads: [SessionPayload]) throws {
        if let shared = payloads.first(where: { !selected.contains($0.id) && !$0.cliIDs.isDisjoint(with: cli) }) {
            throw SyncError("正文仍被其他会话“\(shared.value["title"] as? String ?? shared.id)”引用，未准备清理。若它也已删除，请一并选择；否则需保留正文。")
        }
    }

    func buildSessionPurge(ids: [String]) throws -> (SessionPurgePlan, [DeletedSessionInfo], [SessionPurgeFile]) {
        try checkCompatibility(configuration: false)
        let selected = Set(ids)
        guard !ids.isEmpty, selected.count == ids.count, ids.allSatisfy({ validSession($0) && $0 == $0.lowercased() }) else { throw SyncError("请选择已删除会话") }
        let payloads = try sessionPayloads(), all = try deletedSessionRecords(payloads: payloads)
        let sessions = all.filter { selected.contains($0.id) }
        guard sessions.count == selected.count else { throw SyncError("会话不再符合清理条件，请刷新后重试") }
        let targets = payloads.filter { selected.contains($0.id) }
        guard targets.allSatisfy({ $0.value["sshHost"] == nil && $0.value["remoteSessionId"] == nil && $0.value["environmentId"] == nil }) else { throw SyncError("所选会话含远程记录，不支持永久清理") }
        let cli = targets.reduce(into: Set<String>()) { $0.formUnion($1.cliIDs) }
        try ensureExclusiveTranscripts(cli, selected: selected, payloads: payloads)
        var actions: [String: PurgeAction] = [:], files: [String: SessionPurgeFile] = [:]
        func remove(_ root: URL, category: String) throws {
            try safePath(root)
            guard exists(root) else { return }
            let type = try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType
            if type == .typeDirectory {
                for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) { try remove(child, category: category) }
                actions[root.path] = PurgeAction(path: root.path, kind: "directory", digest: nil, replacement: nil, bytes: 0)
            } else if type == .typeRegular {
                let data = try Data(contentsOf: root)
                actions[root.path] = PurgeAction(path: root.path, kind: "file", digest: sha(data), replacement: nil, bytes: Int64(data.count))
                files[root.path] = SessionPurgeFile(path: root.path, category: category, bytes: Int64(data.count))
            } else { throw SyncError("清理范围含特殊文件，已停止") }
        }
        func rewrite(_ file: URL, value: Any) throws {
            let before = try Data(contentsOf: file), after = try jsonData(value)
            guard before != after else { return }
            actions[file.path] = PurgeAction(path: file.path, kind: "metadata", digest: sha(before), replacement: after, bytes: 0)
        }
        for item in targets { try remove(item.file, category: item.category) }
        for (root, category) in try transcriptRoots(cli) { try remove(root, category: category) }
        for id in ids { try remove(history.vault.appendingPathComponent("records/" + id), category: "元数据归档") }
        let index = history.vault.appendingPathComponent("index.json")
        if exists(index) { try rewrite(index, value: readJSON(index).filter { !selected.contains($0.key.lowercased()) }) }

        // Keep unrelated records in a directory recovery copy restorable after selective erasure.
        if exists(cleanupIndex) {
            guard var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: cleanupIndex)) as? [[String: Any]] else { throw SyncError("恢复索引格式无效") }
            for i in entries.indices {
                let content = state.appendingPathComponent("removed-records/\(entries[i]["id"] as! String)/content")
                let allFiles = try treeFiles(content), kept = allFiles.filter { actions[$0.path]?.kind != "file" }
                guard kept.count != allFiles.count else { continue }
                var digest = SHA256()
                for file in kept { digest.update(data: Data(file.path.dropFirst(content.path.count).utf8)); digest.update(data: try Data(contentsOf: file)) }
                entries[i]["digest"] = digest.finalize().map { String(format: "%02x", $0) }.joined()
                entries[i]["sessionCount"] = kept.filter { $0.deletingLastPathComponent() == content && validSession($0.deletingPathExtension().lastPathComponent) && $0.pathExtension == "json" }.count
                entries[i]["bytes"] = try kept.reduce(Int64(0)) { try $0 + Int64(Data(contentsOf: $1).count) }
            }
            try rewrite(cleanupIndex, value: entries)
        }
        for manifest in try backupManifests() {
            var document = try readJSON(manifest), changed = false
            guard var entries = document["entries"] as? [[String: Any]] else { throw SyncError("操作备份索引格式错误") }
            for i in entries.indices {
                let payloads = try backupPayloads(manifest.deletingLastPathComponent(), index: i)
                if payloads.contains(where: { root in actions.values.contains { $0.kind == "file" && ($0.path == root.path || $0.path.hasPrefix(root.path + "/")) } }) {
                    entries[i].removeValue(forKey: "digest"); entries[i]["permanentlyPruned"] = true; changed = true
                }
            }
            if changed {
                document["entries"] = entries; document["status"] = "purged"
                document["purgedSessionIDs"] = Set((document["purgedSessionIDs"] as? [String] ?? []) + ids).sorted()
                try rewrite(manifest, value: document)
            }
        }
        let ordered = actions.values.sorted {
            let rank: (PurgeAction) -> Int = { $0.kind == "file" ? 0 : $0.kind == "directory" ? 1 : 2 }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.kind == "directory", $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.path < $1.path
        }
        return (SessionPurgePlan(ids: ids.sorted(), cliIDs: cli.sorted(), actions: ordered), sessions, files.values.sorted { $0.path < $1.path })
    }

    func validateSessionPurgePlan(_ plan: SessionPurgePlan) throws {
        let deleted = try history.deletedSessions()
        guard plan.version == 1, !plan.ids.isEmpty, Set(plan.ids).count == plan.ids.count,
              plan.ids.allSatisfy({ validSession($0) && deleted[$0] != nil }),
              !plan.cliIDs.isEmpty, plan.cliIDs.allSatisfy({ uuid($0) }),
              Set(plan.actions.map(\.path)).count == plan.actions.count else { throw SyncError("会话清理清单无效") }
        let backupPaths = try remainingPurgeMetadata(plan)
        for action in plan.actions {
            let file = URL(fileURLWithPath: action.path), relative = String(action.path.dropFirst(state.path.count + 1))
            guard file.standardizedFileURL.path == action.path else { throw SyncError("清理路径无效") }
            try safePath(file)
            var allowed = false
            if action.kind == "metadata" {
                allowed = file == history.vault.appendingPathComponent("index.json") || file == cleanupIndex
                if action.path.hasPrefix(state.path + "/backups/") {
                    let parts = relative.split(separator: "/")
                    allowed = parts.count == 3 && parts[2] == "manifest.json" && String(parts[1]).range(of: "^[0-9]+-[a-f0-9-]{36}$", options: .regularExpression) != nil
                }
            } else if let id = nativeSessionID(file) { allowed = action.kind == "file" && plan.ids.contains(id) }
            else {
                for (sub, ids) in [("history/records", plan.ids), ("history/transcripts", plan.cliIDs)] {
                    allowed = allowed || ids.contains { let root = state.appendingPathComponent(sub + "/" + $0).path; return action.path == root || action.path.hasPrefix(root + "/") }
                }
                let projects = home.appendingPathComponent(".claude/projects").path + "/"
                if action.path.hasPrefix(projects) {
                    let parts = String(action.path.dropFirst(projects.count)).split(separator: "/").map(String.init)
                    allowed = parts.count >= 2 && (plan.cliIDs.contains(parts[1].lowercased()) || (parts.count == 2 && parts[1].hasSuffix(".jsonl") && plan.cliIDs.contains(String(parts[1].dropLast(6)).lowercased()) && action.kind == "file"))
                }
                // Restrict backup erasure to metadata payloads recognized by the journal mapping.
                if action.path.hasPrefix(state.path + "/backups/") || action.path.hasPrefix(state.path + "/removed-records/") {
                    allowed = action.kind == "file" && backupPaths.contains(action.path)
                }
            }
            guard allowed, ["file", "directory", "metadata"].contains(action.kind),
                  action.kind == "directory" || action.digest?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  (action.kind == "metadata") == (action.replacement != nil) else { throw SyncError("清理清单含范围外操作") }
        }
    }

    /// Verify existing backup payloads; removed payloads remain resumable via the recorded path mapping.
    private func remainingPurgeMetadata(_ plan: SessionPurgePlan) throws -> Set<String> {
        var paths = Set<String>()
        for entry in try cleanupEntries() {
            for id in plan.ids { paths.insert(state.appendingPathComponent("removed-records/\(entry.id)/content/\(id).json").path) }
        }
        for manifest in try backupManifests() {
            guard let entries = try readJSON(manifest)["entries"] as? [[String: Any]] else { throw SyncError("操作备份索引格式错误") }
            for (i, entry) in entries.enumerated() {
                guard let destination = entry["destination"] as? String else { throw SyncError("备份目标缺失") }
                // Include already-removed direct payload names when resuming.
                let folder = manifest.deletingLastPathComponent()
                var roots = try backupPayloads(folder, index: i)
                roots += ["\(i)-before", "\(i)-displaced", "\(i)-new.json"].map { folder.appendingPathComponent($0) }
                for action in plan.actions where action.path.hasPrefix(folder.path + "/") {
                    let first = String(action.path.dropFirst(folder.path.count + 1)).split(separator: "/").first.map(String.init) ?? ""
                    if first.hasPrefix("\(i)-recovery-"), uuid(String(first.dropFirst("\(i)-recovery-".count))) { roots.append(folder.appendingPathComponent(first)) }
                }
                for action in plan.actions where action.kind == "file" {
                    for root in roots where action.path == root.path || action.path.hasPrefix(root.path + "/") {
                        let mapped = URL(fileURLWithPath: destination + String(action.path.dropFirst(root.path.count)))
                        if let id = nativeSessionID(mapped), plan.ids.contains(id) { paths.insert(action.path) }
                    }
                }
            }
        }
        return paths
    }

    func executeSessionPurge(_ plan: SessionPurgePlan, beforeAction: (() throws -> Void)? = nil) throws {
        try validateSessionPurgePlan(plan)
        let replacementPaths = Set(plan.actions.filter { $0.kind == "file" }.map(\.path))
        // Recovery copies can have stale digests after an interrupted selective deletion, so use
        // file-level hashes in the persisted plan instead of re-entering the inventory builder.
        for action in plan.actions where action.kind != "directory" {
            let file = URL(fileURLWithPath: action.path)
            if !exists(file) { guard action.kind == "file" else { throw SyncError("清理期间索引被移除") }; continue }
            let digest = try sha(Data(contentsOf: file))
            guard digest == action.digest || action.replacement.map({ sha($0) }) == digest else { throw SyncError("文件已变化，停止清理，请保留执行清单") }
        }
        let payloads = try sessionPayloads(validateRecoveryDigests: false), selected = Set(plan.ids)
        try ensureExclusiveTranscripts(Set(plan.cliIDs), selected: selected, payloads: payloads)
        guard payloads.filter({ selected.contains($0.id) }).allSatisfy({ replacementPaths.contains($0.file.path) }) else { throw SyncError("出现新的会话副本，请保留清理清单并检查") }
        for (root, _) in try transcriptRoots(Set(plan.cliIDs)) {
            guard try treeFiles(root).allSatisfy({ replacementPaths.contains($0.path) }) else { throw SyncError("正文目录出现新文件，已停止清理") }
        }
        for action in plan.actions {
            try beforeAction?()
            guard !process.running, process.workers == 0 else { throw SyncError("Claude 已重新启动，请退出后继续清理") }
            let file = URL(fileURLWithPath: action.path)
            try safePath(file)
            if let replacement = action.replacement {
                let digest = try sha(Data(contentsOf: file))
                if digest == sha(replacement) { continue }
                guard digest == action.digest else { throw SyncError("索引发生变化，已停止清理") }
                try atomicData(replacement, file)
            } else if exists(file) {
                if action.kind == "directory" {
                    guard try fm.contentsOfDirectory(atPath: file.path).isEmpty else { throw SyncError("目录出现新内容，已停止清理") }
                } else {
                    guard replacementPaths.contains(file.path), try sha(Data(contentsOf: file)) == action.digest else { throw SyncError("文件发生变化，已停止清理") }
                }
                try fm.removeItem(at: file)
                let fd = open(file.deletingLastPathComponent().path, O_RDONLY)
                if fd >= 0 { _ = fsync(fd); close(fd) }
            }
        }
        try fm.removeItem(at: pendingSessionPurge)
    }

    public func purgeDeletedSessions(_ preview: SessionPurgePreview, allowOpenSessions: Bool = false) throws -> Outcome {
        try locked(state) {
            guard !hasPendingOperation else { throw SyncError("请先完成上次操作。") }
            let ids = preview.sessions.map(\.id)
            var plan = try buildSessionPurge(ids: ids).0
            guard try plan.fingerprint == preview.fingerprint else { throw SyncError("清理范围或内容已变化，请重新预览并确认") }
            let wasRunning = process.running
            try process.stop(allowOpenSessions: allowOpenSessions)
            do {
                plan = try buildSessionPurge(ids: ids).0
                guard try plan.fingerprint == preview.fingerprint else { throw SyncError("退出 Claude 后内容发生变化，请重新预览并确认") }
                _ = try history.rememberDeletions()
                plan.restartClaude = wasRunning
                try validateSessionPurgePlan(plan)
                try atomicData(JSONEncoder().encode(plan), pendingSessionPurge)
                try executeSessionPurge(plan)
            } catch {
                if exists(pendingSessionPurge) { throw SyncError("永久清理未完成。已删除内容不会恢复，请点击“继续永久清除”。\n\(error.localizedDescription)") }
                if wasRunning { try? process.start() }
                throw error
            }
            return finishSessionPurge(plan, restart: wasRunning)
        }
    }

    public func resumeSessionPurge(allowOpenSessions: Bool = false) throws -> Outcome {
        try locked(state) {
            try checkCompatibility(configuration: false)
            guard !exists(state.appendingPathComponent("pending.json")), !exists(pendingPurge) else { throw SyncError("请先处理其他未完成操作") }
            try safePath(pendingSessionPurge)
            let plan = try JSONDecoder().decode(SessionPurgePlan.self, from: Data(contentsOf: pendingSessionPurge))
            try validateSessionPurgePlan(plan)
            let wasRunning = process.running
            try process.stop(allowOpenSessions: allowOpenSessions)
            try executeSessionPurge(plan)
            return finishSessionPurge(plan, restart: wasRunning || plan.restartClaude)
        }
    }

    private func finishSessionPurge(_ plan: SessionPurgePlan, restart: Bool) -> Outcome {
        var suffix = ""
        if restart { do { try process.start() } catch { suffix = "Claude 未能重开，请手动打开。" } }
        return Outcome(message: "已永久清理 \(plan.ids.count) 条已删除会话的正文、归档和相关备份；保留删除标记以防重新导入。\(suffix)", added: plan.ids.count)
    }
}
