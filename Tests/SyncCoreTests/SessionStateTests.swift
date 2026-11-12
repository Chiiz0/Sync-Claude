import XCTest
@testable import SyncCore

// Cross-account regressions use isolated homes and a fake Claude process.
extension CoreTests {
    private func auditAccounts() throws -> (source: URL, target: URL, sourceID: String, targetID: String) {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(a)
        _ = try engine.saveAccount(name: "Audit A")
        let sourceID = try XCTUnwrap(engine.accounts().first { $0["account"] as? String == a }?["id"] as? String)
        try selectOfficial(b)
        _ = try engine.saveAccount(name: "Audit B")
        let targetID = try XCTUnwrap(engine.accounts().first { $0["account"] as? String == b }?["id"] as? String)
        _ = try engine.switchProfile(id: sourceID)
        return (source, target, sourceID, targetID)
    }

    private func auditChange(_ file: URL, _ fields: [String: Any]) throws {
        var value = try readJSON(file)
        value.merge(fields) { _, new in new }
        try atomicJSON(value, file)
    }

    func testAuditArchiveShouldReachExistingAccountCopy() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        try auditChange(source, ["isArchived": false])
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        // A completed user action, after both accounts already received the session.
        try auditChange(source, ["isArchived": true, "lastActivityAt": 200])
        let result = try engine.switchProfile(id: pair.targetID)
        XCTAssertTrue(result.message.contains("切换配置完成"))
        let target = try readJSON(pair.target.appendingPathComponent(source.lastPathComponent))
        XCTAssertEqual(target["isArchived"] as? Bool, true, "Existing B copy should reflect A's archive action")
    }

    func testAuditUnarchiveShouldReachExistingAccountCopy() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        try auditChange(source, ["isArchived": true])
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        try auditChange(source, ["isArchived": false, "lastActivityAt": 200])
        _ = try engine.switchProfile(id: pair.targetID)
        let target = try readJSON(pair.target.appendingPathComponent(source.lastPathComponent))
        XCTAssertEqual(target["isArchived"] as? Bool, false, "Simply OR-ing archived flags would also be wrong")
    }

    func testAuditVerifiedContinuationShouldAdvanceExistingPointer() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        // Same desktop session; a newer CLI transcript explicitly lists the old one.
        try atomicData(Data("{\"type\":\"assistant\",\"message\":\"new transcript\"}\n".utf8),
                       root.appendingPathComponent(".claude/projects/-fixture/\(gateway).jsonl"))
        try auditChange(source, ["cliSessionId": gateway, "priorCliSessionIds": [sid], "lastActivityAt": 200])
        let result = try engine.switchProfile(id: pair.targetID)
        XCTAssertTrue(result.message.contains("切换配置完成"))
        XCTAssertEqual(try transcriptSnapshots(gateway).count, 1, "Backup succeeds even when resume state is stale")
        let target = try readJSON(pair.target.appendingPathComponent(source.lastPathComponent))
        XCTAssertEqual(target["cliSessionId"] as? String, gateway, "B must resume the verified continuation")
        XCTAssertEqual(target["priorCliSessionIds"] as? [String], [sid], "B must retain the history chain")
    }

    func testAuditMoveToTopLevelShouldReachExistingChildCopy() throws {
        let pair = try auditAccounts()
        _ = try lineageFixture(pair.source, id: sid)
        let child = try lineageFixture(pair.source, id: gateway, parent: sid, spawned: true)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        try auditChange(child, ["lineageDetached": true, "lastActivityAt": 200])
        _ = try engine.switchProfile(id: pair.targetID)
        let target = try readJSON(pair.target.appendingPathComponent(child.lastPathComponent))
        XCTAssertNil(SessionLineage.parent(of: target), "Moving a child to the top level should survive switching")
    }

    func testAuditMetadataEditWithoutNewMessageShouldBecomeCurrentSnapshot() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        try auditChange(source, ["isArchived": false])
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        // Archiving does not require a new chat message or a lastActivityAt change.
        try auditChange(source, ["isArchived": true])
        _ = try engine.archive()
        let index = try readJSON(engine.history.vault.appendingPathComponent("index.json"))
        let entry = try XCTUnwrap(index["local_" + sid] as? [String: Any])
        let hash = try XCTUnwrap(entry["hash"] as? String)
        let snapshot = try readJSON(engine.history.vault.appendingPathComponent("records/local_\(sid)/\(hash).json"))
        XCTAssertEqual(snapshot["isArchived"] as? Bool, true, "Later directory ordering must not replace a user edit with a stale copy")
    }

    func testAuditControlNewImportCopiesArchiveAndTopLevelState() throws {
        let pair = try auditAccounts()
        _ = try lineageFixture(pair.source, id: sid)
        let child = try lineageFixture(pair.source, id: gateway, parent: sid, spawned: true,
                                       extra: ["isArchived": true, "lineageDetached": true])
        _ = try engine.switchProfile(id: pair.targetID)
        let target = try readJSON(pair.target.appendingPathComponent(child.lastPathComponent))
        XCTAssertEqual(target["isArchived"] as? Bool, true)
        XCTAssertNil(SessionLineage.parent(of: target))
    }

    func testAuditControlUnrelatedTranscriptMustNotReplaceTarget() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        let target = pair.target.appendingPathComponent(source.lastPathComponent)
        let before = try Data(contentsOf: target)
        try atomicData(Data("{\"type\":\"user\",\"message\":\"unrelated\"}\n".utf8),
                       root.appendingPathComponent(".claude/projects/-fixture/\(gateway).jsonl"))
        try auditChange(source, ["cliSessionId": gateway, "lastActivityAt": 200])
        _ = try engine.switchProfile(id: pair.targetID)
        XCTAssertEqual(try Data(contentsOf: target), before, "No continuation proof: keep the independent conversation")
    }

    func testSharedStateMergesIndependentFieldsWithoutUsingChatTimestamp() throws {
        let pair = try auditAccounts()
        _ = try lineageFixture(pair.source, id: sid)
        let source = try lineageFixture(pair.source, id: gateway, parent: sid, spawned: true)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        let target = pair.target.appendingPathComponent(source.lastPathComponent)
        try auditChange(source, ["isArchived": true])
        try auditChange(target, ["lineageDetached": true])
        _ = try engine.switchProfile(id: pair.targetID)
        let copy = try readJSON(target)
        XCTAssertEqual(copy["isArchived"] as? Bool, true)
        XCTAssertEqual(copy["lineageDetached"] as? Bool, true)
        _ = try engine.switchProfile(id: pair.sourceID)
        XCTAssertEqual(try readJSON(source)["lineageDetached"] as? Bool, true)
        XCTAssertEqual(try readJSON(source)["lastActivityAt"] as? Double, 100)
    }

    func testConflictingRelationshipEditsRollbackCopiesAndBaseline() throws {
        let pair = try auditAccounts()
        _ = try lineageFixture(pair.source, id: sid)
        let source = try lineageFixture(pair.source, id: gateway, parent: sid)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        let target = pair.target.appendingPathComponent(source.lastPathComponent)
        try auditChange(source, ["lineageDetached": true])
        try auditChange(target, ["forkedFromSessionId": "local_" + org])
        let before = try [source, target, engine.history.sessionStateFile].map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try engine.switchProfile(id: pair.targetID))
        XCTAssertEqual(try [source, target, engine.history.sessionStateFile].map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try engine.accountID(), a)
        XCTAssertFalse(engine.hasPendingOperation)
    }

    func testRestoredUntrackedCopyDoesNotUndoCanonicalState() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        try auditChange(source, ["isArchived": true])
        _ = try engine.switchProfile(id: pair.targetID)
        let newWorkspace = try workspace("Claude", b, gateway)
        _ = try fixture(newWorkspace, time: 999)
        _ = try engine.sync()
        XCTAssertEqual(try readJSON(newWorkspace.appendingPathComponent(source.lastPathComponent))["isArchived"] as? Bool, true)
    }

    func testContinuationDoesNotRegressWhenAncestorHasNewerActivity() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        let target = pair.target.appendingPathComponent(source.lastPathComponent)
        try atomicData(Data("{\"type\":\"assistant\"}\n".utf8), root.appendingPathComponent(".claude/projects/-fixture/\(gateway).jsonl"))
        try auditChange(source, ["cliSessionId": gateway, "priorCliSessionIds": [sid], "lastActivityAt": 200])
        try auditChange(target, ["lastActivityAt": 999, "title": "Local title", "model": "local-model", "permissionMode": "plan"])
        _ = try engine.switchProfile(id: pair.targetID)
        let copy = try readJSON(target)
        XCTAssertEqual(copy["cliSessionId"] as? String, gateway)
        XCTAssertEqual(copy["priorCliSessionIds"] as? [String], [sid])
        XCTAssertEqual(copy["title"] as? String, "Local title")
        XCTAssertEqual(copy["model"] as? String, "local-model")
        XCTAssertEqual(copy["permissionMode"] as? String, "plan")
        _ = try engine.switchProfile(id: pair.sourceID)
        XCTAssertEqual(try readJSON(source)["cliSessionId"] as? String, gateway)
    }

    func testContinuationMissingBodyRollsBackWithoutRetargeting() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        try auditChange(source, ["cliSessionId": gateway, "priorCliSessionIds": [sid], "lastActivityAt": 200])
        let target = pair.target.appendingPathComponent(source.lastPathComponent)
        let before = try Data(contentsOf: target)
        XCTAssertThrowsError(try engine.switchProfile(id: pair.targetID))
        XCTAssertEqual(try Data(contentsOf: target), before)
    }

    func testContinuationNewImportRejectsMissingAncestorBody() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        try auditChange(source, ["priorCliSessionIds": [gateway]])
        let before = try Data(contentsOf: source)
        XCTAssertThrowsError(try engine.switchProfile(id: pair.targetID))
        XCTAssertFalse(exists(pair.target.appendingPathComponent(source.lastPathComponent)))
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try engine.accountID(), a)
    }

    func testContinuationNewImportRejectsConflictingProjectPaths() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        let ancestorWorkspace = try owner("Claude-3p", a)
        let ancestor = try fixture(ancestorWorkspace)
        try auditChange(ancestor, ["cwd": root.appendingPathComponent("other-project").path])
        try atomicData(Data("{\"type\":\"assistant\"}\n".utf8),
                       root.appendingPathComponent(".claude/projects/-fixture/\(gateway).jsonl"))
        try auditChange(source, ["cliSessionId": gateway, "priorCliSessionIds": [sid], "lastActivityAt": 200])
        XCTAssertThrowsError(try engine.switchProfile(id: pair.targetID))
        XCTAssertFalse(exists(pair.target.appendingPathComponent(source.lastPathComponent)))
        XCTAssertEqual(try engine.accountID(), a)
    }

    func testContinuationSameTipRejectsAddingMissingHistory() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        try auditChange(source, ["priorCliSessionIds": [gateway]])
        let target = pair.target.appendingPathComponent(source.lastPathComponent)
        let before = try [target, engine.history.sessionStateFile].map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try engine.switchProfile(id: pair.targetID))
        XCTAssertEqual(try [target, engine.history.sessionStateFile].map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try engine.accountID(), a)
    }

    func testContinuationNewImportPreservesCompleteHistory() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        try atomicData(Data("{\"type\":\"assistant\"}\n".utf8),
                       root.appendingPathComponent(".claude/projects/-fixture/\(gateway).jsonl"))
        try auditChange(source, ["cliSessionId": gateway, "priorCliSessionIds": [sid]])
        _ = try engine.switchProfile(id: pair.targetID)
        let target = try readJSON(pair.target.appendingPathComponent(source.lastPathComponent))
        XCTAssertEqual(target["cliSessionId"] as? String, gateway)
        XCTAssertEqual(target["priorCliSessionIds"] as? [String], [sid])
        XCTAssertEqual(target["permissionMode"] as? String, "default")
    }

    func testTrackedTopLevelStateIgnoresConflictingUntrackedLineage() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        let oldA = try owner("Claude-3p", a), oldB = try owner("Claude-3p", b)
        _ = try lineageFixture(oldA, id: sid, parent: gateway, time: 999)
        _ = try lineageFixture(oldB, id: sid, parent: org, time: 999)
        _ = try engine.switchProfile(id: pair.sourceID)
        XCTAssertNil(SessionLineage.parent(of: try readJSON(source)))
        let ledger = try SessionStateLedger(readJSON(engine.history.sessionStateFile))
        XCTAssertTrue((ledger.entries["local_" + sid]?["lineage"] as? [String: Any])?.isEmpty == true)
    }

    func testInterruptedStateMergeRestoresWrittenCopiesAndBaseline() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        let target = pair.target.appendingPathComponent(source.lastPathComponent)
        let files = [target, engine.history.sessionStateFile]
        let before = try files.map { try Data(contentsOf: $0) }
        try auditChange(source, ["isArchived": true])
        _ = try engine.archive()
        let owners = try engine.history.owners()
        let sourceOwner = try XCTUnwrap(owners.first { $0.directory.path == pair.source.path })
        let targetOwner = try XCTUnwrap(owners.first { $0.directory.path == pair.target.path })
        let tx = try Transaction(root: engine.state, operation: "interrupted shared-state merge")
        _ = try engine.history.merge(from: [sourceOwner], into: [targetOwner], transaction: tx)
        XCTAssertEqual(try readJSON(target)["isArchived"] as? Bool, true)
        XCTAssertNotEqual(try Data(contentsOf: engine.history.sessionStateFile), before[1])
        try Transaction.recover(root: engine.state)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try readJSON(source)["isArchived"] as? Bool, true)
        XCTAssertFalse(engine.hasPendingOperation)
    }

    func testTrackedLineageNewWorkspaceRetainsPortableLabels() throws {
        let pair = try auditAccounts()
        _ = try lineageFixture(pair.source, id: sid)
        let child = try lineageFixture(pair.source, id: gateway, parent: sid, spawned: true)
        _ = try engine.switchProfile(id: pair.targetID)
        let team = try workspace("Claude", b, gateway)
        _ = try engine.sync()
        let target = try readJSON(team.appendingPathComponent(child.lastPathComponent))
        let link = try XCTUnwrap(target["spawnedFrom"] as? [String: Any])
        XCTAssertEqual(link["title"] as? String, "Parent task")
        XCTAssertEqual(link["name"] as? String, "child")
        XCTAssertNil(link["wakeParent"])
        XCTAssertNil(link["approvedPermissions"])
    }

    func testSessionPurgeRemovesSelectedStateAndRetainsOtherBaselines() throws {
        let pair = try auditAccounts()
        _ = try fixture(pair.source)
        _ = try fixture(pair.source, id: gateway)
        _ = try engine.switchProfile(id: pair.targetID)
        let before = try SessionStateLedger(readJSON(engine.history.sessionStateFile))
        _ = try deletionMarker(pair.target, id: sid)
        let preview = try engine.previewSessionPurge(ids: ["local_" + sid])
        _ = try engine.purgeDeletedSessions(preview)
        let after = try SessionStateLedger(readJSON(engine.history.sessionStateFile))
        XCTAssertNil(after.entries["local_" + sid])
        XCTAssertEqual(try jsonData(after.entries["local_" + gateway]!), try jsonData(before.entries["local_" + gateway]!))
        _ = try engine.sync()
        XCTAssertFalse(exists(pair.target.appendingPathComponent("local_\(sid).json")))
    }

    func testContinuationRejectsCyclesAndParallelDescendants() throws {
        func value(_ cli: String, prior: [String]) -> [String: Any] { ["cliSessionId": cli, "priorCliSessionIds": prior] }
        XCTAssertThrowsError(try SessionContinuation([value(a, prior: [b]), value(b, prior: [a])]))
        XCTAssertThrowsError(try SessionContinuation([value(a, prior: [a])]))
        let base = value(a, prior: [])
        let fork = try SessionContinuation([base, value(b, prior: [a]), value(gateway, prior: [a])])
        XCTAssertThrowsError(try fork.latest(from: base))
        XCTAssertThrowsError(try fork.latest(from: value(b, prior: [a])))
        let chain = try SessionContinuation([base, value(b, prior: [a]), value(gateway, prior: [b])])
        let tip = try chain.latest(from: base)
        XCTAssertEqual(tip["cliSessionId"] as? String, gateway)
        XCTAssertEqual(tip["priorCliSessionIds"] as? [String], [a, b])
    }

    func testDeletionRemovesStateBaselineAndDoesNotResurrectSession() throws {
        let pair = try auditAccounts()
        _ = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try deletionMarker(pair.target, id: sid)
        _ = try engine.sync()
        let ledger = try SessionStateLedger(readJSON(engine.history.sessionStateFile))
        XCTAssertNil(ledger.entries["local_" + sid])
        _ = try engine.switchProfile(id: pair.sourceID)
        XCTAssertFalse(exists(pair.source.appendingPathComponent("local_\(sid).json")))
    }

    func testCorruptStateBaselineRefusesWrites() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source)
        _ = try engine.switchProfile(id: pair.targetID)
        let target = pair.target.appendingPathComponent(source.lastPathComponent)
        let before = try Data(contentsOf: target)
        try atomicJSON(["version": 99, "sessions": [:]], engine.history.sessionStateFile)
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try Data(contentsOf: target), before)
    }

    func testRestorationOfTrackedDirectoryDoesNotBecomeNewUserEdit() throws {
        let pair = try auditAccounts()
        let source = try fixture(pair.source), original = try readJSON(source)
        _ = try engine.switchProfile(id: pair.targetID)
        _ = try engine.switchProfile(id: pair.sourceID)
        try auditChange(source, ["isArchived": true])
        _ = try engine.switchProfile(id: pair.targetID)
        let tx = try Transaction(root: engine.state, operation: "isolated directory restoration")
        try tx.write(original, to: source)
        try engine.history.noteRestoredState(ownerKey: "Claude/\(a)/\(org)", transaction: tx)
        try tx.commit()
        _ = try engine.switchProfile(id: pair.sourceID)
        XCTAssertEqual(try readJSON(source)["isArchived"] as? Bool, true)
    }
}
