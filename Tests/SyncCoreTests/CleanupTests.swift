import XCTest
@testable import SyncCore

extension CoreTests {
    func prepareCleanup() throws -> URL {
        try selectOfficial(b)
        try atomicJSON(["lastKnownAccountUuid": a], engine.third.appendingPathComponent("config.json"))
        return try owner("Claude", a)
    }
    func emptySchedule(_ directory: URL) throws {
        try atomicJSON(["scheduledTasks": [], "recordedSkips": [:], "sundayAliasBoundaryStamped": true, "dayFieldsOrBoundaryStamped": true], directory.appendingPathComponent("scheduled-tasks.json"))
    }
    func cleanupPreview(_ directory: URL) throws -> AccountRecordInfo {
        try XCTUnwrap(engine.accountRecords().first { $0.account == directory.deletingLastPathComponent().lastPathComponent && $0.organization == directory.lastPathComponent && $0.profile == directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent })
    }
    func testCleanupEmptyScopesAndRestoreExactContent() throws {
        let first = try prepareCleanup(), second = first.deletingLastPathComponent().appendingPathComponent(gateway)
        try privateDir(second); try emptySchedule(first); try emptySchedule(second)
        let before = try digestTree(first), previews = try engine.accountRecords()
        XCTAssertTrue(previews.allSatisfy { $0.empty && $0.canClean && $0.bytes > 0 })
        XCTAssertEqual(try engine.cleanAccountRecords(previews).added, 2)
        XCTAssertFalse(exists(first.deletingLastPathComponent()))
        XCTAssertEqual(try engine.status().ownerCount, 0)
        let removed = try engine.removedAccountRecords()
        XCTAssertEqual(removed.count, 2)
        let item = try XCTUnwrap(removed.first { $0.organization == org })
        XCTAssertEqual(try engine.restoreAccountRecords(id: item.id).added, 1)
        XCTAssertEqual(try digestTree(first), before)
        XCTAssertFalse(exists(second))
        XCTAssertEqual(try engine.removedAccountRecords().count, 1)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }
    func testCleanupRetainsUniqueHistoryAndSharedTranscript() throws {
        let directory = try prepareCleanup(), file = try fixture(directory)
        let bytes = try Data(contentsOf: file)
        let transcript = root.appendingPathComponent(".claude/projects/-fixture/\(sid).jsonl"), body = try Data(contentsOf: transcript)
        let preview = try cleanupPreview(directory)
        XCTAssertEqual(preview.uniqueSessionCount, 1)
        XCTAssertFalse(preview.empty)
        _ = try engine.cleanAccountRecords([preview])
        XCTAssertFalse(exists(directory))
        XCTAssertEqual(try Data(contentsOf: transcript), body)
        XCTAssertEqual(try engine.history.catalog().map(\.id), ["local_" + sid])
        let deleted = try XCTUnwrap(engine.removedAccountRecords().first)
        _ = try engine.restoreAccountRecords(id: deleted.id)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testCleanupProtectsBothRetainedIdentitiesAndUnknownIdentity() throws {
        _ = try prepareCleanup()
        let official = try owner("Claude", b), api = try owner("Claude-3p", a)
        for directory in [official, api] {
            let preview = try cleanupPreview(directory)
            XCTAssertFalse(preview.canClean)
            XCTAssertThrowsError(try engine.cleanAccountRecords([preview]))
            XCTAssertTrue(exists(directory))
        }
        try fm.removeItem(at: engine.first.appendingPathComponent("config.json"))
        XCTAssertFalse(try cleanupPreview(official).canClean)
    }
    func testCleanupRechecksIdentityAndReviewedDirectory() throws {
        let directory = try prepareCleanup(), preview = try cleanupPreview(directory)
        try emptySchedule(directory)
        XCTAssertThrowsError(try engine.cleanAccountRecords([preview]))
        XCTAssertTrue(exists(directory))
        let updated = try cleanupPreview(directory)
        try login(a, token: "changed-current-account")
        XCTAssertThrowsError(try engine.cleanAccountRecords([updated]))
        XCTAssertTrue(exists(directory))
        XCTAssertTrue(try engine.removedAccountRecords().isEmpty)
    }
    func testCleanupBatchDoesNotPartiallyRemoveChangedSelection() throws {
        let directory = try prepareCleanup(), second = try owner("Claude", gateway)
        let previews = try engine.accountRecords()
        try emptySchedule(second)
        XCTAssertThrowsError(try engine.cleanAccountRecords(previews))
        XCTAssertTrue(exists(directory)); XCTAssertTrue(exists(second))
        XCTAssertTrue(try engine.removedAccountRecords().isEmpty)
    }
    func testCleanupProtectsSchedulesRemoteSessionsAndUnknownScheduleFormat() throws {
        let directory = try prepareCleanup(), schedule = directory.appendingPathComponent("scheduled-tasks.json")
        try atomicJSON(["scheduledTasks": [["id": "job"]], "recordedSkips": [:]], schedule)
        XCTAssertFalse(try cleanupPreview(directory).canClean)
        try atomicJSON(["futureFormat": true], schedule)
        XCTAssertFalse(try cleanupPreview(directory).canClean)
        try emptySchedule(directory)
        let file = try fixture(directory)
        var record = try readJSON(file); record["sshHost"] = "example.invalid"
        try atomicJSON(record, file)
        XCTAssertFalse(try cleanupPreview(directory).canClean)
    }
    func testCleanupRestorationRejectsConflictsAndTampering() throws {
        let directory = try prepareCleanup(); try emptySchedule(directory)
        _ = try engine.cleanAccountRecords([cleanupPreview(directory)])
        let item = try XCTUnwrap(engine.removedAccountRecords().first)
        try privateDir(directory)
        let file = directory.appendingPathComponent("new.json"); try atomicJSON(["new": true], file)
        XCTAssertThrowsError(try engine.restoreAccountRecords(id: item.id))
        XCTAssertEqual(try readJSON(file)["new"] as? Bool, true)
        try fm.removeItem(at: directory)
        let backup = engine.state.appendingPathComponent("removed-records/\(item.id)/content")
        try atomicJSON(["tampered": true], backup.appendingPathComponent("scheduled-tasks.json"))
        XCTAssertThrowsError(try engine.restoreAccountRecords(id: item.id))
        XCTAssertFalse(exists(directory))
        XCTAssertEqual(try engine.removedAccountRecords().count, 1)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }
    func testMissingEmptyBackupCannotRestoreAsSuccessfulNoOp() throws {
        let directory = try prepareCleanup()
        _ = try engine.cleanAccountRecords([cleanupPreview(directory)])
        let item = try XCTUnwrap(engine.removedAccountRecords().first)
        try fm.removeItem(at: engine.state.appendingPathComponent("removed-records/\(item.id)/content"))
        XCTAssertThrowsError(try engine.restoreAccountRecords(id: item.id))
        XCTAssertFalse(exists(directory))
    }
    func testCleanupRequiresWorkerConsentAndRejectsUnsafeRestoreIdentity() throws {
        let directory = try prepareCleanup(), preview = try cleanupPreview(directory)
        process.workers = 1
        XCTAssertThrowsError(try engine.cleanAccountRecords([preview]))
        XCTAssertTrue(exists(directory))
        _ = try engine.cleanAccountRecords([preview], allowOpenSessions: true)
        var entries = try engine.cleanupEntries()
        let entry = entries.removeFirst()
        let unsafe = RemovedAccountRecord(id: entry.id, profile: "../outside", account: a, organization: org, sessionCount: 0, bytes: 0, cleanedAt: 0, digest: entry.digest)
        try atomicData(JSONEncoder().encode([unsafe]), engine.cleanupIndex)
        XCTAssertThrowsError(try engine.restoreAccountRecords(id: entry.id))
        XCTAssertFalse(exists(directory))
    }
    func testInterruptedCleanupRestoresDirectoryAndIndexTogether() throws {
        let directory = try prepareCleanup(); try emptySchedule(directory)
        let before = try digestTree(directory)
        let tx = try Transaction(root: engine.state, operation: "interrupted cleanup fixture")
        try tx.replace(directory, with: nil)
        try tx.write([], to: engine.cleanupIndex)
        try Transaction.recover(root: engine.state)
        XCTAssertEqual(try digestTree(directory), before)
        XCTAssertFalse(exists(engine.cleanupIndex))
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }
}
