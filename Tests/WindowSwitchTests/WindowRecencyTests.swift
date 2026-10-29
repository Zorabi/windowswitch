// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import XCTest
@testable import WindowSwitch

final class WindowRecencyTests: XCTestCase {
    func testReopenEntryInheritsClosedMainWindowPosition() {
        var history = WindowRecency()
        let mainDate = Date(timeIntervalSince1970: 100)
        history.recordWindow(key: "main", pid: 1, isPrimary: true, at: mainDate)
        history.recordWindow(key: "browser", pid: 2, isPrimary: false, at: mainDate.addingTimeInterval(5))
        history.retain(windowKeys: ["app:1", "browser"], pids: [1, 2])
        let reopened = history.date(key: "app:1", pid: 1, isApplication: true, prefersPrimary: true)
        XCTAssertEqual(reopened, mainDate)
        XCTAssertLessThan(reopened, history.date(key: "browser", pid: 2, isApplication: false, prefersPrimary: false))
        XCTAssertGreaterThan(reopened, .distantPast)
    }

    func testMiniProgramDoesNotOverwriteMainWindowRecency() {
        var history = WindowRecency()
        let mainDate = Date(timeIntervalSince1970: 100)
        history.recordWindow(key: "main", pid: 1, isPrimary: true, at: mainDate)
        history.recordWindow(key: "mini", pid: 1, isPrimary: false, at: mainDate.addingTimeInterval(10))
        XCTAssertEqual(history.date(key: "app:1", pid: 1, isApplication: true, prefersPrimary: true), mainDate)
    }

    func testRestoredMainWithNewWindowIDKeepsItsRecentUse() {
        var history = WindowRecency()
        let date = Date(timeIntervalSince1970: 200)
        history.recordWindow(key: "app:1", pid: 1, isPrimary: true, at: date)
        XCTAssertEqual(history.date(key: "new-main-id", pid: 1, isApplication: false, prefersPrimary: true), date)
    }

    func testExitedProcessDoesNotLeakRecencyToReusedPID() {
        var history = WindowRecency()
        history.recordWindow(key: "main", pid: 1, isPrimary: true, at: Date())
        history.retain(windowKeys: [], pids: [])
        XCTAssertEqual(history.date(key: "app:1", pid: 1, isApplication: true, prefersPrimary: true), .distantPast)
    }
}
