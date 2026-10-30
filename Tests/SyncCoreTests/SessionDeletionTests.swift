import XCTest
@testable import SyncCore

extension CoreTests {
    func deletionMarker(_ directory: URL, id: String? = nil) throws -> URL {
        let file = directory.appendingPathComponent("deleted_" + (id ?? sid))
        try atomicData(Data("1793290000000".utf8), file)
        return file
    }

    func testExplicitDeletionHidesAllCopiesAndArchiveWithoutWritingClaude() throws {
        let first = try owner("Claude", a), third = try owner("Claude-3p", b)
        let f = try fixture(first), t = try fixture(third)
        _ = try engine.archive()
        let marker = try deletionMarker(first)
        let hashes = try [f, t, marker].map { try digestTree($0) }
        let status = try engine.status()
        XCTAssertTrue(status.sessions.isEmpty)
        XCTAssertEqual(status.pendingDeletionCopies, 2)
        XCTAssertEqual(try [f, t, marker].map { try digestTree($0) }, hashes)
        XCTAssertEqual(process.stops, 0)
    }

    func testDeletionSyncRemovesEveryCopyButKeepsOtherSessionsAndBodies() throws {
        let first = try owner("Claude", a), third = try owner("Claude-3p", b)
        let f = try fixture(first), t = try fixture(third)
        let other = try fixture(third, id: gateway), otherBytes = try Data(contentsOf: other)
        let transcript = root.appendingPathComponent(".claude/projects/-fixture/\(sid).jsonl")
        let body = try Data(contentsOf: transcript)
        let marker = try deletionMarker(first)
        let markerBytes = try Data(contentsOf: marker)
        let result = try engine.sync()
        XCTAssertTrue(result.message.contains("同步删除 2 份"))
        XCTAssertFalse(exists(f)); XCTAssertFalse(exists(t))
        XCTAssertEqual(try Data(contentsOf: third.appendingPathComponent(marker.lastPathComponent)), markerBytes)
        XCTAssertEqual(try Data(contentsOf: transcript), body)
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
        XCTAssertEqual(try engine.status().pendingDeletionCopies, 0)
        XCTAssertEqual(try engine.history.catalog().map(\.id), ["local_" + gateway])
        XCTAssertTrue(exists(engine.history.vault.appendingPathComponent("records/local_\(sid)")))
        _ = try engine.switchProfile(id: "official")
        _ = try engine.switchProfile(id: gateway)
        XCTAssertFalse(exists(f)); XCTAssertFalse(exists(t))
    }

    func testMissingFileWithoutTombstoneIsNotAUserDeletion() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        let file = try fixture(source)
        _ = try engine.archive()
        try fm.removeItem(at: file)
        XCTAssertEqual(try engine.history.catalog().count, 1)
        XCTAssertTrue(try engine.history.deletedSessions().isEmpty)
        XCTAssertEqual(try engine.sync().added, 1)
        XCTAssertTrue(exists(target.appendingPathComponent(file.lastPathComponent)))
    }

    func testDeletionIntentSurvivesRemovalOfItsSourceAccountDirectory() throws {
        let source = try owner("Claude", a)
        _ = try fixture(source); _ = try deletionMarker(source)
        _ = try engine.archive()
        try fm.removeItem(at: source)
        let target = try owner("Claude-3p", b)
        try atomicJSON(["lastKnownAccountUuid": b], engine.third.appendingPathComponent("config.json"))
        XCTAssertTrue(try engine.history.catalog().isEmpty)
        XCTAssertEqual(try engine.sync().added, 0)
        XCTAssertFalse(exists(target.appendingPathComponent("local_\(sid).json")))
    }

    func testRestoringAccountDirectoryDoesNotResurrectDeletedSession() throws {
        let (directory, item) = try recoverableFixture(withSession: true)
        let source = try owner("Claude-3p", b)
        _ = try deletionMarker(source)
        let backup = engine.state.appendingPathComponent("removed-records/\(item.id)/content")
        let hash = try digestTree(backup)
        _ = try engine.restoreAccountRecords(id: item.id)
        XCTAssertFalse(exists(directory.appendingPathComponent("local_\(sid).json")))
        XCTAssertTrue(exists(directory.appendingPathComponent("deleted_\(sid)")))
        XCTAssertTrue(try engine.history.catalog().isEmpty)
        XCTAssertEqual(try digestTree(backup), hash)
    }

    func testInterruptedDeletionRollsBackMetadataAndRetainsDeletionIntent() throws {
        let first = try owner("Claude", a), third = try owner("Claude-3p", b)
        let f = try fixture(first), t = try fixture(third)
        _ = try deletionMarker(first); _ = try engine.archive()
        let before = try [f, t].map { try Data(contentsOf: $0) }
        let tx = try Transaction(root: engine.state, operation: "deletion failure fixture")
        var writes = 0
        tx.beforeWrite = { writes += 1; if writes == 5 { throw SyncError("injected write failure") } }
        XCTAssertThrowsError(try engine.history.synchronizeDeletions(transaction: tx))
        try tx.rollback()
        XCTAssertEqual(try [f, t].map { try Data(contentsOf: $0) }, before)
        XCTAssertFalse(exists(third.appendingPathComponent("deleted_\(sid)")))
        XCTAssertTrue(try engine.history.catalog().isEmpty)
        XCTAssertEqual(try engine.status().pendingDeletionCopies, 2)
        _ = try engine.sync()
        XCTAssertFalse(exists(f)); XCTAssertFalse(exists(t))
    }

    func testMalformedAndLinkedDeletionMarkersNeverDeleteRecords() throws {
        let directory = try owner("Claude", a), file = try fixture(directory)
        let marker = directory.appendingPathComponent("deleted_\(sid)")
        for content in ["", "false", "-1", "1.5", "{\"deleted\":true}", String(repeating: "1", count: 64)] {
            try atomicData(Data(content.utf8), marker)
            XCTAssertThrowsError(try engine.sync())
            XCTAssertTrue(exists(file))
        }
        try fm.removeItem(at: marker)
        let elsewhere = root.appendingPathComponent("not-a-marker")
        try atomicData(Data("1793290000000".utf8), elsewhere)
        try fm.createSymbolicLink(at: marker, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try engine.sync())
        XCTAssertTrue(exists(file))
    }

    func testUnknownDesktopCanHideDeletedHistoryButCannotPropagateWrites() throws {
        let directory = try owner("Claude", a), file = try fixture(directory)
        _ = try deletionMarker(directory)
        let unknown = Engine(home: root, process: process, version: "99.0.0")
        XCTAssertTrue(try unknown.status().sessions.isEmpty)
        XCTAssertEqual(try unknown.status().pendingDeletionCopies, 1)
        XCTAssertThrowsError(try unknown.sync())
        XCTAssertTrue(exists(file)); XCTAssertEqual(process.stops, 0)
    }
}
