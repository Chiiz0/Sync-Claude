import XCTest
@testable import SyncCore

extension CoreTests {
    func testVerifiedBuildsUseTheSameStatusAndWriteGate() throws {
        for version in DesktopCompatibility.verifiedVersions {
            let candidate = Engine(home: root, process: process, version: version)
            XCTAssertTrue(try candidate.status().compatible, version)
            _ = try candidate.switchProfile(id: gateway)
            XCTAssertEqual(try candidate.mode(), "3p", version)
        }
    }

    func testUnknownBuildsRefuseWritesAndCredentialAccess() async throws {
        let before = try Data(contentsOf: engine.library.appendingPathComponent("_meta.json"))
        for version in ["4.4212.1", "4.4213.0", "4.30.0", "4.4212", "未安装"] {
            let candidate = Engine(home: root, process: process, version: version)
            XCTAssertFalse(try candidate.status().compatible, version)
            XCTAssertThrowsError(try candidate.switchProfile(id: "official"), version)
            do {
                _ = try await candidate.refreshUsage(credential: { _ in
                    XCTFail("Unsupported build must not read credentials")
                    throw SyncError("unexpected credential access")
                }, fetch: { _ in
                    XCTFail("Unsupported build must not request usage")
                    return Data()
                })
                XCTFail("Unsupported build must reject usage refresh")
            } catch {}
            XCTAssertNoThrow(try candidate.archive(), version)
        }
        XCTAssertEqual(process.stops, 0)
        XCTAssertEqual(try Data(contentsOf: engine.library.appendingPathComponent("_meta.json")), before)
    }
}
