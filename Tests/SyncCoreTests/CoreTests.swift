import XCTest
@testable import SyncCore

final class FakeProcess: ClaudeProcess {
    var running = true
    var workers = 0
    var stops = 0
    var starts = 0
    var failStart = false
    func stop(allowOpenSessions: Bool) throws {
        if workers > 0 && !allowOpenSessions { throw SyncError("active workers") }
        stops += 1; running = false; workers = 0
    }
    func start() throws {
        starts += 1
        if failStart { throw SyncError("start failure") }
        running = true
    }
}
final class CoreTests: XCTestCase {
    var root: URL!
    var engine: Engine!
    var process: FakeProcess!
    let a = "11111111-1111-4111-8111-111111111111"
    let b = "22222222-2222-4222-8222-222222222222"
    let org = "00000000-0000-4000-8000-000000000001"
    let sid = "33333333-3333-4333-8333-333333333333"
    let gateway = "44444444-4444-4444-8444-444444444444"
    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)")
        try privateDir(root)
        let version = ProcessInfo.processInfo.environment["SYNC_CLAUDE_TEST_DESKTOP_VERSION"] ?? "4.29.0"
        guard DesktopCompatibility.supports(version) else { throw SyncError("Unsupported fixture Desktop version: \(version)") }
        process = FakeProcess(); engine = Engine(home: root, process: process, version: version)
        try atomicJSON(["deploymentMode": "3p", "preferences": ["theme": "dark"]], engine.third.appendingPathComponent("claude_desktop_config.json"))
        try atomicJSON(["entries": [["id": gateway, "name": "Gateway"]], "appliedId": gateway, "custom": "preserve"], engine.library.appendingPathComponent("_meta.json"))
        try atomicJSON(["inferenceProvider": "gateway", "inferenceGatewayBaseUrl": "https://example.com/secret-path", "inferenceGatewayApiKey": "private-test-key"], engine.library.appendingPathComponent(gateway + ".json"))
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }
    func owner(_ profile: String, _ account: String) throws -> URL {
        let d = engine.support.appendingPathComponent("\(profile)/claude-code-sessions/\(account)/\(org)")
        try privateDir(d); return d
    }
    func fixture(_ directory: URL, id: String? = nil, time: Double = 100, transcript: Bool = true) throws -> URL {
        let id = id ?? sid
        let value: [String: Any] = ["sessionId": "local_" + id, "cliSessionId": id, "cwd": root.appendingPathComponent("project").path, "title": "A session", "lastActivityAt": time, "permissionMode": "bypassPermissions", "remoteMcpServersConfig": [["token": "do-not-copy"]], "alwaysAllowedReasons": ["old-approval"]]
        let path = directory.appendingPathComponent("local_\(id).json")
        try atomicJSON(value, path)
        if transcript { try atomicData(Data("{\"type\":\"user\",\"message\":\"fixture\"}\n".utf8), root.appendingPathComponent(".claude/projects/-fixture/\(id).jsonl")) }
        return path
    }
    func login(_ id: String, token: String) throws {
        try atomicJSON(["lastKnownAccountUuid": id, "oauth:tokenCacheV2": token, "theme": "dark"], engine.first.appendingPathComponent("config.json"))
        try atomicData(Data(token.utf8), engine.first.appendingPathComponent("Cookies"))
    }
    func selectOfficial(_ account: String) throws {
        try login(account, token: "test-only")
        var config = try readJSON(engine.third.appendingPathComponent("claude_desktop_config.json"))
        config["deploymentMode"] = "1p"
        try atomicJSON(config, engine.third.appendingPathComponent("claude_desktop_config.json"))
    }
    func testSwitchPreservesConfigurationAndLibraries() throws {
        _ = try engine.switchProfile(id: "official")
        XCTAssertEqual(try engine.mode(), "1p")
        XCTAssertEqual(try readJSON(engine.third.appendingPathComponent("claude_desktop_config.json"))["preferences"] as? [String: String], ["theme": "dark"])
        _ = try engine.switchProfile(id: gateway)
        XCTAssertEqual(try engine.mode(), "3p")
        XCTAssertEqual(try engine.metadata()["custom"] as? String, "preserve")
        XCTAssertEqual(try engine.metadata()["appliedId"] as? String, gateway)
        XCTAssertEqual(process.starts, 2)
    }
    func testUnionIsIdempotentAndResetsPermissions() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        let original = try fixture(source), before = try Data(contentsOf: original)
        XCTAssertEqual(try engine.sync().added, 1)
        XCTAssertEqual(try engine.sync().added, 0)
        let copied = try readJSON(target.appendingPathComponent("local_\(sid).json"))
        XCTAssertEqual(copied["permissionMode"] as? String, "default")
        XCTAssertNil(copied["remoteMcpServersConfig"])
        XCTAssertNil(copied["alwaysAllowedReasons"])
        XCTAssertEqual(try Data(contentsOf: original), before)
    }
    func testDeletedTargetAndMissingTranscriptAreNotImported() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        _ = try fixture(source)
        try atomicData(Data("1".utf8), target.appendingPathComponent("deleted_\(sid)"))
        _ = try fixture(source, id: gateway, transcript: false)
        XCTAssertEqual(try engine.sync().added, 0)
        XCTAssertFalse(exists(target.appendingPathComponent("local_\(sid).json")))
    }
    func testExistingTargetIsNeverOverwrittenAndVersionsAreRetained() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        _ = try fixture(source, time: 200)
        let destination = try fixture(target, time: 100), old = try Data(contentsOf: destination)
        XCTAssertEqual(try engine.sync().added, 0)
        XCTAssertEqual(try Data(contentsOf: destination), old)
        let versions = try fm.contentsOfDirectory(at: engine.history.vault.appendingPathComponent("records/local_\(sid)"), includingPropertiesForKeys: nil)
        XCTAssertEqual(versions.count, 2)
    }
    func testSyncOnlyWritesCurrentAccountAndProfile() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        let stale = try owner("Claude", a), otherAPI = try owner("Claude-3p", b)
        _ = try fixture(source)
        try selectOfficial(b)
        XCTAssertEqual(try engine.sync().added, 1)
        XCTAssertTrue(exists(target.appendingPathComponent("local_\(sid).json")))
        XCTAssertFalse(exists(stale.appendingPathComponent("local_\(sid).json")))
        XCTAssertFalse(exists(otherAPI.appendingPathComponent("local_\(sid).json")))
    }
    func testSwitchImportsIntoDestinationIdentity() throws {
        let source = try owner("Claude", b), target = try owner("Claude-3p", a)
        let stale = try owner("Claude-3p", b)
        _ = try fixture(source)
        try selectOfficial(b)
        try atomicJSON(["lastKnownAccountUuid": a], engine.third.appendingPathComponent("config.json"))
        XCTAssertEqual(try engine.switchProfile(id: gateway).added, 1)
        XCTAssertTrue(exists(target.appendingPathComponent("local_\(sid).json")))
        XCTAssertFalse(exists(stale.appendingPathComponent("local_\(sid).json")))
    }
    func testUnknownIdentityDoesNotImportIntoStaleScopes() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        _ = try fixture(source)
        XCTAssertEqual(try engine.switchProfile(id: "official").added, 0)
        XCTAssertFalse(exists(target.appendingPathComponent("local_\(sid).json")))
    }
    func testAmbiguousOrganizationRollsBackWithoutImporting() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        let other = target.deletingLastPathComponent().appendingPathComponent(gateway)
        try privateDir(other)
        _ = try fixture(source)
        try selectOfficial(b)
        XCTAssertThrowsError(try engine.sync())
        XCTAssertFalse(exists(target.appendingPathComponent("local_\(sid).json")))
        XCTAssertFalse(exists(other.appendingPathComponent("local_\(sid).json")))
        XCTAssertTrue(process.running)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }
    func testMalformedRecordPreventsMutationAndReopensClaude() throws {
        let d = try owner("Claude-3p", a)
        try atomicData(Data("{broken".utf8), d.appendingPathComponent("local_\(sid).json"))
        XCTAssertThrowsError(try engine.switchProfile(id: "official"))
        XCTAssertEqual(try engine.mode(), "3p")
        XCTAssertTrue(process.running)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }
    func testBusyClaudeRefusesSwitchWithoutWriting() throws {
        process.workers = 1
        XCTAssertThrowsError(try engine.switchProfile(id: "official"))
        XCTAssertEqual(process.stops, 0)
        XCTAssertEqual(try engine.mode(), "3p")
    }
    func testExplicitConsentAllowsGracefulRestartOfOpenSession() throws {
        process.workers = 1
        _ = try engine.switchProfile(id: "official", allowOpenSessions: true)
        XCTAssertEqual(process.stops, 1)
        XCTAssertEqual(process.starts, 1)
        XCTAssertEqual(try engine.mode(), "1p")
    }
    func testUnverifiedVersionOnlyAllowsArchive() throws {
        let future = Engine(home: root, process: process, version: "9.0.0")
        XCTAssertThrowsError(try future.switchProfile(id: "official"))
        XCTAssertNoThrow(try future.archive())
        XCTAssertEqual(process.stops, 0)
    }
    func testAccountSnapshotsPreserveAndRefreshEachIdentity() throws {
        _ = try engine.switchProfile(id: "official")
        try login(a, token: "A-original")
        _ = try engine.saveAccount(name: "Account A")
        _ = try engine.newLogin()
        XCTAssertFalse(exists(engine.first.appendingPathComponent("Cookies")))
        try login(b, token: "B-original")
        _ = try engine.saveAccount(name: "Account B")
        let profiles = try engine.status().profiles
        let aid = try XCTUnwrap(profiles.first { $0.name == "Account A" }?.id)
        let bid = try XCTUnwrap(profiles.first { $0.name == "Account B" }?.id)
        _ = try engine.switchProfile(id: aid)
        XCTAssertEqual(try Data(contentsOf: engine.first.appendingPathComponent("Cookies")), Data("A-original".utf8))
        try login(a, token: "A-refreshed")
        _ = try engine.switchProfile(id: bid)
        XCTAssertEqual(try engine.accountID(), b)
        _ = try engine.switchProfile(id: aid)
        XCTAssertEqual(try Data(contentsOf: engine.first.appendingPathComponent("Cookies")), Data("A-refreshed".utf8))
    }
    func testSnapshotTamperingIsRejectedAndCurrentIdentityRetained() throws {
        _ = try engine.switchProfile(id: "official"); try login(a, token: "A")
        _ = try engine.saveAccount(name: "A")
        let entry = try XCTUnwrap(engine.accounts().first), id = entry["id"] as! String, snapshot = entry["snapshot"] as! String
        try atomicData(Data("tampered".utf8), engine.state.appendingPathComponent("accounts/\(id)/\(snapshot)/Cookies"))
        try login(b, token: "B")
        XCTAssertThrowsError(try engine.switchProfile(id: id))
        XCTAssertEqual(try engine.accountID(), b)
        XCTAssertEqual(try Data(contentsOf: engine.first.appendingPathComponent("Cookies")), Data("B".utf8))
    }
    func testJournalRecoversPartialWritesAndRetainsBackups() throws {
        let path = engine.first.appendingPathComponent("test.json")
        try atomicJSON(["old": true], path)
        let tx = try Transaction(root: engine.state, operation: "crash fixture")
        try tx.write(["new": true], to: path)
        try tx.write(["brandNew": true], to: engine.first.appendingPathComponent("new.json"))
        try Transaction.recover(root: engine.state)
        XCTAssertEqual(try readJSON(path)["old"] as? Bool, true)
        XCTAssertFalse(exists(engine.first.appendingPathComponent("new.json")))
        XCTAssertTrue(exists(tx.folder.appendingPathComponent("0-before")))
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }
    func testSymlinkedSessionOrAncestorIsRejected() throws {
        let d = try owner("Claude-3p", a), source = try fixture(d)
        let target = try owner("Claude", b).appendingPathComponent(source.lastPathComponent)
        try fm.createSymbolicLink(at: target, withDestinationURL: source)
        XCTAssertThrowsError(try engine.archive())
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: engine.first)
        XCTAssertThrowsError(try atomicJSON(["bad": true], alias.appendingPathComponent("nested/file.json")))
    }
    func testArchiveOmitsPartialJSONLButKeepsSource() throws {
        let d = try owner("Claude-3p", a); _ = try fixture(d)
        let source = root.appendingPathComponent(".claude/projects/-fixture/\(sid).jsonl")
        let data = Data("{\"valid\":true}\n{\"unfinished\":".utf8)
        try atomicData(data, source)
        _ = try engine.archive()
        let versions = try fm.contentsOfDirectory(at: engine.history.vault.appendingPathComponent("transcripts/\(sid)"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(versions.first)), Data("{\"valid\":true}\n".utf8))
        XCTAssertEqual(try Data(contentsOf: source), data)
    }
    func testStatusDoesNotExposeGatewayCredentialsOrURLPath() throws {
        let text = String(decoding: try JSONEncoder().encode(engine.status()), as: UTF8.self)
        XCTAssertFalse(text.contains("private-test-key"))
        XCTAssertFalse(text.contains("secret-path"))
        XCTAssertTrue(text.contains("example.com"))
    }
    func testUnknownProfileRollsBackAndRestarts() throws {
        XCTAssertThrowsError(try engine.switchProfile(id: sid))
        XCTAssertEqual(try engine.mode(), "3p")
        XCTAssertTrue(process.running)
    }
    func testStartFailureReportsSavedStateRatherThanClaimingReadiness() throws {
        process.failStart = true
        let outcome = try engine.switchProfile(id: "official")
        XCTAssertTrue(outcome.message.contains("未能启动"))
        XCTAssertEqual(try engine.mode(), "1p")
    }
    func testOrganizationManagedConfigIsNotOverridden() throws {
        var meta = try engine.metadata(); meta["hybridPointer"] = "https://organization.invalid"
        try atomicJSON(meta, engine.library.appendingPathComponent("_meta.json"))
        XCTAssertThrowsError(try engine.switchProfile(id: gateway))
        XCTAssertEqual(process.stops, 0)
    }
    func testLockBlocksConcurrentMutation() throws {
        try locked(engine.state) { XCTAssertThrowsError(try engine.archive()) }
    }
    func testRecoveryRejectsOutOfScopeDestination() throws {
        let tx = try Transaction(root: engine.state, operation: "scope-test")
        let outside = root.appendingPathComponent("outside.json")
        try atomicJSON(["preserve": true], outside)
        tx.journal.entries = [Undo(destination: outside.path)]
        try tx.persist()
        XCTAssertThrowsError(try Transaction.recover(root: engine.state))
        XCTAssertEqual(try readJSON(outside)["preserve"] as? Bool, true)
    }
    func testNewProcessBlocksFurtherWrites() throws {
        let tx = try Transaction(root: engine.state, operation: "restart-race")
        tx.beforeWrite = { throw SyncError("reopened") }
        XCTAssertThrowsError(try tx.write(["bad": true], to: engine.first.appendingPathComponent("race.json")))
        XCTAssertFalse(exists(engine.first.appendingPathComponent("race.json")))
        try tx.rollback()
    }
}
