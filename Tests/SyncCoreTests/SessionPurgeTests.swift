import XCTest
@testable import SyncCore

extension CoreTests {
    var deletedID: String { "local_" + sid }
    var bodyFile: URL { root.appendingPathComponent(".claude/projects/-fixture/\(sid).jsonl") }

    func deletedFixture() throws -> URL {
        let source = try owner("Claude", a)
        let file = try fixture(source)
        _ = try engine.archive()
        _ = try deletionMarker(source)
        return file
    }

    func testSessionPurgePreviewExplainsArchiveOnlyRecordWithoutChanges() throws {
        let file = try deletedFixture()
        try fm.removeItem(at: file); try fm.removeItem(at: bodyFile)
        let before = try digestTree(root)
        let rows = try engine.deletedSessionRecords(), preview = try engine.previewSessionPurge(ids: [deletedID])
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].title, "A session")
        XCTAssertEqual(rows[0].nativeCopies, 0); XCTAssertEqual(rows[0].archiveVersions, 1)
        XCTAssertEqual(rows[0].transcriptCopies, 1)
        XCTAssertEqual(preview.files.count, 2); XCTAssertGreaterThan(preview.bytes, 0)
        XCTAssertEqual(try digestTree(root), before); XCTAssertEqual(process.stops, 0)
        _ = try engine.purgeDeletedSessions(preview)
        XCTAssertTrue(try engine.deletedSessionRecords().isEmpty)
        XCTAssertTrue(try engine.history.catalog().isEmpty)
        XCTAssertNotNil(try engine.history.deletedSessions()[deletedID])
    }

    func testSessionPurgeDeletesBodiesAttachmentsArchiveAndAllOperationCopies() throws {
        let first = try owner("Claude", a), third = try owner("Claude-3p", b)
        _ = try fixture(first); _ = try fixture(third)
        let other = try fixture(first, id: gateway), otherBytes = try Data(contentsOf: other)
        let sidecar = root.appendingPathComponent(".claude/projects/-fixture/\(sid)/subagents/agent-test.jsonl")
        try atomicData(Data("private sidecar".utf8), sidecar)
        _ = try engine.archive(); _ = try deletionMarker(first); _ = try engine.sync()
        let otherBody = root.appendingPathComponent(".claude/projects/-fixture/\(gateway).jsonl")
        let otherBodyBytes = try Data(contentsOf: otherBody)
        let backups = try fm.contentsOfDirectory(atPath: engine.state.appendingPathComponent("backups").path)
        let preview = try engine.previewSessionPurge(ids: [deletedID])
        XCTAssertTrue(preview.files.contains { $0.category == "操作备份" })
        XCTAssertTrue(preview.files.contains { $0.path == sidecar.path })
        _ = try engine.purgeDeletedSessions(preview)
        XCTAssertTrue(preview.files.allSatisfy { !exists(URL(fileURLWithPath: $0.path)) })
        XCTAssertFalse(exists(bodyFile)); XCTAssertFalse(exists(sidecar))
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
        XCTAssertEqual(try Data(contentsOf: otherBody), otherBodyBytes)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: engine.state.appendingPathComponent("backups").path), backups)
        XCTAssertNil(try readJSON(engine.history.vault.appendingPathComponent("index.json"))[deletedID])
        _ = try engine.sync()
        XCTAssertFalse(exists(first.appendingPathComponent(deletedID + ".json")))
        XCTAssertFalse(exists(engine.pendingSessionPurge))
    }

    func testSessionPurgeSelectivelyPrunesRecoveryCopiesAndKeepsOtherRecordsRestorable() throws {
        let directory = try prepareCleanup()
        _ = try fixture(directory); _ = try fixture(directory, id: gateway)
        _ = try engine.cleanAccountRecords([cleanupPreview(directory)])
        let entry = try XCTUnwrap(engine.cleanupEntries().first)
        let active = try owner("Claude-3p", b); _ = try deletionMarker(active)
        let preview = try engine.previewSessionPurge(ids: [deletedID])
        XCTAssertTrue(preview.files.contains { $0.category == "账户恢复副本" })
        _ = try engine.purgeDeletedSessions(preview)
        let updated = try XCTUnwrap(engine.cleanupEntries().first)
        XCTAssertEqual(updated.id, entry.id); XCTAssertEqual(updated.sessionCount, 1)
        XCTAssertEqual(try digestTree(engine.state.appendingPathComponent("removed-records/\(entry.id)/content")), updated.digest)
        _ = try engine.restoreAccountRecords(id: entry.id)
        XCTAssertTrue(exists(directory.appendingPathComponent("local_\(gateway).json")))
        XCTAssertFalse(exists(directory.appendingPathComponent(deletedID + ".json")))
    }

    func testSessionPurgeProtectsTranscriptsReferencedByAnyOtherSession() throws {
        _ = try deletedFixture()
        let otherDir = try owner("Claude-3p", b), other = try fixture(otherDir, id: gateway)
        var d = try readJSON(other); d["priorCliSessionIds"] = [sid]; try atomicJSON(d, other)
        XCTAssertThrowsError(try engine.previewSessionPurge(ids: [deletedID]))
        _ = try engine.archive(); try fm.removeItem(at: other)
        // An archived-only reference is equally important.
        XCTAssertThrowsError(try engine.previewSessionPurge(ids: [deletedID]))
        _ = try deletionMarker(otherDir, id: gateway)
        let preview = try engine.previewSessionPurge(ids: [deletedID, "local_" + gateway])
        _ = try engine.purgeDeletedSessions(preview)
        XCTAssertFalse(exists(bodyFile))
    }

    func testSessionPurgeRejectsChangedPreviewActiveWorkersAndUnknownDesktop() throws {
        _ = try deletedFixture()
        let preview = try engine.previewSessionPurge(ids: [deletedID])
        process.workers = 1
        XCTAssertThrowsError(try engine.purgeDeletedSessions(preview))
        XCTAssertTrue(exists(bodyFile)); process.workers = 0
        try atomicData(Data("changed body\n".utf8), bodyFile)
        XCTAssertThrowsError(try engine.purgeDeletedSessions(preview))
        XCTAssertTrue(exists(bodyFile)); XCTAssertFalse(exists(engine.pendingSessionPurge))
        let unknown = Engine(home: root, process: process, version: "99.0.0")
        XCTAssertThrowsError(try unknown.previewSessionPurge(ids: [deletedID]))
        XCTAssertThrowsError(try engine.previewSessionPurge(ids: ["local_" + gateway]))
    }

    func testSessionPurgeInterruptionResumesWithoutBackupOrResurrection() throws {
        let directory = try prepareCleanup()
        _ = try fixture(directory); _ = try fixture(directory, id: gateway)
        _ = try engine.cleanAccountRecords([cleanupPreview(directory)])
        _ = try deletionMarker(owner("Claude-3p", b))
        let (plan, _, files) = try engine.buildSessionPurge(ids: [deletedID])
        _ = try engine.history.rememberDeletions()
        try atomicData(JSONEncoder().encode(plan), engine.pendingSessionPurge)
        process.running = false
        var n = 0
        XCTAssertThrowsError(try engine.executeSessionPurge(plan, beforeAction: {
            n += 1; if n == plan.actions.count { throw SyncError("fixture interruption before last index") }
        }))
        XCTAssertTrue(files.allSatisfy { !exists(URL(fileURLWithPath: $0.path)) })
        XCTAssertTrue(try engine.status().pendingPurge)
        XCTAssertThrowsError(try engine.archive())
        XCTAssertThrowsError(try engine.previewRecordPurge(ids: []))
        _ = try engine.resumeRecordPurge()
        XCTAssertFalse(exists(engine.pendingSessionPurge))
        XCTAssertTrue(try engine.deletedSessionRecords().isEmpty)
        let entry = try XCTUnwrap(engine.cleanupEntries().first)
        _ = try engine.restoreAccountRecords(id: entry.id)
        XCTAssertTrue(exists(directory.appendingPathComponent("local_\(gateway).json")))
    }

    func testSessionPurgeResumeRejectsNewFilesReferencesAndOutOfScopeActions() throws {
        _ = try deletedFixture()
        let (plan, _, _) = try engine.buildSessionPurge(ids: [deletedID])
        _ = try engine.history.rememberDeletions()
        try atomicData(JSONEncoder().encode(plan), engine.pendingSessionPurge)
        let other = try fixture(owner("Claude-3p", b), id: gateway)
        var value = try readJSON(other); value["priorCliSessionIds"] = [sid]; try atomicJSON(value, other)
        process.running = false
        XCTAssertThrowsError(try engine.resumeSessionPurge())
        XCTAssertTrue(exists(bodyFile))
        value.removeValue(forKey: "priorCliSessionIds"); try atomicJSON(value, other)
        let extra = root.appendingPathComponent(".claude/projects/-fixture/\(sid)/new.txt")
        try atomicData(Data("new".utf8), extra)
        XCTAssertThrowsError(try engine.resumeSessionPurge()); XCTAssertTrue(exists(bodyFile))
        let malicious = SessionPurgePlan(ids: plan.ids, cliIDs: plan.cliIDs, actions: [PurgeAction(path: engine.registry.path, kind: "file", digest: String(repeating: "0", count: 64), replacement: nil, bytes: 0)])
        XCTAssertThrowsError(try engine.validateSessionPurgePlan(malicious))
    }

    func testSessionPurgeRejectsSymlinkAndCorruptArchiveWithoutDeletingAnything() throws {
        _ = try deletedFixture()
        let outside = root.appendingPathComponent("outside.txt")
        try atomicData(Data("preserve".utf8), outside)
        let linked = root.appendingPathComponent(".claude/projects/-fixture/\(sid)")
        try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
        XCTAssertThrowsError(try engine.previewSessionPurge(ids: [deletedID]))
        try fm.removeItem(at: linked)
        let archive = try XCTUnwrap(treeFiles(engine.history.vault.appendingPathComponent("records/" + deletedID)).first)
        var value = try readJSON(archive); value["title"] = "tampered"; try atomicJSON(value, archive)
        XCTAssertThrowsError(try engine.previewSessionPurge(ids: [deletedID]))
        XCTAssertEqual(try String(contentsOf: outside), "preserve")
        XCTAssertTrue(exists(bodyFile)); XCTAssertEqual(process.stops, 0)
    }
}
