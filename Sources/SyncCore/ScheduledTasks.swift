import Foundation
import CoreFoundation

struct TaskManifest {
    let owner: Owner
    var value: [String: Any]
    var tasks: [[String: Any]] { value["scheduledTasks"] as? [[String: Any]] ?? [] }
    var file: URL { owner.directory.appendingPathComponent("scheduled-tasks.json") }
}

// Native task IDs and prompt files are shared on this Mac. Keep IDs stable so run history,
// jitter and notification references retain their meaning across account changes.
enum LocalSchedule {
    static let definitionKeys: Set<String> = ["id", "displayName", "cronExpression", "fireAt", "enabled", "filePath", "model", "createdAt", "cwd", "useWorktree", "sourceBranch", "disableJitter", "notifySessionId", "dispatchSubscribed"]
    static let runtimeKeys: Set<String> = ["lastRunAt", "lastScheduledFor", "missedRunScanFloor"]
    static let localKeys: Set<String> = ["permissionMode", "permissionModeCarried", "approvedPermissions", "chromePermissionMode", "chromeAllowedDomains", "observedToolUse", "userSelectedFolders", "userSelectedFiles"]
    static let envelopeKeys: Set<String> = ["scheduledTasks", "recordedSkips", "recordedPlaceSkips", "runRetries", "sundayAliasBoundaryStamped", "dayFieldsOrBoundaryStamped"]
    static func validID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9_-]{0,119}$", options: .regularExpression) != nil
    }
    static func definition(_ task: [String: Any]) -> [String: Any] { task.filter { definitionKeys.contains($0.key) } }
    static func fingerprint(_ task: [String: Any]) throws -> String { try sha(jsonData(definition(task))) }
    static func titleKey(_ task: [String: Any]) -> String {
        let name = (task["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (name.isEmpty ? (task["id"] as! String).replacingOccurrences(of: "-", with: " ") : name)
            .precomposedStringWithCompatibilityMapping.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func promptModel(_ task: [String: Any]) throws -> String? {
        let file = URL(fileURLWithPath: task["filePath"] as! String)
        try safePath(file)
        let content = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        // Match Desktop's SKILL.md parser, not a general YAML interpreter.
        let regex = try NSRegularExpression(pattern: "^---\\n([\\s\\S]*?)\\n---\\n+([\\s\\S]*)$")
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let headerRange = Range(match.range(at: 1), in: content), let bodyRange = Range(match.range(at: 2), in: content),
              !content[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SyncError("定时任务提示词格式不完整：\(task["id"] as! String)") }
        let lines = content[headerRange].components(separatedBy: "\n")
        guard lines.contains(where: { $0.hasPrefix("name: ") && $0.count > 6 }), lines.contains(where: { $0 == "description:" || $0.hasPrefix("description: ") }) else { throw SyncError("定时任务提示词缺少 name/description：\(task["id"] as! String)") }
        guard let line = lines.first(where: { $0.hasPrefix("model: ") }) else { return nil }
        var model = String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("\""), model.hasSuffix("\""), model.count > 2 { model = String(model.dropFirst().dropLast()) }
        return model.isEmpty || ["default", "inherit"].contains(model.lowercased()) ? nil : model
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func bool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
    static func validate(_ task: [String: Any], home: URL, files: Bool = true) throws {
        let name = task["id"] as? String ?? "未知任务"
        func fail(_ reason: String) -> SyncError { SyncError("定时任务“\(name)”\(reason)。请在 Claude 中处理后重试。") }
        guard validID(name), bool(task["enabled"]), let created = task["createdAt"] as? Double, created.isFinite,
              let path = task["filePath"] as? String, let cwd = task["cwd"] as? String, cwd.hasPrefix("/") else { throw fail("格式不兼容") }
        let unknown = Set(task.keys).subtracting(definitionKeys.union(runtimeKeys).union(localKeys))
        guard unknown.isEmpty else { throw fail("含尚不支持的字段：\(unknown.sorted().joined(separator: "、"))") }
        for key in ["displayName", "model", "sourceBranch", "notifySessionId", "cronExpression"] {
            if let value = task[key], !(value is String) { throw fail("的 \(key) 格式无效") }
        }
        for key in ["useWorktree", "disableJitter", "dispatchSubscribed"] {
            if let value = task[key], !bool(value) { throw fail("的 \(key) 格式无效") }
        }
        if let cron = task["cronExpression"] as? String {
            guard cron.split(whereSeparator: { $0.isWhitespace }).count == 5,
                  cron.range(of: "^[0-9*/?,\\-\\s]+$", options: .regularExpression) != nil,
                  task["fireAt"] == nil else { throw fail("的调度表达式无法安全同步") }
        }
        if let fire = task["fireAt"] { guard let number = fire as? Double, number.isFinite, number > 0 else { throw fail("的单次执行时间无效") } }
        for key in runtimeKeys {
            if let value = task[key] { guard let value = value as? String, date(value) != nil else { throw fail("的运行时间无效") } }
        }
        if let ref = task["notifySessionId"] as? String, !validSession(ref) { throw fail("引用了非本机通知会话") }
        // Custom CLAUDE_CONFIG_DIR and remote/Cowork tasks require a separate adapter.
        let expected = home.appendingPathComponent(".claude/scheduled-tasks/\(name)/SKILL.md").standardizedFileURL
        guard URL(fileURLWithPath: path).standardizedFileURL == expected else { throw fail("的提示词不在已适配的本机共享目录") }
        if files {
            try safePath(expected); try safePath(URL(fileURLWithPath: cwd))
            guard exists(expected), let attrs = try? fm.attributesOfItem(atPath: expected.path),
                  attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? NSNumber,
                  size.intValue > 0, size.intValue <= 1024 * 1024 else { throw fail("缺少提示词文件，或文件超过 1 MB") }
            _ = try promptModel(task)
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { throw fail("的工作目录不可用") }
        }
    }
}

extension Engine {
    var scheduleLedger: URL { state.appendingPathComponent("scheduled-tasks.json") }

    func taskManifests() throws -> [TaskManifest] {
        try history.owners().compactMap { owner in
            let file = owner.directory.appendingPathComponent("scheduled-tasks.json")
            guard exists(file) else { return nil }
            let value = try readNativeRecordJSON(file, running: process.running)
            guard let tasks = value["scheduledTasks"] as? [[String: Any]],
                  Set(value.keys).isSubset(of: LocalSchedule.envelopeKeys),
                  tasks.allSatisfy({ ($0["id"] as? String).map(LocalSchedule.validID) == true }),
                  Set(tasks.compactMap { $0["id"] as? String }).count == tasks.count else {
                throw SyncError("定时任务登记格式不兼容：\(owner.key)。未同步任务。")
            }
            for key in ["recordedSkips", "recordedPlaceSkips", "runRetries"] {
                if let field = value[key], !(field is [String: Any]) { throw SyncError("定时任务的 \(key) 格式无法识别") }
            }
            return TaskManifest(owner: owner, value: value)
        }
    }

    func readScheduleLedger() throws -> [String: Any] {
        let ledger = try readJSON(scheduleLedger, optional: true)
        guard ledger.isEmpty || ledger["version"] as? Int == 1 && ledger["tasks"] is [String: [String: Any]] else { throw SyncError("共享定时任务索引无法识别") }
        if let raw = ledger["lastTargets"] {
            guard let keys = raw as? [String], Set(keys).count == keys.count, keys.allSatisfy({ key in
                let parts = key.components(separatedBy: "/")
                return parts.count == 3 && ["Claude", "Claude-3p"].contains(parts[0]) && uuid(parts[1]) && uuid(parts[2])
            }) else { throw SyncError("定时任务工作区同步基线无法识别") }
        }
        for (id, entry) in ledger["tasks"] as? [String: [String: Any]] ?? [:] {
            guard LocalSchedule.validID(id), let definition = entry["definition"] as? [String: Any], definition["id"] as? String == id,
                  entry["copies"] is [String: String] else { throw SyncError("共享定时任务索引损坏") }
            try LocalSchedule.validate(definition, home: home, files: false)
            for (key, raw) in entry["runtime"] as? [String: Any] ?? [:] {
                guard LocalSchedule.runtimeKeys.contains(key), let time = raw as? String, LocalSchedule.date(time) != nil else { throw SyncError("共享定时任务运行时间损坏") }
            }
        }
        return ledger
    }

    /// Three-way reconciliation: a changed copy wins only if all changed copies agree.
    /// A missing task is removal only in a source workspace successfully synchronized on
    /// the previous operation. Missing manifests/account directories never imply deletion.
    /// Resolve once before any destination write so directory order cannot change the result.
    func synchronizeTasks(from source: [Owner], into targets: [Owner], transaction tx: Transaction) throws -> Int {
        let importFloor = ISO8601DateFormatter().string(from: Date())
        var manifests = try taskManifests(), ledger = try readScheduleLedger()
        let existingManifestOwners = Set(manifests.map { $0.owner.key })
        let originalFiles = try Dictionary(uniqueKeysWithValues: manifests.map { ($0.file, try digestTree($0.file)) })
        var promptFiles: [URL: String] = [:]
        var entries = ledger["tasks"] as? [String: [String: Any]] ?? [:]
        let hasTasks = manifests.contains { !$0.tasks.isEmpty } || entries.values.contains { $0["deleted"] as? Bool != true }
        guard !targets.isEmpty else {
            if hasTasks { throw SyncError("目标账号尚未建立 Code 目录；请先在 Claude 中选择工作区并进入一次 Code，再同步定时任务。") }
            return 0
        }
        for target in targets where !manifests.contains(where: { $0.owner == target }) {
            manifests.append(TaskManifest(owner: target, value: ["scheduledTasks": [], "recordedSkips": [:]]))
        }
        let previousTargets = ledger["lastTargets"] as? [String] ?? (ledger["activeOwner"] as? String).map { [$0] } ?? []
        let trackedSources = Set(source.map(\.key)).intersection(previousTargets)
        let ids = Set(entries.keys).union(manifests.flatMap { $0.tasks.compactMap { $0["id"] as? String } })
        var resolved: [String: [String: Any]] = [:], removed = Set<String>()
        for id in ids.sorted() {
            let copies = manifests.flatMap { m in m.tasks.filter { $0["id"] as? String == id }.map { (m.owner.key, $0) } }
            var entry = entries[id] ?? [:]
            var baselines = entry["copies"] as? [String: String] ?? [:]
            let wasDeleted = entry["deleted"] as? Bool == true
            let missingSource = trackedSources.contains { key in
                baselines[key] != nil && existingManifestOwners.contains(key)
                    && manifests.contains { $0.owner.key == key && !$0.tasks.contains { $0["id"] as? String == id } }
            }
            if wasDeleted || missingSource {
                // A recreated ID with a new definition needs explicit reconciliation, never erase it.
                for (owner, task) in copies {
                    guard let baseline = baselines[owner], try LocalSchedule.fingerprint(task) == baseline else {
                        throw SyncError("定时任务“\(id)”的删除与修改冲突；请先在 Claude 中为要保留的任务换一个名称。")
                    }
                }
                entry["deleted"] = true; entries[id] = entry; removed.insert(id); continue
            }
            var changes: [String: [String: Any]] = [:]
            for (owner, task) in copies {
                try LocalSchedule.validate(task, home: home)
                let prompt = URL(fileURLWithPath: task["filePath"] as! String)
                if promptFiles[prompt] == nil { promptFiles[prompt] = try digestTree(prompt) }
                let fingerprint = try LocalSchedule.fingerprint(task)
                if baselines[owner] != fingerprint { changes[fingerprint] = LocalSchedule.definition(task) }
            }
            guard changes.count <= 1 else { throw SyncError("定时任务“\(id)”在多个账户中有不同修改；已保留各账户内容，请在 Claude 中统一任务设置或改名后重试。") }
            guard let definition = changes.values.first ?? entry["definition"] as? [String: Any] else { continue }
            try LocalSchedule.validate(definition, home: home)
            let prompt = URL(fileURLWithPath: definition["filePath"] as! String)
            if promptFiles[prompt] == nil { promptFiles[prompt] = try digestTree(prompt) }
            var task = definition
            // Keep the furthest dispatched slot, including copies left behind on earlier switches.
            let previousRuntime = entry["runtime"] as? [String: Any] ?? [:]
            for key in LocalSchedule.runtimeKeys {
                let times = (copies.map { $0.1 } + [previousRuntime]).compactMap { $0[key] as? String }
                task[key] = times.max { LocalSchedule.date($0)! < LocalSchedule.date($1)! }
            }
            if targets.contains(where: { target in !copies.contains { $0.0 == target.key } }) {
                if task["enabled"] as? Bool == true, let fireAt = task["fireAt"] as? Double, fireAt <= Date().timeIntervalSince1970 * 1000 {
                    throw SyncError("单次定时任务“\(id)”已到执行时间；请先在原账户执行或停用，避免导入时意外补跑。")
                }
                // Use one scan floor for all destinations, including existing copies, so
                // the resulting runtime union is independent of workspace write order.
                if LocalSchedule.date(task["missedRunScanFloor"] as? String ?? "") ?? .distantPast < LocalSchedule.date(importFloor)! { task["missedRunScanFloor"] = importFloor }
            }
            if let ref = task["notifySessionId"] as? String {
                if try history.deletedSessions()[ref.lowercased()] != nil { task.removeValue(forKey: "notifySessionId") }
                else if targets.contains(where: { !exists($0.directory.appendingPathComponent(ref + ".json")) }) {
                    throw SyncError("定时任务“\(id)”的通知会话缺少可导入正文，请先恢复该会话或在 Claude 中移除通知关联。")
                }
            }
            for (owner, copy) in copies { baselines[owner] = try LocalSchedule.fingerprint(copy) }
            for target in targets {
                try validateTaskModel(task, target: target)
                baselines[target.key] = try LocalSchedule.fingerprint(task)
            }
            entry["definition"] = LocalSchedule.definition(task)
            entry["runtime"] = task.filter { LocalSchedule.runtimeKeys.contains($0.key) }
            entry["copies"] = baselines
            entries[id] = entry; resolved[id] = task
        }
        let names = Dictionary(grouping: resolved.values, by: LocalSchedule.titleKey)
        guard names.values.allSatisfy({ $0.count == 1 }) else { throw SyncError("不同定时任务使用了相同名称；请在 Claude 中改名后切换，避免重复调度。") }
        var destinations: [(TaskManifest, [String: Any])] = [], imported = 0
        for target in targets {
            let original = manifests.first { $0.owner == target }!
            var destination = original.value
            destination["scheduledTasks"] = resolved.keys.sorted().map { id -> [String: Any] in
                var task = resolved[id]!
                // Approvals belong to this exact account/workspace, never its sibling.
                if let existing = original.tasks.first(where: { $0["id"] as? String == id }) {
                    task.merge(existing.filter { LocalSchedule.localKeys.contains($0.key) }) { _, old in old }
                } else {
                    task["permissionMode"] = "default"; task["chromePermissionMode"] = "ask"
                    imported += 1
                }
                return task
            }
            // Union skip history, retaining retry state only when unambiguous. Never replay a stale retry.
            for key in ["recordedSkips", "recordedPlaceSkips"] {
                var combined = (destination[key] as? [String: Any] ?? [:]).filter { !removed.contains($0.key) }
                for id in resolved.keys {
                    var rows: [String: Any] = [:]
                    for manifest in manifests {
                        if let raw = (manifest.value[key] as? [String: Any])?[id] {
                            guard let list = raw as? [[String: Any]] else { throw SyncError("定时任务“\(id)”的跳过记录无法识别") }
                            for row in list { rows[try sha(jsonData(row))] = row }
                        }
                    }
                    if !rows.isEmpty {
                        combined[id] = rows.keys.sorted().compactMap { rows[$0] as? [String: Any] }.sorted {
                            ($0["at"] as? Double ?? 0) < ($1["at"] as? Double ?? 0)
                        }
                    }
                }
                if !combined.isEmpty || destination[key] != nil { destination[key] = combined }
            }
            for manifest in manifests {
                if let retries = manifest.value["runRetries"] as? [String: Any], !retries.isEmpty {
                    throw SyncError("有定时任务正在等待重试；请在 Claude 中完成或取消重试后再切换。")
                }
            }
            // Migration flags must agree; transferring an unstamped cron can change its meaning.
            for key in ["sundayAliasBoundaryStamped", "dayFieldsOrBoundaryStamped"] {
                let flags = Set(manifests.filter { !$0.tasks.isEmpty }.map { $0.value[key] as? Bool ?? false })
                guard flags.count <= 1 else { throw SyncError("账户间定时任务调度格式不同，请先分别打开 Claude 完成原生迁移。") }
                if let flag = flags.first { destination[key] = flag }
            }
            destinations.append((original, destination))
        }
        for (file, fingerprint) in originalFiles.merging(promptFiles, uniquingKeysWith: { original, _ in original }) {
            guard exists(file), try digestTree(file) == fingerprint else { throw SyncError("定时任务或提示词在同步期间发生变化，已停止操作，请重试。") }
        }
        for (original, _) in destinations where !existingManifestOwners.contains(original.owner.key) {
            guard !exists(original.file) else { throw SyncError("目标任务登记在同步期间出现，请重试。") }
        }
        for (original, destination) in destinations {
            if try jsonData(destination) != jsonData(original.value) { try tx.write(destination, to: original.file) }
        }
        for manifest in manifests where !targets.contains(manifest.owner) && manifest.tasks.contains(where: { removed.contains($0["id"] as? String ?? "") }) {
            var value = manifest.value
            value["scheduledTasks"] = manifest.tasks.filter { !removed.contains($0["id"] as? String ?? "") }
            for key in ["recordedSkips", "recordedPlaceSkips", "runRetries"] {
                if let rows = value[key] as? [String: Any] { value[key] = rows.filter { !removed.contains($0.key) } }
            }
            try tx.write(value, to: manifest.file)
        }
        if hasTasks || !entries.isEmpty {
            ledger["version"] = 1; ledger["tasks"] = entries
            ledger["lastTargets"] = targets.map(\.key).sorted()
            // Older versions can still use the single-workspace baseline. No guessed
            // active workspace is persisted when Claude will make that choice.
            ledger["activeOwner"] = targets.count == 1 ? targets[0].key : nil
            try tx.write(ledger, to: scheduleLedger)
        }
        return imported
    }

    func validateTaskModel(_ task: [String: Any], target: Owner) throws {
        guard target.profile == "Claude-3p", let model = try (task["model"] as? String) ?? LocalSchedule.promptModel(task), model != "default",
              let id = try metadata()["appliedId"] as? String else { return }
        let models = modelEntries(try readJSON(library.appendingPathComponent(id + ".json")))
        if !models.isEmpty && !models.contains(where: { bareModel($0["name"] as? String ?? "") == bareModel(model) }) {
            throw SyncError("定时任务“\(task["id"] as? String ?? "")”使用的模型 \(model) 不在目标 API 配置中；请先选择双方可用的模型。")
        }
    }

    func mergeWork(from source: [Owner], transaction tx: Transaction) throws -> Int {
        let targets = try syncTargets()
        let sessions = try history.merge(from: source, into: targets, transaction: tx)
        let tasks = try synchronizeTasks(from: source, into: targets, transaction: tx)
        tx.taskImports = tasks
        tx.syncedWorkspaceCount = targets.count
        return sessions
    }

    /// The active account's every workspace must have a reconciled copy before cleanup.
    func tasksPreservedOutside(_ owner: Owner) throws -> Bool {
        let targets = try syncTargets()
        guard !targets.isEmpty, !targets.contains(owner) else { return false }
        let manifests = try taskManifests()
        guard let source = manifests.first(where: { $0.owner == owner }) else { return false }
        let entries = try readScheduleLedger()["tasks"] as? [String: [String: Any]] ?? [:]
        for target in targets {
            guard let destination = manifests.first(where: { $0.owner == target }),
                  try taskCopyPreserved(source, in: destination, entries: entries) else { return false }
        }
        return true
    }

    private func taskCopyPreserved(_ source: TaskManifest, in destination: TaskManifest, entries: [String: [String: Any]]) throws -> Bool {
        for task in source.tasks {
            try LocalSchedule.validate(task, home: home)
            let id = task["id"] as! String
            guard let entry = entries[id], entry["deleted"] as? Bool != true,
                  let copy = destination.tasks.first(where: { $0["id"] as? String == id }),
                  let baselines = entry["copies"] as? [String: String],
                  try LocalSchedule.fingerprint(task) == LocalSchedule.fingerprint(copy),
                  try LocalSchedule.fingerprint(task) == baselines[source.owner.key],
                  try LocalSchedule.fingerprint(copy) == baselines[destination.owner.key] else { return false }
            try LocalSchedule.validate(copy, home: home)
            for key in LocalSchedule.runtimeKeys {
                if let timestamp = task[key] as? String {
                    guard let other = copy[key] as? String, LocalSchedule.date(other)! >= LocalSchedule.date(timestamp)! else { return false }
                }
            }
            for key in ["recordedSkips", "recordedPlaceSkips"] {
                let sourceRows = (source.value[key] as? [String: Any])?[id] as? [[String: Any]] ?? []
                let targetRows = (destination.value[key] as? [String: Any])?[id] as? [[String: Any]] ?? []
                let kept = Set(try targetRows.map { try sha(jsonData($0)) })
                guard try sourceRows.allSatisfy({ try kept.contains(sha(jsonData($0))) }) else { return false }
            }
        }
        return (source.value["runRetries"] as? [String: Any] ?? [:]).isEmpty
    }

    func applyTaskDeletions(transaction tx: Transaction) throws {
        let entries = try readScheduleLedger()["tasks"] as? [String: [String: Any]] ?? [:]
        let deleted = Set(entries.filter { $0.value["deleted"] as? Bool == true }.keys)
        guard !deleted.isEmpty else { return }
        for manifest in try taskManifests() where manifest.tasks.contains(where: { deleted.contains($0["id"] as? String ?? "") }) {
            for task in manifest.tasks where deleted.contains(task["id"] as? String ?? "") {
                let id = task["id"] as! String, baselines = entries[id]?["copies"] as? [String: String] ?? [:]
                guard try LocalSchedule.fingerprint(task) == baselines[manifest.owner.key] else { throw SyncError("恢复副本中的已删除任务“\(id)”有不同内容，已停止恢复。") }
            }
            var value = manifest.value
            value["scheduledTasks"] = manifest.tasks.filter { !deleted.contains($0["id"] as? String ?? "") }
            for key in ["recordedSkips", "recordedPlaceSkips", "runRetries"] {
                if let rows = value[key] as? [String: Any] { value[key] = rows.filter { !deleted.contains($0.key) } }
            }
            try tx.write(value, to: manifest.file)
        }
    }
}
