import XCTest
@testable import SyncCore

extension CoreTests {
    func usageData(_ percent: Int) throws -> Data {
        try jsonData(["five_hour": ["utilization": percent, "resets_at": "2026-10-29T19:20:00.333497+00:00"], "seven_day": ["utilization": 0, "resets_at": 1793354400]])
    }
    func usageRegistry() throws {
        try atomicJSON(["accounts": [["id": gateway, "account": a, "name": "Account A"], ["id": sid, "account": b, "name": "Account B"]]], engine.registry)
    }
    func testDesktopTokenDecryptUsesV10GoldenFixture() throws {
        // Fixture encrypted independently with OpenSSL and PBKDF2-HMAC-SHA1; no real credential.
        let fixture = "djEwDbY1hae4DCdyUny/pcoJYfEZSZknabHu6NMstt1RLOEArjNfwu4+HcXmbycoNdcj"
        let value = try DesktopTokenReader.decrypt(fixture, password: Data("fixture-password".utf8))
        XCTAssertEqual((value["fixture"] as? [String: String])?["token"], "dummy-only")
        XCTAssertThrowsError(try DesktopTokenReader.decrypt(fixture, password: Data("wrong".utf8)))
        XCTAssertThrowsError(try DesktopTokenReader.decrypt(Data("v20not-supported".utf8).base64EncodedString(), password: Data("fixture-password".utf8)))
    }
    func testUsageCredentialRequiresExactAccountHostScopeAndLiveExpiry() throws {
        let prefix = "|9d1c250a-e61b-44d9-88ed-5944d1962f5e:\(org):"
        func entry(_ token: String, expiry: Double = 2000000) -> [String: Any] { ["token": token, "expiresAt": expiry, "subscriptionType": "pro"] }
        let entries: [String: Any] = [
            "acct:\(a)\(prefix)https://api.anthropic.com:user:inference user:profile": entry("correct"),
            "acct:\(b)\(prefix)https://api.anthropic.com:user:inference user:profile user:sessions:claude_code": entry("other-account"),
            "acct:\(a)\(prefix)https://attacker.invalid:user:inference user:profile": entry("wrong-host"),
            "acct:\(a)\(prefix)https://api.anthropic.com:user:inference": entry("missing-profile-scope"),
            "acct:\(a)\(prefix)https://api.anthropic.com:user:inference user:profile user:sessions:claude_code": entry("expired", expiry: 0)
        ]
        XCTAssertEqual(try DesktopTokenReader.credential(entries, account: a, now: 1000).token, "correct")
        XCTAssertThrowsError(try DesktopTokenReader.credential(entries, account: gateway, now: 1000))
        XCTAssertThrowsError(try DesktopTokenReader.credential(entries, account: a, now: 3000))
    }
    func testUsageParserPreservesResetInstantsAndUnknownPercentages() throws {
        let windows = try UsageParser.parse(usageData(103))
        XCTAssertEqual(windows[0].utilization, 103)
        XCTAssertEqual(try XCTUnwrap(windows[0].resetsAt), 1793301600.333497, accuracy: 0.001)
        XCTAssertEqual(windows[1].resetsAt, 1793354400)
        let unknown = try UsageParser.parse(jsonData(["five_hour": ["utilization": NSNull(), "resets_at": "2026-10-29T19:20:00Z"]]))
        XCTAssertNil(unknown[0].utilization)
        XCTAssertThrowsError(try UsageParser.parse(jsonData(["five_hour": NSNull(), "seven_day": NSNull()])))
        XCTAssertThrowsError(try UsageParser.parse(jsonData(["five_hour": ["utilization": true]])))
    }
    func testUsageParserAcceptsDynamicWindowsWithoutDoubleCounting() throws {
        let data: [String: Any] = ["seven_day_opus": ["utilization": 4], "limits": [
            ["kind": "session", "percent": 3, "resets_at": 1793301600],
            ["kind": "weekly_all", "percent": 10],
            ["kind": "weekly_scoped", "percent": 4, "scope": ["model": ["display_name": "Opus"]]],
            ["kind": "weekly_scoped", "percent": 5, "scope": ["model": ["display_name": "New model"]]]
        ]]
        let windows = try UsageParser.parse(jsonData(data))
        XCTAssertEqual(windows.count, 4)
        XCTAssertEqual(windows.filter { $0.label == "每周 · Opus" }.count, 1)
    }
    func testMultipleOfficialUsageIsIndependentAndKeepsLastGoodOnFailure() async throws {
        try usageRegistry()
        let first = try await engine.refreshUsage(credential: { UsageCredential(token: $0, plan: "pro") }, fetch: { try self.usageData($0 == self.a ? 3 : 7) })
        XCTAssertEqual(first.added, 2)
        let before = try engine.officialUsage()
        XCTAssertEqual(before.map { $0.windows[0].utilization }, [3, 7])
        let second = try await engine.refreshUsage(credential: { account in
            if account == self.a { throw SyncError("登录已过期") }
            return UsageCredential(token: "dummy-private-token", plan: "max")
        }, fetch: { _ in try self.usageData(9) })
        XCTAssertEqual(second.added, 1)
        let after = try engine.officialUsage()
        XCTAssertEqual(after.map { $0.windows[0].utilization }, [3, 9])
        XCTAssertEqual(after[0].fetchedAt, before[0].fetchedAt)
        XCTAssertEqual(after[0].error, "登录已过期")
        XCTAssertNil(after[1].error)
        let cache = try String(contentsOf: engine.usageCache)
        XCTAssertFalse(cache.contains("dummy-private-token"))
        XCTAssertEqual(process.stops, 0)
        XCTAssertEqual(try engine.mode(), "3p")
    }
    func testUsageErrorsNeverCacheArbitraryErrorDescriptions() async throws {
        try usageRegistry()
        _ = try await engine.refreshUsage(credential: { _ in UsageCredential(token: "secret", plan: nil) }, fetch: { _ in
            throw NSError(domain: "network", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bearer secret"])
        })
        XCTAssertFalse(try String(contentsOf: engine.usageCache).contains("secret"))
        XCTAssertTrue(try engine.officialUsage().allSatisfy { $0.windows.isEmpty && $0.fetchedAt == nil && $0.error != nil })
    }
    func testUsageSnapshotIdentityIsValidatedBeforeCredentialAccess() throws {
        _ = try engine.switchProfile(id: "official"); try login(a, token: "A")
        _ = try engine.saveAccount(name: "A"); try login(b, token: "B")
        let entry = try XCTUnwrap(engine.accounts().first), id = entry["id"] as! String, snapshot = entry["snapshot"] as! String
        try atomicJSON(["lastKnownAccountUuid": b], engine.state.appendingPathComponent("accounts/\(id)/\(snapshot)/config.json"))
        XCTAssertThrowsError(try engine.usageCredential(a)) { error in XCTAssertTrue(error.localizedDescription.contains("校验失败")) }
    }
}
