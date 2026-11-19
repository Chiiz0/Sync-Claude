import XCTest
@testable import SyncCore

extension CoreTests {
    func taskFixture(_ directory: URL, id: String = "daily-review", enabled: Bool = true, changes: [String: Any] = [:]) throws -> [String: Any] {
        let prompt = root.appendingPathComponent(".claude/scheduled-tasks/\(id)/SKILL.md")
        try atomicData(Data("---\nname: \(id)\ndescription: Review the project\n---\n\nReview the project.\n".utf8), prompt)
        try privateDir(root.appendingPathComponent("project"))
        var task: [String: Any] = ["id": id, "enabled": enabled, "filePath": prompt.path,
            "cwd": root.appendingPathComponent("project").path, "createdAt": 1000,
            "cronExpression": "0 9 * * *", "lastRunAt": "2026-11-01T09:01:00Z", "lastScheduledFor": "2026-11-01T09:00:00Z",
            "approvedPermissions": [["toolName": "private-account-tool"]], "permissionMode": "bypassPermissions"]
        task.merge(changes) { _, new in new }
        let file = directory.appendingPathComponent("scheduled-tasks.json")
        var document = try readJSON(file, optional: true), tasks = document["scheduledTasks"] as? [[String: Any]] ?? []
        tasks.append(task); document["scheduledTasks"] = tasks; document["recordedSkips"] = document["recordedSkips"] ?? [:]
        document["sundayAliasBoundaryStamped"] = true; document["dayFieldsOrBoundaryStamped"] = true
        try atomicJSON(document, file)
        return task
    }
    func editTask(_ directory: URL, id: String = "daily-review", _ edit: (inout [String: Any]) -> Void) throws {
        let file = directory.appendingPathComponent("scheduled-tasks.json")
        var document = try readJSON(file), tasks = document["scheduledTasks"] as! [[String: Any]]
        let index = try XCTUnwrap(tasks.firstIndex { $0["id"] as? String == id })
        edit(&tasks[index]); document["scheduledTasks"] = tasks
        try atomicJSON(document, file)
    }
    func tasks(_ directory: URL) throws -> [[String: Any]] {
        try readJSON(directory.appendingPathComponent("scheduled-tasks.json"), optional: true)["scheduledTasks"] as? [[String: Any]] ?? []
    }
    func scheduledRun(_ directory: URL, id: String? = nil, task: String = "daily-review") throws -> URL {
        let file = try fixture(directory, id: id)
        var value = try readJSON(file); value["scheduledTaskId"] = task; value["completedTurns"] = 1
        try atomicJSON(value, file)
        return file
    }
    func testTasksAndRunAssociationsFollowSyncWithoutDuplicating() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b)
        let file = try scheduledRun(source)
        let original = try taskFixture(source, changes: ["notifySessionId": "local_" + sid])
        _ = try taskFixture(source, id: "paused", enabled: false)
        let prompt = URL(fileURLWithPath: original["filePath"] as! String), before = try Data(contentsOf: prompt)
        XCTAssertEqual(try engine.sync().added, 1)
        XCTAssertEqual(try tasks(target).count, 2)
        let imported = try XCTUnwrap(tasks(target).first { $0["id"] as? String == "daily-review" })
        XCTAssertEqual(imported["enabled"] as? Bool, true)
        XCTAssertEqual(imported["notifySessionId"] as? String, "local_" + sid)
        XCTAssertEqual(imported["lastScheduledFor"] as? String, original["lastScheduledFor"] as? String)
        XCTAssertEqual(imported["permissionMode"] as? String, "default")
        XCTAssertNil(imported["approvedPermissions"])
        XCTAssertEqual(try tasks(target).first { $0["id"] as? String == "paused" }?["enabled"] as? Bool, false)
        XCTAssertEqual(try readJSON(target.appendingPathComponent(file.lastPathComponent))["scheduledTaskId"] as? String, "daily-review")
        let manifest = try Data(contentsOf: target.appendingPathComponent("scheduled-tasks.json"))
        _ = try engine.sync()
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("scheduled-tasks.json")), manifest)
        XCTAssertEqual(try Data(contentsOf: prompt), before)
    }
    func testTaskRealAccountSwitchRoundTripCarriesEditsAndLatestSlot() throws {
        let first = try owner("Claude", a), second = try owner("Claude", b)
        try selectOfficial(a); _ = try engine.saveAccount(name: "A")
        let aid = try XCTUnwrap(engine.accounts().first?["id"] as? String)
        try selectOfficial(b); _ = try engine.saveAccount(name: "B")
        let bid = try XCTUnwrap(engine.accounts().first { $0["account"] as? String == b }?["id"] as? String)
        _ = try taskFixture(first)
        _ = try engine.switchProfile(id: aid)
        _ = try engine.switchProfile(id: bid)
        try editTask(second) { $0["enabled"] = false; $0["lastRunAt"] = "2026-11-02T09:01:00Z"; $0["lastScheduledFor"] = "2026-11-02T09:00:00Z" }
        _ = try engine.switchProfile(id: aid)
        XCTAssertEqual(try tasks(first).count, 1)
        XCTAssertEqual(try tasks(first)[0]["enabled"] as? Bool, false)
        XCTAssertEqual(try tasks(first)[0]["lastScheduledFor"] as? String, "2026-11-02T09:00:00Z")
        XCTAssertNotNil(try tasks(first)[0]["approvedPermissions"])
        _ = try engine.switchProfile(id: bid)
        XCTAssertEqual(try tasks(second).count, 1)
        XCTAssertEqual(try tasks(second)[0]["enabled"] as? Bool, false)
    }
    func testConcurrentTaskEditsRollbackAllSessionAndTaskWrites() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        try editTask(source) { $0["cronExpression"] = "0 8 * * *" }
        try editTask(target) { $0["cronExpression"] = "0 7 * * *" }
        _ = try fixture(source)
        let before = try digestTree(target), ledger = try Data(contentsOf: engine.scheduleLedger)
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try digestTree(target), before)
        XCTAssertEqual(try Data(contentsOf: engine.scheduleLedger), ledger)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
        XCTAssertTrue(process.running)
    }
    func testPreviouslyUnseenSameIDAndSameNameConflictsAreNotOverwritten() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b)
        _ = try taskFixture(source)
        _ = try taskFixture(target, changes: ["cronExpression": "0 8 * * *"])
        let before = try digestTree(target)
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try digestTree(target), before)
        try emptySchedule(target)
        _ = try taskFixture(target, id: "other", changes: ["displayName": "Daily Review"])
        XCTAssertThrowsError(try engine.sync())
    }
    func testNativeTaskRemovalPropagatesButMissingManifestDoesNot() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        try fm.removeItem(at: target.appendingPathComponent("scheduled-tasks.json"))
        _ = try engine.sync()
        XCTAssertEqual(try tasks(target).count, 1)
        try emptySchedule(target)
        _ = try engine.sync()
        XCTAssertTrue(try tasks(source).isEmpty)
        XCTAssertTrue(try tasks(target).isEmpty)
        _ = try engine.sync()
        XCTAssertTrue(try tasks(target).isEmpty)
        XCTAssertTrue(exists(root.appendingPathComponent(".claude/scheduled-tasks/daily-review/SKILL.md")))
    }
    func testTaskDeletionConflictingWithAnotherEditDoesNotEraseEdit() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        try emptySchedule(target)
        try editTask(source) { $0["enabled"] = false }
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try tasks(source)[0]["enabled"] as? Bool, false)
    }
    func testMissingPromptAndUnsupportedRemoteTasksFailAtomically() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try fixture(source)
        let task = try taskFixture(source)
        try fm.removeItem(atPath: task["filePath"] as! String)
        XCTAssertThrowsError(try engine.sync())
        XCTAssertFalse(exists(target.appendingPathComponent("local_\(sid).json")))
        try emptySchedule(source); _ = try taskFixture(source, changes: ["place": ["kind": "ssh"]])
        XCTAssertThrowsError(try engine.sync())
        XCTAssertTrue(try tasks(target).isEmpty)
    }
    func testPromptSymlinkAndUnknownTaskFieldAreRejected() throws {
        let source = try owner("Claude", a); _ = try owner("Claude", b)
        try selectOfficial(b); let task = try taskFixture(source)
        let prompt = URL(fileURLWithPath: task["filePath"] as! String)
        let elsewhere = root.appendingPathComponent("external.txt")
        try fm.moveItem(at: prompt, to: elsewhere); try fm.createSymbolicLink(at: prompt, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try engine.sync())
        try fm.removeItem(at: prompt); try fm.moveItem(at: elsewhere, to: prompt)
        try editTask(source) { $0["futureAuthorization"] = "must-not-copy" }
        XCTAssertThrowsError(try engine.sync())
    }
    func testPendingRetryAndUnclearTargetBlockTaskSwitch() throws {
        let source = try owner("Claude", a)
        _ = try taskFixture(source)
        XCTAssertThrowsError(try engine.switchProfile(id: "official"))
        XCTAssertEqual(try engine.mode(), "3p")
        _ = try owner("Claude", b); try selectOfficial(b)
        let file = source.appendingPathComponent("scheduled-tasks.json")
        var document = try readJSON(file); document["runRetries"] = ["daily-review": ["slot": "2026-11-01T09:00:00Z", "attempts": 1]]
        try atomicJSON(document, file)
        XCTAssertThrowsError(try engine.sync())
    }
    func testSkipHistoryIsUnionedAndStaleRunTimesDoNotWin() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        try editTask(source) { $0["lastScheduledFor"] = "2026-11-02T09:00:00Z" }
        for (directory, time) in [(source, 1000), (target, 2000)] {
            let file = directory.appendingPathComponent("scheduled-tasks.json")
            var d = try readJSON(file); d["recordedSkips"] = ["daily-review": [["at": time, "reason": "global_limit"]]]
            try atomicJSON(d, file)
        }
        _ = try engine.sync()
        XCTAssertEqual(try tasks(target)[0]["lastScheduledFor"] as? String, "2026-11-02T09:00:00Z")
        let skips = try readJSON(target.appendingPathComponent("scheduled-tasks.json"))["recordedSkips"] as? [String: [[String: Any]]]
        XCTAssertEqual(skips?["daily-review"]?.count, 2)
        _ = try engine.sync()
        XCTAssertEqual(try tasks(target).count, 1)
    }
    func testGatewayModelMismatchRollsBackAccountSwitch() throws {
        let source = try owner("Claude", a); _ = try owner("Claude-3p", b)
        try selectOfficial(a)
        try atomicJSON(["lastKnownAccountUuid": b], engine.third.appendingPathComponent("config.json"))
        let file = engine.library.appendingPathComponent(gateway + ".json")
        var config = try readJSON(file); config["inferenceModels"] = [["name": "claude-sonnet-4-5"]]; try atomicJSON(config, file)
        _ = try taskFixture(source, changes: ["model": "claude-opus-4-5"])
        XCTAssertThrowsError(try engine.switchProfile(id: gateway))
        XCTAssertEqual(try engine.mode(), "1p")
    }
    func testPreexistingSessionImportGetsMissingTaskAssociationOnly() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try scheduledRun(source); let existing = try fixture(target)
        var value = try readJSON(existing); value["title"] = "Keep local title"; try atomicJSON(value, existing)
        _ = try taskFixture(source); _ = try engine.sync()
        XCTAssertEqual(try readJSON(existing)["scheduledTaskId"] as? String, "daily-review")
        XCTAssertEqual(try readJSON(existing)["title"] as? String, "Keep local title")
    }
    func testTaskTransactionCrashRecoveryRestoresManifestAndLedger() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source)
        process.running = false
        let tx = try Transaction(root: engine.state, operation: "crash fixture")
        _ = try engine.synchronizeTasks(from: engine.syncTargets(), into: engine.syncTargets(), transaction: tx)
        XCTAssertEqual(try tasks(target).count, 1)
        try Transaction.recover(root: engine.state)
        XCTAssertTrue(try tasks(target).isEmpty)
        XCTAssertFalse(exists(engine.scheduleLedger))
        _ = try engine.sync(); XCTAssertEqual(try tasks(target).count, 1)
    }
    func testGatewayChecksModelFromPromptFrontmatter() throws {
        let source = try owner("Claude", a); _ = try owner("Claude-3p", b)
        try selectOfficial(a); try atomicJSON(["lastKnownAccountUuid": b], engine.third.appendingPathComponent("config.json"))
        let configFile = engine.library.appendingPathComponent(gateway + ".json")
        var config = try readJSON(configFile); config["inferenceModels"] = ["claude-sonnet-4-5"]; try atomicJSON(config, configFile)
        let task = try taskFixture(source), prompt = URL(fileURLWithPath: task["filePath"] as! String)
        try atomicData(Data("---\nname: daily-review\ndescription: Review\nmodel: \"claude-opus-4-5\"\n---\n\nReview.\n".utf8), prompt)
        XCTAssertThrowsError(try engine.switchProfile(id: gateway))
        XCTAssertEqual(try engine.mode(), "1p")
    }
    func testInvalidPromptIsNotImportedAsRunnableTask() throws {
        let source = try owner("Claude", a); _ = try owner("Claude", b)
        try selectOfficial(b); let task = try taskFixture(source)
        try atomicData(Data("not a native task prompt".utf8), URL(fileURLWithPath: task["filePath"] as! String))
        XCTAssertThrowsError(try engine.sync())
    }
    func testOverdueOneShotNeedsResolutionButPausedAndFutureTasksKeepState() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source)
        try editTask(source) { $0.removeValue(forKey: "cronExpression"); $0["fireAt"] = 1000; $0.removeValue(forKey: "lastRunAt"); $0.removeValue(forKey: "lastScheduledFor") }
        XCTAssertThrowsError(try engine.sync())
        try editTask(source) { $0["enabled"] = false }
        _ = try engine.sync()
        XCTAssertEqual(try tasks(target)[0]["enabled"] as? Bool, false)
        _ = try taskFixture(source, id: "future-task")
        let future = (Date().addingTimeInterval(86400).timeIntervalSince1970 * 1000).rounded()
        try editTask(source, id: "future-task") { $0.removeValue(forKey: "cronExpression"); $0["fireAt"] = future }
        _ = try engine.sync()
        XCTAssertEqual(try tasks(target).first { $0["id"] as? String == "future-task" }?["fireAt"] as? Double, future)
        _ = try engine.sync(); XCTAssertEqual(try tasks(target).count, 2)
    }
}
