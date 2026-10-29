import XCTest
@testable import SyncCore

extension CoreTests {
    func extraGateway() throws -> URL {
        let file = engine.library.appendingPathComponent(sid + ".json")
        try atomicJSON(["inferenceProvider": "gateway", "inferenceGatewayBaseUrl": "https://unused.example", "inferenceGatewayApiKey": "dummy-delete-test"], file)
        var meta = try engine.metadata()
        meta["entries"] = [["id": gateway, "name": "Gateway"], ["id": sid, "name": "Unused API"]]
        try atomicJSON(meta, engine.library.appendingPathComponent("_meta.json"))
        return file
    }

    func savedOfficialForDeletion() throws -> String {
        try selectOfficial(a)
        _ = try engine.saveAccount(name: "Account A")
        let id = try XCTUnwrap(engine.accounts().first?["id"] as? String)
        _ = try engine.switchProfile(id: gateway)
        return id
    }

    func testDeleteInactiveGatewayRemovesOnlyReviewedConfiguration() throws {
        let file = try extraGateway()
        _ = try engine.setProfileAlias(id: sid, kind: "gateway", alias: "Unused alias")
        _ = try engine.setProfileAlias(id: gateway, kind: "gateway", alias: "Keep alias")
        let record = try fixture(owner("Claude-3p", a))
        let protected = [engine.third.appendingPathComponent("claude_desktop_config.json"), engine.library.appendingPathComponent(gateway + ".json"), record, root.appendingPathComponent(".claude")]
        let before = try protected.map { try digestTree($0) }
        let preview = try engine.profileDeletionPreview(id: sid, kind: "gateway")
        XCTAssertEqual(preview.name, "Unused alias")
        XCTAssertEqual(try engine.deleteProfile(preview).added, 1)
        XCTAssertFalse(exists(file))
        XCTAssertEqual((try engine.metadata()["entries"] as? [[String: String]])?.map { $0["id"] }, [gateway])
        XCTAssertEqual(try engine.metadata()["appliedId"] as? String, gateway)
        XCTAssertEqual(try engine.metadata()["custom"] as? String, "preserve")
        XCTAssertEqual(try engine.profileAliases(), [engine.aliasKey(id: gateway, kind: "gateway"): "Keep alias"])
        XCTAssertEqual(try protected.map { try digestTree($0) }, before)
        XCTAssertEqual(process.stops, 1)
        XCTAssertEqual(process.starts, 1)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
        let backups = try treeFiles(engine.state.appendingPathComponent("backups"))
        XCTAssertTrue(try backups.contains { try Data(contentsOf: $0).range(of: Data("dummy-delete-test".utf8)) != nil })
    }

    func testDeleteLastGatewayInOfficialModeClearsDormantSelection() throws {
        try selectOfficial(a)
        let preview = try engine.profileDeletionPreview(id: gateway, kind: "gateway")
        _ = try engine.deleteProfile(preview)
        XCTAssertNil(try engine.metadata()["appliedId"])
        XCTAssertTrue((try engine.metadata()["entries"] as? [Any])?.isEmpty == true)
        XCTAssertEqual(try engine.mode(), "1p")
        XCTAssertEqual(try engine.accountID(), a)
    }

