import XCTest
@testable import SyncCore

extension CoreTests {
    func testAliasesPersistWithoutRestartingOrChangingNativeData() throws {
        try login(a, token: "fixture-only")
        try atomicJSON(["accounts": [["id": sid, "account": a, "name": "Original account"]]], engine.registry)
        let session = try fixture(owner("Claude-3p", b))
        let protected = [engine.first, engine.third, engine.registry, session, root.appendingPathComponent(".claude")]
        let before = try protected.map { try digestTree($0) }
        process.workers = 3
        _ = try engine.setProfileAlias(id: gateway, kind: "gateway", alias: "  工作 API 🚀  ")
        _ = try engine.setProfileAlias(id: sid, kind: "account", alias: "个人订阅")
        let reloaded = Engine(home: root, process: process, version: "4.29.0")
        let status = try reloaded.status()
        XCTAssertEqual(status.profiles.map(\.name), ["工作 API 🚀", "个人订阅"])
        XCTAssertEqual(status.profiles.map(\.originalName), ["Gateway", "Original account"])
        XCTAssertEqual(status.officialUsage.first?.name, "个人订阅")
        XCTAssertEqual(try protected.map { try digestTree($0) }, before)
        XCTAssertEqual(process.stops, 0)
        XCTAssertEqual(process.starts, 0)
        XCTAssertEqual(process.workers, 3)
        XCTAssertTrue(process.running)
        XCTAssertEqual(status.mode, "3p")
        XCTAssertFalse(status.pendingRecovery)
        XCTAssertEqual(try fm.attributesOfItem(atPath: engine.aliasRegistry.path)[.posixPermissions] as? Int, 0o600)
    }

    func testAliasResetUsesLatestOriginalNameAndKeepsOtherAliases() throws {
        try usageRegistry()
        _ = try engine.setProfileAlias(id: gateway, kind: "gateway", alias: "API alias")
        _ = try engine.setProfileAlias(id: gateway, kind: "account", alias: "Official alias")
        _ = try engine.setProfileAlias(id: sid, kind: "account", alias: "Second account")
        var metadata = try engine.metadata()
        metadata["entries"] = [["id": gateway, "name": "Renamed in Claude"]]
        try atomicJSON(metadata, engine.library.appendingPathComponent("_meta.json"))
        XCTAssertEqual(try engine.status().profiles.first?.name, "API alias")
        _ = try engine.setProfileAlias(id: gateway, kind: "gateway", alias: nil)
        let status = try engine.status()
        XCTAssertEqual(status.profiles.first?.name, "Renamed in Claude")
        XCTAssertNil(status.profiles.first?.alias)
        XCTAssertEqual(try engine.usageAccounts(), [a: "Official alias", b: "Second account"])
        _ = try engine.setProfileAlias(id: gateway, kind: "account", alias: nil)
        XCTAssertEqual(try engine.usageAccounts(), [a: "Account A", b: "Second account"])
    }

    func testOfficialAliasSurvivesSnapshotRefreshAndDoesNotChangeUsageHistory() async throws {
        try selectOfficial(a)
        _ = try engine.saveAccount(name: "Initial name")
        let id = try XCTUnwrap(engine.accounts().first?["id"] as? String)
        _ = try await engine.refreshUsage(credential: { _ in UsageCredential(token: "fixture", plan: "pro") }, fetch: { _ in try self.usageData(7) })
        let usageBefore = try Data(contentsOf: engine.usageCache)
        _ = try engine.setProfileAlias(id: id, kind: "account", alias: "My account")
        _ = try engine.saveAccount(name: "Updated source name")
        let status = try engine.status()
        let profile = try XCTUnwrap(status.profiles.first { $0.kind == "account" })
        XCTAssertEqual(profile.name, "My account")
        XCTAssertEqual(profile.originalName, "Updated source name")
        XCTAssertEqual(status.officialUsage.first?.name, "My account")
        XCTAssertEqual(status.officialUsage.first?.windows.first?.utilization, 7)
        XCTAssertEqual(try Data(contentsOf: engine.usageCache), usageBefore)
        _ = try engine.setProfileAlias(id: id, kind: "account", alias: nil)
        XCTAssertEqual(try engine.officialUsage().first?.name, "Updated source name")
    }

    func testInvalidAndStaleAliasEditsPreserveSavedAliases() throws {
        _ = try engine.setProfileAlias(id: gateway, kind: "gateway", alias: "Keep")
        let before = try Data(contentsOf: engine.aliasRegistry)
        for alias in ["", " \n ", "line\nbreak", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try engine.setProfileAlias(id: gateway, kind: "gateway", alias: alias))
        }
        XCTAssertThrowsError(try engine.setProfileAlias(id: "../file", kind: "gateway", alias: "No"))
        XCTAssertThrowsError(try engine.setProfileAlias(id: gateway, kind: "official", alias: "No"))
        XCTAssertThrowsError(try engine.setProfileAlias(id: sid, kind: "account", alias: "Gone"))
        try atomicJSON(["entries": []], engine.library.appendingPathComponent("_meta.json"))
        XCTAssertThrowsError(try engine.setProfileAlias(id: gateway, kind: "gateway", alias: "Gone"))
        XCTAssertEqual(try Data(contentsOf: engine.aliasRegistry), before)
        XCTAssertEqual(process.stops, 0)
    }

    func testAliasMetadataIsIndependentOfClaudeVersionAndRefusesCorruptState() throws {
        let newer = Engine(home: root, process: process, version: "99.0.0")
        try atomicJSON(["aliases": [:], "futureMetadata": "keep"], engine.aliasRegistry)
        _ = try newer.setProfileAlias(id: gateway, kind: "gateway", alias: "Local display only")
        XCTAssertEqual(try readJSON(engine.aliasRegistry)["futureMetadata"] as? String, "keep")
        let before = try Data(contentsOf: engine.aliasRegistry)
        try atomicJSON([:], engine.state.appendingPathComponent("pending.json"))
        XCTAssertThrowsError(try engine.setProfileAlias(id: gateway, kind: "gateway", alias: "No"))
        XCTAssertEqual(try Data(contentsOf: engine.aliasRegistry), before)
        try fm.removeItem(at: engine.state.appendingPathComponent("pending.json"))
        try atomicJSON(["aliases": ["not-a-profile": 5]], engine.aliasRegistry)
        let corrupt = try Data(contentsOf: engine.aliasRegistry)
        XCTAssertThrowsError(try engine.setProfileAlias(id: gateway, kind: "gateway", alias: "No"))
        XCTAssertEqual(try Data(contentsOf: engine.aliasRegistry), corrupt)
        XCTAssertEqual(process.stops, 0)
    }
}
