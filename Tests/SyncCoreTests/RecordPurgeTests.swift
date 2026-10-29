import XCTest
@testable import SyncCore

extension CoreTests {
    func recoverableFixture(withSession: Bool = false) throws -> (URL, RemovedAccountRecord) {
        let directory = try prepareCleanup()
        if withSession { _ = try fixture(directory) } else { try emptySchedule(directory) }
        _ = try engine.cleanAccountRecords([cleanupPreview(directory)])
        return (directory, try XCTUnwrap(engine.removedAccountRecords().first))
    }

    func testPurgeEmptyCopiesIncludesRestoredVersionsAndPreservesOtherScope() throws {
        let first = try prepareCleanup(), second = first.deletingLastPathComponent().appendingPathComponent(gateway)
        try privateDir(second); try emptySchedule(first); try emptySchedule(second)
        _ = try engine.cleanAccountRecords(engine.accountRecords())
        let original = try XCTUnwrap(engine.removedAccountRecords().first { $0.organization == org })
        let other = try XCTUnwrap(engine.removedAccountRecords().first { $0.organization == gateway })
        _ = try engine.restoreAccountRecords(id: original.id)
        _ = try engine.cleanAccountRecords([cleanupPreview(first)])
        let latest = try XCTUnwrap(engine.removedAccountRecords().first { $0.organization == org })
        let backupFolders = try fm.contentsOfDirectory(atPath: engine.state.appendingPathComponent("backups").path)
        let preview = try engine.previewRecordPurge(ids: [latest.id])
        XCTAssertEqual(preview.recoveryCopyCount, 2)
        XCTAssertTrue(preview.emptyOnly)
        XCTAssertGreaterThan(preview.fileCount, 2)
        XCTAssertEqual(preview.fingerprint, try engine.previewRecordPurge(ids: [latest.id]).fingerprint)
        let stops = process.stops
        _ = try engine.purgeRecords(preview)
        XCTAssertEqual(process.stops, stops)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("removed-records/\(original.id)")))
        XCTAssertFalse(exists(engine.state.appendingPathComponent("removed-records/\(latest.id)")))
        XCTAssertEqual(try engine.cleanupEntries().map(\.id), [other.id])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: engine.state.appendingPathComponent("backups").path).sorted(), backupFolders.sorted())
        for file in try treeFiles(engine.state.appendingPathComponent("backups")) where file.pathExtension == "json" || ["before", "displaced"].contains(file.pathExtension) {
            if let array = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] {
                XCTAssertFalse(array.contains { $0["organization"] as? String == org })
            }
        }
        _ = try engine.restoreAccountRecords(id: other.id)
        XCTAssertTrue(exists(second.appendingPathComponent("scheduled-tasks.json")))
        XCTAssertFalse(exists(engine.pendingPurge))
    }

    func testPurgePayloadsKeepsSharedTranscriptAndArchive() throws {
        let (_, entry) = try recoverableFixture(withSession: true)
        let shared = root.appendingPathComponent(".claude"), archive = engine.history.vault
        let before = try [shared, archive].map { try digestTree($0) }
        let preview = try engine.previewRecordPurge(ids: [entry.id])
        XCTAssertFalse(preview.emptyOnly)
        _ = try engine.purgeRecords(preview)
        XCTAssertEqual(try [shared, archive].map { try digestTree($0) }, before)
        XCTAssertTrue(try engine.cleanupEntries().isEmpty)
        XCTAssertTrue(try engine.removedAccountRecords().isEmpty)
        XCTAssertThrowsError(try engine.restoreAccountRecords(id: entry.id))
        XCTAssertFalse(try treeFiles(engine.state.appendingPathComponent("backups")).contains { $0.lastPathComponent == "local_\(sid).json" })
    }

    func testDeleteEmptyDirectoryCreatesNoRecoveryPayloadOrTransactionBackup() throws {
        let directory = try prepareCleanup(); try emptySchedule(directory)
        let preview = try engine.previewEmptyRecordDeletion([cleanupPreview(directory)])
        XCTAssertTrue(preview.deletesLiveDirectories)
        XCTAssertTrue(preview.emptyOnly)
        XCTAssertEqual(preview.recoveryCopyCount, 0)
        _ = try engine.purgeRecords(preview)
        XCTAssertFalse(exists(directory))
        XCTAssertFalse(exists(directory.deletingLastPathComponent()))
        XCTAssertFalse(exists(engine.state.appendingPathComponent("backups")))
        XCTAssertFalse(exists(engine.cleanupIndex))
        XCTAssertFalse(exists(engine.pendingPurge))
        XCTAssertEqual(process.stops, 1)
        XCTAssertEqual(process.starts, 1)
    }

    func testDirectEmptyDeletionRejectsActiveUnknownAndNonemptyDirectories() throws {
        let directory = try prepareCleanup()
        let empty = try cleanupPreview(directory)
        _ = try fixture(directory)
        XCTAssertThrowsError(try engine.previewEmptyRecordDeletion([empty]))
        XCTAssertThrowsError(try engine.previewEmptyRecordDeletion([cleanupPreview(directory)]))
        let active = try owner("Claude", b)
        XCTAssertThrowsError(try engine.previewEmptyRecordDeletion([cleanupPreview(active)]))
        XCTAssertTrue(exists(directory))
        XCTAssertEqual(process.stops, 0)
    }

    func testPurgeRejectsChangedPreviewBeforeDeletingAnything() throws {
        let (_, entry) = try recoverableFixture()
        let preview = try engine.previewRecordPurge(ids: [entry.id])
        let plan = try engine.buildPurgePlan(ids: [entry.id], live: [])
        let payload = try XCTUnwrap(plan.actions.first { $0.kind == "file" && $0.path.contains("/backups/") })
        try atomicData(Data("changed legacy copy".utf8), URL(fileURLWithPath: payload.path))
        XCTAssertThrowsError(try engine.purgeRecords(preview))
        XCTAssertTrue(exists(engine.state.appendingPathComponent("removed-records/\(entry.id)/content")))
        XCTAssertFalse(exists(engine.pendingPurge))
    }

    func testInterruptedPurgeResumesWithoutRestoringDeletedFiles() throws {
        let (_, entry) = try recoverableFixture()
        let plan = try engine.buildPurgePlan(ids: [entry.id], live: [])
        try atomicData(JSONEncoder().encode(plan), engine.pendingPurge)
        var actions = 0
        XCTAssertThrowsError(try engine.executePurgePlan(plan, beforeAction: {
            actions += 1
            if actions == plan.actions.count { throw SyncError("simulated interruption before final index") }
        }))
        XCTAssertTrue(exists(engine.pendingPurge))
        XCTAssertTrue(try engine.status().pendingPurge)
        XCTAssertThrowsError(try engine.archive())
        XCTAssertThrowsError(try engine.setProfileAlias(id: gateway, kind: "gateway", alias: "Blocked"))
        XCTAssertTrue(plan.actions.filter { $0.kind == "file" }.allSatisfy { !exists(URL(fileURLWithPath: $0.path)) })
        let stops = process.stops
        _ = try engine.resumeRecordPurge()
        XCTAssertEqual(process.stops, stops)
        XCTAssertFalse(exists(engine.pendingPurge))
        XCTAssertTrue(try engine.cleanupEntries().isEmpty)
    }

    func testPurgeResumeRejectsNewContentAndOutOfScopePlan() throws {
        let (_, entry) = try recoverableFixture()
        let plan = try engine.buildPurgePlan(ids: [entry.id], live: [])
        try atomicData(JSONEncoder().encode(plan), engine.pendingPurge)
        let file = try XCTUnwrap(plan.actions.first { $0.kind == "file" })
        try atomicData(Data("new data".utf8), URL(fileURLWithPath: file.path))
        XCTAssertThrowsError(try engine.resumeRecordPurge())
        XCTAssertEqual(try String(contentsOfFile: file.path), "new data")
        var unsafe = plan
        unsafe.actions = [PurgeAction(path: engine.registry.path, kind: "file", digest: sha(Data()), replacement: nil, bytes: 0)]
        try atomicData(JSONEncoder().encode(unsafe), engine.pendingPurge)
        XCTAssertThrowsError(try engine.resumeRecordPurge())
    }

    func testPurgeDoesNotTouchRecreatedOriginalOrUnknownBackupFiles() throws {
        let (directory, entry) = try recoverableFixture()
        try privateDir(directory)
        let newFile = directory.appendingPathComponent("new-session.txt")
        try atomicData(Data("keep recreated directory".utf8), newFile)
        let backup = engine.state.appendingPathComponent("backups/123-11111111-1111-4111-8111-111111111111")
        try privateDir(backup)
        let unrelated = backup.appendingPathComponent("notes.txt")
        try atomicData(Data("keep unrelated".utf8), unrelated)
        let preview = try engine.previewRecordPurge(ids: [entry.id])
        _ = try engine.purgeRecords(preview)
        XCTAssertEqual(try String(contentsOf: newFile), "keep recreated directory")
        XCTAssertEqual(try String(contentsOf: unrelated), "keep unrelated")
    }

    func testPurgeEmptyClassificationIncludesUnknownExtraFilesAndOldPayloads() throws {
        let (_, entry) = try recoverableFixture()
        let extra = engine.state.appendingPathComponent("removed-records/\(entry.id)/notes.txt")
        try atomicData(Data("not empty".utf8), extra)
        XCTAssertFalse(try engine.previewRecordPurge(ids: [entry.id]).emptyOnly)
        try fm.removeItem(at: extra)
        let plan = try engine.buildPurgePlan(ids: [entry.id], live: [])
        let payload = try XCTUnwrap(plan.actions.first { $0.kind == "file" && $0.path.contains("/backups/") })
        try atomicJSON(["scheduledTasks": [["id": "legacy task"]], "recordedSkips": [:]], URL(fileURLWithPath: payload.path))
        XCTAssertFalse(try engine.previewRecordPurge(ids: [entry.id]).emptyOnly)
    }

    func testPurgeRejectsSymbolicLinksAndPendingRollback() throws {
        let (_, entry) = try recoverableFixture()
        let folder = engine.state.appendingPathComponent("removed-records/\(entry.id)")
        let outside = root.appendingPathComponent("untouched.txt")
        try atomicData(Data("untouched".utf8), outside)
        let link = folder.appendingPathComponent("symlink")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try engine.previewRecordPurge(ids: [entry.id]))
        XCTAssertEqual(try String(contentsOf: outside), "untouched")
        try fm.removeItem(at: link)
        try atomicJSON([:], engine.state.appendingPathComponent("pending.json"))
        XCTAssertThrowsError(try engine.previewRecordPurge(ids: [entry.id]))
    }

    func testRestoredBackupCanBePurgedWithoutDeletingRestoredDirectory() throws {
        let (directory, entry) = try recoverableFixture()
        _ = try engine.restoreAccountRecords(id: entry.id)
        XCTAssertTrue(try engine.removedAccountRecords().isEmpty)
        XCTAssertEqual(try engine.restoredAccountBackups().map(\.id), [entry.id])
        let before = try digestTree(directory)
        _ = try engine.purgeRecords(engine.previewRecordPurge(ids: [entry.id]))
        XCTAssertEqual(try digestTree(directory), before)
        XCTAssertTrue(try engine.restoredAccountBackups().isEmpty)
    }

    func testUnknownScheduleFlagIsNotClassifiedAsEmpty() throws {
        let directory = try prepareCleanup()
        try atomicJSON(["scheduledTasks": [], "recordedSkips": [:], "sundayAliasBoundaryStamped": "unknown content"], directory.appendingPathComponent("scheduled-tasks.json"))
        XCTAssertFalse(try cleanupPreview(directory).empty)
        XCTAssertThrowsError(try engine.previewEmptyRecordDeletion([cleanupPreview(directory)]))
    }
}
