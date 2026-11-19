#if os(Linux)
import XCTest
@testable import SyncCore

extension CoreTests {
    func testXDGPathsAndExplicitHomeIsolation() {
        XCTAssertEqual(LinuxDesktop.config(home: root, xdg: "/tmp/custom").path, "/tmp/custom")
        for invalid in [nil, "", "relative"] as [String?] {
            XCTAssertEqual(LinuxDesktop.config(home: root, xdg: invalid).path, root.path + "/.config")
        }
        XCTAssertEqual(engine.support.path, root.path + "/.config")
        XCTAssertEqual(engine.state.path, root.path + "/.config/SyncClaude")
    }

    func testProcessGuardDistinguishesDesktopWorkersFromStandaloneCLI() throws {
        let proc = root.appendingPathComponent("proc")
        let desktop = DesktopProcess(proc: proc, support: engine.support)
        func executable(_ pid: Int, _ path: String) throws {
            let directory = proc.appendingPathComponent(String(pid))
            try privateDir(directory)
            try fm.createSymbolicLink(atPath: directory.appendingPathComponent("exe").path, withDestinationPath: path)
        }
        try executable(121, "/usr/local/bin/claude")
        try desktop.stop(allowOpenSessions: false)
        try executable(122, engine.third.path + "/claude-code/1.0/claude")
        XCTAssertEqual(desktop.workers, 1)
        XCTAssertFalse(desktop.running)
        XCTAssertThrowsError(try desktop.stop(allowOpenSessions: false))
        try executable(123, LinuxDesktop.executable)
        XCTAssertTrue(desktop.running)
        // No Electron singleton lock identifies this process as safe to quit.
        XCTAssertThrowsError(try desktop.stop(allowOpenSessions: true))
    }

    func testDesktopWithoutExeBlocksWritesUntilItBecomesAZombie() throws {
        let proc = root.appendingPathComponent("proc")
        let pid = proc.appendingPathComponent("124")
        let desktop = DesktopProcess(proc: proc, support: engine.support)
        try atomicData(Data("claude-desktop\n".utf8), pid.appendingPathComponent("comm"))
        let stat = pid.appendingPathComponent("stat")
        try atomicData(Data("124 (claude-desktop) S 1".utf8), stat)
        XCTAssertTrue(desktop.running)
        XCTAssertEqual(desktop.workers, 0)
        XCTAssertThrowsError(try desktop.stop(allowOpenSessions: false))
        try atomicData(Data("124 (claude-desktop) Z 1".utf8), stat)
        XCTAssertFalse(desktop.running)
        try desktop.stop(allowOpenSessions: false)
    }

    func testProcessGuardFailsClosedWhenProcIsUnavailable() throws {
        let desktop = DesktopProcess(proc: root.appendingPathComponent("missing"), support: engine.support)
        XCTAssertTrue(desktop.running)
        XCTAssertThrowsError(try desktop.stop(allowOpenSessions: true))
    }
}
#endif
