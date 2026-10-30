import XCTest
@testable import SyncCore

final class UpdateTests: XCTestCase {
    func response(tag: String = "v0.1.3", draft: Bool = false, prerelease: Bool = false, page: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "name": tag, "body": "Release notes", "draft": draft, "prerelease": prerelease,
            "html_url": page ?? "https://github.com/Chiiz0/Sync-Claude/releases/tag/\(tag)"])
    }
    func testNumericVersionsAndNoDowngrades() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("0.1.10")), try XCTUnwrap(ReleaseVersion("v0.1.9")))
        XCTAssertEqual(ReleaseVersion("v1.2.3"), ReleaseVersion("1.2.3"))
        for text in ["1.2", "1.2.3-beta", "1.2.3/path", "01.2.3", "latest", "99999999999999999999999.0.0"] { XCTAssertNil(ReleaseVersion(text)) }
        let release = try XCTUnwrap(UpdateChecker.parse(data: response(), statusCode: 200))
        XCTAssertTrue(release.isNewer(than: "0.1.2"))
        XCTAssertFalse(release.isNewer(than: "0.1.3"))
        XCTAssertFalse(release.isNewer(than: "0.2.0"))
    }
    func testOnlyPublishedStableReleasesAndTrustedLinks() throws {
        XCTAssertNil(try UpdateChecker.parse(data: response(draft: true), statusCode: 200))
        XCTAssertNil(try UpdateChecker.parse(data: response(prerelease: true), statusCode: 200))
        for page in ["http://github.com/Chiiz0/Sync-Claude/releases/tag/v0.1.3", "https://github.com.attacker.test/Chiiz0/Sync-Claude/releases/tag/v0.1.3", "https://github.com/other/repo/releases/tag/v0.1.3", "https://github.com/Chiiz0/Sync-Claude/releases/tag/v0.1.3?redirect=1"] {
            XCTAssertThrowsError(try UpdateChecker.parse(data: response(page: page), statusCode: 200))
        }
        XCTAssertThrowsError(try UpdateChecker.parse(data: response(tag: "v0.1.3-beta"), statusCode: 200))
    }
    func testFailuresNeverBecomeUpToDateResults() throws {
        for code in [403, 429, 500] { XCTAssertThrowsError(try UpdateChecker.parse(data: Data(), statusCode: code)) }
        XCTAssertThrowsError(try UpdateChecker.parse(data: Data("{}".utf8), statusCode: 200))
        XCTAssertNil(try UpdateChecker.parse(data: Data(), statusCode: 404))
    }
    func testAutomaticScheduleSurvivesRestartsAndBacksOffFailures() {
        let now = Date()
        XCTAssertTrue(UpdateChecker.shouldCheck(now: now, lastAttempt: nil, lastSuccess: nil))
        XCTAssertFalse(UpdateChecker.shouldCheck(now: now, lastAttempt: now.addingTimeInterval(-10), lastSuccess: nil))
        XCTAssertFalse(UpdateChecker.shouldCheck(now: now, lastAttempt: nil, lastSuccess: now.addingTimeInterval(-86399)))
        XCTAssertTrue(UpdateChecker.shouldCheck(now: now, lastAttempt: now.addingTimeInterval(-3601), lastSuccess: now.addingTimeInterval(-86401)))
        XCTAssertTrue(UpdateChecker.shouldCheck(now: now, lastAttempt: now.addingTimeInterval(3600), lastSuccess: now.addingTimeInterval(3600)))
    }
}
