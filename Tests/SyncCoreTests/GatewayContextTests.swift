import XCTest
@testable import SyncCore

extension CoreTests {
    func contextFixture() throws -> URL {
        var config = try readJSON(engine.library.appendingPathComponent(gateway + ".json"))
        config["inferenceModels"] = [["name": "claude-fable-5-1", "supports1m": true, "prefer1m": true], ["name": "claude-opus-5-5", "supports1m": true, "prefer1m": true]]
        try atomicJSON(config, engine.library.appendingPathComponent(gateway + ".json"))
        try atomicJSON(["lastKnownAccountUuid": a], engine.third.appendingPathComponent("config.json"))
        return engine.third.appendingPathComponent("local-agent-mode-sessions/\(a)/\(org)/cowork_account_settings.json")
    }
    func testDefault1MRepairClearsHistoricalOverridesAndKeepsOtherPreferences() throws {
        let settings = try contextFixture()
        let state: [String: Any] = ["code": ["model": "claude-fable-5-1", "thinking_by_model": ["claude-opus-5-5": ["effort": "max"]]], "cowork": ["model": "claude-fable-5[1m]"], "chat": ["model": "claude-opus-5-5[1m]"]]
        try atomicJSON(["__model_selector_state": state, "paprika_mode": "preserve"], settings)
        let session = try fixture(owner("Claude-3p", a)), beforeSession = try Data(contentsOf: session)
        let beforeMeta = try Data(contentsOf: engine.library.appendingPathComponent("_meta.json"))
        let preview = try engine.gatewayContext(id: gateway)
        XCTAssertEqual(preview.selections.filter { $0.issue != nil }.count, 2)
        XCTAssertEqual(try engine.repairGatewayContext(preview).added, 3)
        let result = try readJSON(settings), selections = result["__model_selector_state"] as! [String: Any]
        XCTAssertNil((selections["code"] as? [String: Any])?["model"])
        XCTAssertNotNil((selections["code"] as? [String: Any])?["thinking_by_model"])
        XCTAssertNil(selections["cowork"])
        XCTAssertEqual((selections["chat"] as? [String: String])?["model"], "claude-opus-5-5[1m]")
        XCTAssertEqual(result["paprika_mode"] as? String, "preserve")
        let config = try readJSON(engine.library.appendingPathComponent(gateway + ".json"))
        XCTAssertEqual(config["modelPrefer1mContext"] as? Bool, true)
        XCTAssertEqual(config["inferenceGatewayApiKey"] as? String, "private-test-key")
        XCTAssertNil(config["alwaysStartWithDefaultModel"])
        XCTAssertEqual(try Data(contentsOf: session), beforeSession)
        XCTAssertEqual(try Data(contentsOf: engine.library.appendingPathComponent("_meta.json")), beforeMeta)
        XCTAssertTrue(try engine.gatewayContext(id: gateway).issues.isEmpty)
    }
    func testDefault1MFreshMachineDoesNotRequirePriorAccountSettings() throws {
        let settings = try contextFixture()
        let preview = try engine.gatewayContext(id: gateway)
        XCTAssertTrue(preview.selections.isEmpty)
        XCTAssertEqual(try engine.repairGatewayContext(preview).added, 1)
        XCTAssertFalse(exists(settings))
        XCTAssertEqual(try engine.repairGatewayContext(engine.gatewayContext(id: gateway)).added, 0)
    }
    func testDefault1MRepairRejectsUnsupportedOrInactiveConfiguration() throws {
        var preview = try engine.gatewayContext(id: gateway)
        XCTAssertNotNil(preview.repairBlockedReason)
        XCTAssertThrowsError(try engine.repairGatewayContext(preview))
        _ = try contextFixture(); try selectOfficial(b)
        preview = try engine.gatewayContext(id: gateway)
        XCTAssertNotNil(preview.repairBlockedReason)
        XCTAssertThrowsError(try engine.repairGatewayContext(preview))
        XCTAssertEqual(try engine.mode(), "1p")
    }
    func testDefault1MRepairRechecksReviewedSettings() throws {
        let settings = try contextFixture()
        try atomicJSON(["__model_selector_state": ["code": ["model": "claude-fable-5-1"]]], settings)
        let preview = try engine.gatewayContext(id: gateway)
        try atomicJSON(["__model_selector_state": ["code": ["model": "claude-opus-5-5[1m]"]]], settings)
        XCTAssertThrowsError(try engine.repairGatewayContext(preview))
        XCTAssertNil(try readJSON(engine.library.appendingPathComponent(gateway + ".json"))["modelPrefer1mContext"])
        XCTAssertEqual((try readJSON(settings)["__model_selector_state"] as? [String: [String: String]])?["code"]?["model"], "claude-opus-5-5[1m]")
    }
    func testDefault1MAmbiguousOrganizationRefusesRepair() throws {
        let settings = try contextFixture(); try atomicJSON([:], settings)
        let other = settings.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(b + "/cowork_account_settings.json")
        try atomicJSON([:], other)
        let preview = try engine.gatewayContext(id: gateway)
        XCTAssertNotNil(preview.repairBlockedReason)
        XCTAssertThrowsError(try engine.repairGatewayContext(preview))
    }
    func testNewGateway1MIsExplicitAndDiscoveryDoesNotInventCapabilities() throws {
        let normal = engine.newGatewayModels(["claude-fable-5-1"], prefer1m: false)
        XCTAssertNil(normal["modelPrefer1mContext"])
        XCTAssertNil((normal["inferenceModels"] as? [[String: Any]])?.first?["supports1m"])
        let explicit = engine.newGatewayModels(["claude-fable-5-1"], prefer1m: true)
        XCTAssertEqual((explicit["inferenceModels"] as? [[String: Any]])?.first?["supports1m"] as? Bool, true)
        XCTAssertEqual((explicit["inferenceModels"] as? [[String: Any]])?.first?["prefer1m"] as? Bool, true)
        let discovered = engine.newGatewayModels([], prefer1m: true)
        XCTAssertEqual(discovered["modelPrefer1mContext"] as? Bool, true)
        XCTAssertNil(discovered["inferenceModels"])
    }
}
