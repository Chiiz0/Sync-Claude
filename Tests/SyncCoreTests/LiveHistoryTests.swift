import XCTest
@testable import SyncCore

extension CoreTests {
    func testSavedCurrentAccountCannotBeSavedAgainAndDoesNotRestart() throws {
        try selectOfficial(a)
        XCTAssertTrue(try engine.status().canSaveOfficialAccount)
        _ = try engine.saveAccount(name: "Account A")
        XCTAssertFalse(try engine.status().canSaveOfficialAccount)
        let before = try digestTree(engine.state), stops = process.stops
        XCTAssertTrue(try engine.saveAccount(name: "Duplicate").message.contains("已保存"))
        XCTAssertEqual(try digestTree(engine.state), before)
        XCTAssertEqual(process.stops, stops)
        try login(b, token: "B")
        XCTAssertTrue(try engine.status().canSaveOfficialAccount)
    }

    func testInitializingSessionIsVisibleButOnlyArchivedAndMergedWhenReady() throws {
        let owner = try owner("Claude-3p", a)
        let file = owner.appendingPathComponent("local_\(sid).json")
        let placeholder: [String: Any] = ["sessionId": "local_" + sid, "cwd": root.path, "title": "Starting",
            "lastActivityAt": 100, "pendingFirstStart": ["since": 100, "options": [:]]]
        try atomicJSON(placeholder, file)
        _ = try fixture(owner, id: gateway)
        let before = try Data(contentsOf: file)
        let status = try engine.status()
        XCTAssertEqual(status.sessions.count, 2)
        XCTAssertTrue(try XCTUnwrap(status.sessions.first { $0.id == "local_" + sid }).initializing)
        XCTAssertEqual(try engine.archive().added, 1)
        XCTAssertNil(try readJSON(engine.history.vault.appendingPathComponent("index.json"))["local_" + sid])
        XCTAssertEqual(try Data(contentsOf: file), before)
        _ = try fixture(owner)
        XCTAssertEqual(try engine.archive().added, 2)
        XCTAssertFalse(try XCTUnwrap(engine.status().sessions.first { $0.id == "local_" + sid }).initializing)
        let target = try self.owner("Claude", b); try selectOfficial(b)
        _ = try engine.sync()
        XCTAssertTrue(exists(target.appendingPathComponent(file.lastPathComponent)))
    }

    func testInvalidCLIOrUnrecognizedPlaceholderStillFails() throws {
        let file = try owner("Claude-3p", a).appendingPathComponent("local_\(sid).json")
        var value: [String: Any] = ["sessionId": "local_" + sid, "cwd": root.path]
        try atomicJSON(value, file); XCTAssertThrowsError(try engine.archive())
        value["pendingFirstStart"] = ["since": 100, "options": [:]]
        value["cliSessionId"] = "not-a-uuid"
        try atomicJSON(value, file); XCTAssertThrowsError(try engine.archive())
        value["cliSessionId"] = NSNull()
        try atomicJSON(value, file); XCTAssertNoThrow(try engine.archive())
        value["cwd"] = "relative"
        try atomicJSON(value, file); XCTAssertThrowsError(try engine.archive())
    }

    func testNativeJSONReadRetriesOnlyTransientReadFailures() throws {
        let file = root.appendingPathComponent("record.json")
        try atomicJSON(["ready": true], file)
        var calls = 0
        let value = try readNativeRecordJSON(file, running: true, read: { path in
            calls += 1
            return calls == 1 ? Data("{\"ready\":".utf8) : try Data(contentsOf: path)
        }, pause: { _ in })
        XCTAssertEqual(calls, 2); XCTAssertEqual(value["ready"] as? Bool, true)
        calls = 0
        XCTAssertThrowsError(try readNativeRecordJSON(file, running: true, read: { _ in
            calls += 1; throw CocoaError(.fileReadNoPermission)
        }, pause: { _ in }))
        XCTAssertEqual(calls, 1)
    }

    func testRecentPartialJSONIsDeferredButStableCorruptionAndStoppedClaudeFail() throws {
        let file = root.appendingPathComponent("record.json")
        try atomicData(Data("{unfinished".utf8), file)
        XCTAssertThrowsError(try readNativeRecordJSON(file, running: true, pause: { _ in })) { XCTAssertTrue($0 is LiveRecordReadPending) }
        XCTAssertThrowsError(try readNativeRecordJSON(file, running: false, pause: { _ in })) { XCTAssertFalse($0 is LiveRecordReadPending) }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file.path)
        XCTAssertThrowsError(try readNativeRecordJSON(file, running: true, pause: { _ in })) { XCTAssertFalse($0 is LiveRecordReadPending) }
        let link = root.appendingPathComponent("link.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try readNativeRecordJSON(link, running: true, pause: { _ in })) { XCTAssertFalse($0 is LiveRecordReadPending) }
    }
}
