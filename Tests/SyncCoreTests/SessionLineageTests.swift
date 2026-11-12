import XCTest
@testable import SyncCore

extension CoreTests {
    @discardableResult
    func lineageFixture(_ directory: URL, id: String, parent: String? = nil,
                        spawned: Bool = false, time: Double = 100, extra: [String: Any] = [:]) throws -> URL {
        let file = try fixture(directory, id: id, time: time)
        var record = try readJSON(file)
        if let parent {
            if spawned {
                record["spawnedFrom"] = ["sessionId": "local_" + parent, "taskId": "task-" + id,
                    "title": "Parent task", "name": "child", "sideSession": true, "wakeParent": true,
                    "sharedCheckout": true, "sharedFolder": true, "approvedPermissions": ["source-only"]] as [String: Any]
            } else {
                record["forkedFromSessionId"] = "local_" + parent
                record["forkedAtMessageUuid"] = org
            }
        }
        record.merge(extra) { _, new in new }; try atomicJSON(record, file)
        return file
    }

    func testLineageRecursiveTreeSurvivesMultiWorkspaceImportAndRepeatedSync() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        let team = try workspace("Claude", b, gateway)
        try selectOfficial(b)
        let files = try [lineageFixture(source, id: sid), lineageFixture(source, id: a, parent: sid),
                         lineageFixture(source, id: b, parent: a, spawned: true),
                         lineageFixture(source, id: gateway, parent: b)]
        let before = try files.map { try Data(contentsOf: $0) }
        XCTAssertEqual(try engine.sync().added, 8)
        for destination in [target, team] {
            let fork = try readJSON(destination.appendingPathComponent("local_\(a).json"))
            let child = try readJSON(destination.appendingPathComponent("local_\(b).json"))
            let grandchild = try readJSON(destination.appendingPathComponent("local_\(gateway).json"))
            XCTAssertEqual(fork["forkedFromSessionId"] as? String, "local_" + sid)
            XCTAssertEqual(fork["forkedAtMessageUuid"] as? String, org)
            let link = try XCTUnwrap(child["spawnedFrom"] as? [String: Any])
            XCTAssertEqual(link["sessionId"] as? String, "local_" + a)
            XCTAssertEqual(link["sideSession"] as? Bool, true)
            for key in ["wakeParent", "sharedCheckout", "sharedFolder", "approvedPermissions"] { XCTAssertNil(link[key]) }
            XCTAssertEqual(grandchild["forkedFromSessionId"] as? String, "local_" + b)
            XCTAssertEqual(child["permissionMode"] as? String, "default")
            XCTAssertNil(child["remoteMcpServersConfig"])
        }
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
        let imported = try [target, team].map { try digestTree($0) }
        XCTAssertEqual(try engine.sync().added, 0)
        XCTAssertEqual(try [target, team].map { try digestTree($0) }, imported)
    }

    func testLineageRepairsLegacyImportWithoutChangingTitlePermissionsOrTaskAssociation() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        _ = try lineageFixture(source, id: sid)
        _ = try lineageFixture(source, id: a, parent: sid, spawned: true, extra: ["scheduledTaskId": "daily-review"])
        let file = try lineageFixture(target, id: a, time: 200, extra: ["title": "Target title", "effort": "high"])
        let original = try readJSON(file)
        let result = try engine.sync(), repaired = try readJSON(file)
        XCTAssertEqual(result.added, 1)
        XCTAssertTrue(result.message.contains("修复 1 份会话树关联"))
        XCTAssertEqual((repaired["spawnedFrom"] as? [String: Any])?["sessionId"] as? String, "local_" + sid)
        XCTAssertEqual(repaired["scheduledTaskId"] as? String, "daily-review")
        for key in ["title", "effort", "permissionMode", "remoteMcpServersConfig", "alwaysAllowedReasons"] {
            XCTAssertEqual(try jsonData([key: repaired[key] as Any]), try jsonData([key: original[key] as Any]))
        }
    }

    func testLineageRecoversFromArchiveWhenNewerIndexAndAllLiveCopiesLostLinks() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try lineageFixture(source, id: sid)
        let child = try lineageFixture(source, id: a, parent: sid)
        _ = try engine.archive(); try fm.removeItem(at: child)
        let legacy = try lineageFixture(target, id: a, time: 300, extra: ["title": "Continued after switching"])
        _ = try engine.archive()
        let index = try readJSON(engine.history.vault.appendingPathComponent("index.json"))
        let hash = try XCTUnwrap((index["local_" + a] as? [String: Any])?["hash"] as? String)
        XCTAssertNil(try readJSON(engine.history.vault.appendingPathComponent("records/local_\(a)/\(hash).json"))["forkedFromSessionId"])
        _ = try engine.sync()
        XCTAssertEqual(try readJSON(legacy)["forkedFromSessionId"] as? String, "local_" + sid)
        XCTAssertEqual(try readJSON(legacy)["title"] as? String, "Continued after switching")
    }

    func testLineagePreservesExistingDetachAndParentChoice() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        _ = try lineageFixture(source, id: sid); _ = try lineageFixture(source, id: gateway)
        _ = try lineageFixture(source, id: a, parent: sid)
        _ = try lineageFixture(source, id: b, parent: sid)
        let detached = try lineageFixture(target, id: a, extra: ["lineageDetached": true])
        let moved = try lineageFixture(target, id: b, parent: gateway)
        let before = try [detached, moved].map { try Data(contentsOf: $0) }
        _ = try engine.sync()
        XCTAssertEqual(try [detached, moved].map { try Data(contentsOf: $0) }, before)
    }

    func testLineageFreshImportKeepsDetachAndForkKindWithoutAutomaticWakeups() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try lineageFixture(source, id: sid)
        _ = try lineageFixture(source, id: a, parent: sid, spawned: true,
                               extra: ["lineageDetached": true, "forkedFromSessionId": "local_" + sid, "forkedAtMessageUuid": org])
        _ = try engine.sync()
        let value = try readJSON(target.appendingPathComponent("local_\(a).json"))
        XCTAssertEqual(value["lineageDetached"] as? Bool, true)
        XCTAssertEqual(value["forkedFromSessionId"] as? String, "local_" + sid)
        XCTAssertEqual((value["spawnedFrom"] as? [String: Any])?["sessionId"] as? String, "local_" + sid)
        XCTAssertNil((value["spawnedFrom"] as? [String: Any])?["wakeParent"])
    }

    func testLineageCurrentDetachWinsOverTiedArchivedAttachedVersion() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try lineageFixture(source, id: sid)
        let child = try lineageFixture(source, id: a, parent: sid)
        _ = try engine.archive()
        var value = try readJSON(child); value["lineageDetached"] = true; try atomicJSON(value, child)
        _ = try engine.sync()
        XCTAssertEqual(try readJSON(target.appendingPathComponent("local_\(a).json"))["lineageDetached"] as? Bool, true)
    }

    func testLineageDoesNotBorrowRelationshipFromDifferentCLIConversation() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try lineageFixture(source, id: sid)
        _ = try lineageFixture(source, id: a, parent: sid)
        _ = try fixture(target, id: b)
        let other = try lineageFixture(target, id: a, time: 200, extra: ["cliSessionId": b])
        let before = try Data(contentsOf: other)
        _ = try engine.sync()
        XCTAssertEqual(try Data(contentsOf: other), before)
    }

    func testLineageDoesNotRepairRemoteTargetWithMatchingLocalIDs() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try lineageFixture(source, id: sid)
        _ = try lineageFixture(source, id: a, parent: sid)
        let remote = try lineageFixture(target, id: a, extra: ["sshHost": "fixture-host"])
        let before = try Data(contentsOf: remote)
        _ = try engine.sync()
        XCTAssertEqual(try Data(contentsOf: remote), before)
    }

    func testLineageCurrentDetachWinsOverNewerArchivedConversation() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try lineageFixture(source, id: sid)
        _ = try lineageFixture(source, id: a, parent: sid, time: 300)
        _ = try engine.archive()
        _ = try lineageFixture(source, id: a, time: 100, extra: ["lineageDetached": true])
        _ = try engine.sync()
        let copy = try readJSON(target.appendingPathComponent("local_\(a).json"))
        XCTAssertEqual(copy["lineageDetached"] as? Bool, true)
        XCTAssertNil(copy["forkedFromSessionId"])
    }

    func testLineageForkKindsAndDeletedParentSurviveOfficialAccountRoundTrip() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(a); _ = try engine.saveAccount(name: "A")
        let aid = try XCTUnwrap(engine.accounts().first?["id"] as? String)
        try selectOfficial(b); _ = try engine.saveAccount(name: "B")
        let bid = try XCTUnwrap(engine.accounts().first { $0["account"] as? String == b }?["id"] as? String)
        _ = try engine.switchProfile(id: aid)
        _ = try lineageFixture(source, id: sid)
        let link: [String: Any] = ["sessionId": "local_" + sid, "name": "", "title": "", "taskId": "task",
            "sideSession": true, "userFork": true, "handOff": true, "btw": true,
            "deletedParent": ["sessionId": "local_" + gateway, "title": ""]]
        _ = try lineageFixture(source, id: a, parent: sid, extra: ["spawnedFrom": link])
        XCTAssertEqual(try engine.switchProfile(id: bid).added, 2)
        let file = target.appendingPathComponent("local_\(a).json"), copy = try readJSON(file)
        XCTAssertEqual(try jsonData(copy["spawnedFrom"] as Any), try jsonData(link))
        XCTAssertEqual(copy["forkedFromSessionId"] as? String, "local_" + sid)
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try engine.switchProfile(id: aid).added, 0)
        XCTAssertEqual(try engine.switchProfile(id: bid).added, 0)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testLineageAmbiguousSourceWorkspacesRollbackWithoutOverwritingEitherSide() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        let team = try workspace("Claude", b, gateway)
        try selectOfficial(b)
        _ = try lineageFixture(source, id: sid); _ = try lineageFixture(source, id: gateway)
        _ = try lineageFixture(source, id: a, parent: sid)
        _ = try lineageFixture(target, id: a, parent: gateway)
        _ = try lineageFixture(team, id: a, parent: sid)
        let before = try [source, target, team].map { try digestTree($0) }
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try [source, target, team].map { try digestTree($0) }, before)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
        XCTAssertTrue(process.running)
    }

    func testLineageCycleRollsBackTheWholeImport() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        _ = try lineageFixture(source, id: sid, parent: a)
        _ = try lineageFixture(source, id: a, parent: sid)
        let before = try digestTree(target)
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try digestTree(target), before)
        XCTAssertTrue(process.running)
    }

    func testLineageDeletedParentIsNotReimportedToRepairChild() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        _ = try lineageFixture(source, id: sid); _ = try lineageFixture(source, id: a, parent: sid)
        _ = try deletionMarker(source, id: sid)
        _ = try engine.sync()
        XCTAssertFalse(exists(target.appendingPathComponent("local_\(sid).json")))
        XCTAssertTrue(exists(target.appendingPathComponent("local_\(a).json")))
        XCTAssertEqual(try readJSON(target.appendingPathComponent("local_\(a).json"))["forkedFromSessionId"] as? String, "local_" + sid)
        XCTAssertTrue(exists(root.appendingPathComponent(".claude/projects/-fixture/\(sid).jsonl")))
    }

    func testLineageTamperedArchiveCannotRepairLegacyCopy() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try lineageFixture(source, id: sid)
        let original = try lineageFixture(source, id: a, parent: sid)
        _ = try engine.archive(); try fm.removeItem(at: original)
        let legacy = try lineageFixture(target, id: a, time: 200)
        let before = try Data(contentsOf: legacy)
        let folder = engine.history.vault.appendingPathComponent("records/local_" + a)
        let archived = try XCTUnwrap(fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        var value = try readJSON(archived); value["forkedFromSessionId"] = "local_" + gateway; try atomicJSON(value, archived)
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try Data(contentsOf: legacy), before)
    }

    func testLineageInvalidAndRemoteParentFieldsAreRejected() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b)
        _ = try lineageFixture(source, id: a, extra: ["spawnedFrom": ["sessionId": "remote-session", "sideSession": true]])
        XCTAssertThrowsError(try engine.sync())
        _ = try lineageFixture(source, id: a, extra: ["forkedFromSessionId": "local_" + a])
        XCTAssertThrowsError(try engine.sync())
        _ = try lineageFixture(source, id: a, parent: sid, extra: ["lineageDetached": 1])
        XCTAssertThrowsError(try engine.sync())
        XCTAssertFalse(exists(target.appendingPathComponent("local_\(a).json")))
    }

    func testLineagePartialRepairRecoversAfterInterruptedWrite() throws {
        let source = try owner("Claude-3p", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try lineageFixture(source, id: sid)
        _ = try lineageFixture(source, id: a, parent: sid)
        let legacy = try lineageFixture(target, id: a, time: 200)
        let before = try Data(contentsOf: legacy)
        _ = try engine.archive()
        let tx = try Transaction(root: engine.state, operation: "interrupted lineage repair")
        tx.beforeWrite = {
            if try readJSON(legacy)["forkedFromSessionId"] != nil { throw SyncError("injected interruption after link repair") }
        }
        XCTAssertThrowsError(try engine.history.merge(into: engine.syncTargets(), transaction: tx))
        XCTAssertNotNil(try readJSON(legacy)["forkedFromSessionId"])
        try Transaction.recover(root: engine.state)
        XCTAssertEqual(try Data(contentsOf: legacy), before)
        XCTAssertFalse(exists(target.appendingPathComponent("local_\(sid).json")))
    }
}