    func testDeletedOfficialAccountStaysRemovedUntilExplicitlySavedAgain() async throws {
        let id = try savedOfficialForDeletion()
        _ = try engine.setProfileAlias(id: id, kind: "account", alias: "Remove me")
        _ = try await engine.refreshUsage(credential: { _ in UsageCredential(token: "fixture", plan: "pro") }, fetch: { _ in try self.usageData(8) })
        var document = try readJSON(engine.registry); document["otherMetadata"] = "keep"; try atomicJSON(document, engine.registry)
        let firstBefore = try digestTree(engine.first)
        _ = try engine.deleteProfile(engine.profileDeletionPreview(id: id, kind: "account"))
        XCTAssertTrue(try engine.accounts().isEmpty)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("accounts/\(id)")))
        XCTAssertEqual(try digestTree(engine.first), firstBefore)
        XCTAssertEqual(try engine.forgottenAccountIDs(), [a])
        XCTAssertEqual(try readJSON(engine.registry)["otherMetadata"] as? String, "keep")
        XCTAssertNil(try engine.profileAliases()[engine.aliasKey(id: id, kind: "account")])
        XCTAssertTrue(try engine.officialUsage().isEmpty)
        XCTAssertNil(try engine.cachedUsage()[a])
        // Both implicit snapshot paths must respect explicit deletion.
        _ = try engine.switchProfile(id: "official")
        _ = try engine.switchProfile(id: gateway)
        XCTAssertTrue(try engine.accounts().isEmpty)
        _ = try engine.newLogin()
        XCTAssertTrue(try engine.accounts().isEmpty)
        try login(a, token: "new-login")
        _ = try engine.saveAccount(name: "Added again")
        XCTAssertEqual(try engine.accounts().count, 1)
        XCTAssertFalse(try engine.forgottenAccountIDs().contains(a))
        XCTAssertEqual(try engine.officialUsage().first?.name, "Added again")
    }

    func testDeletingActiveOrStaleProfilesDoesNotStopClaude() throws {
        XCTAssertThrowsError(try engine.profileDeletionPreview(id: gateway, kind: "gateway"))
        let file = try extraGateway()
        let preview = try engine.profileDeletionPreview(id: sid, kind: "gateway")
        try atomicJSON(["changed": true], file)
        XCTAssertThrowsError(try engine.deleteProfile(preview))
        XCTAssertEqual(process.stops, 0)
        try selectOfficial(a)
        _ = try engine.saveAccount(name: "Active official")
        let id = try XCTUnwrap(engine.accounts().first?["id"] as? String)
        let stops = process.stops
        XCTAssertThrowsError(try engine.profileDeletionPreview(id: id, kind: "account"))
        XCTAssertEqual(process.stops, stops)
        XCTAssertThrowsError(try engine.profileDeletionPreview(id: "../invalid", kind: "account"))
        XCTAssertThrowsError(try engine.profileDeletionPreview(id: gateway, kind: "official"))
    }

    func testProfileDeleteRollbackRestoresAccountAndSnapshots() throws {
        let id = try savedOfficialForDeletion()
        let snapshotRoot = engine.state.appendingPathComponent("accounts/\(id)")
        let registryBefore = try Data(contentsOf: engine.registry), snapshotsBefore = try digestTree(snapshotRoot)
        // Failure occurs after registry and snapshot removal, exercising rollback of both.
        try atomicJSON(["malformed": "usage"], engine.usageCache)
        let preview = try engine.profileDeletionPreview(id: id, kind: "account")
        XCTAssertThrowsError(try engine.deleteProfile(preview))
        XCTAssertEqual(try Data(contentsOf: engine.registry), registryBefore)
        XCTAssertEqual(try digestTree(snapshotRoot), snapshotsBefore)
        XCTAssertTrue(try engine.forgottenAccountIDs().isEmpty)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
        XCTAssertTrue(process.running)
    }

    func testUsageInFlightCannotRecreateDeletedAccountCache() async throws {
        let id = try savedOfficialForDeletion()
        let preview = try engine.profileDeletionPreview(id: id, kind: "account")
        let result = try await engine.refreshUsage(credential: { _ in UsageCredential(token: "fixture", plan: "pro") }, fetch: { _ in
            _ = try self.engine.deleteProfile(preview)
            return try self.usageData(9)
        })
        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(try engine.cachedUsage().isEmpty)
        XCTAssertTrue(try engine.officialUsage().isEmpty)
    }

    func testDeleteRejectsPendingRecoveryAndChangedSelection() throws {
        _ = try extraGateway()
        let preview = try engine.profileDeletionPreview(id: sid, kind: "gateway")
        var meta = try engine.metadata(); meta["appliedId"] = sid
        try atomicJSON(meta, engine.library.appendingPathComponent("_meta.json"))
        XCTAssertThrowsError(try engine.deleteProfile(preview))
        meta["appliedId"] = gateway; try atomicJSON(meta, engine.library.appendingPathComponent("_meta.json"))
        try atomicJSON([:], engine.state.appendingPathComponent("pending.json"))
        XCTAssertThrowsError(try engine.deleteProfile(preview))
        XCTAssertEqual(process.stops, 0)
        XCTAssertTrue(exists(engine.library.appendingPathComponent(sid + ".json")))
    }
}
