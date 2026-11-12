// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import XCTest
@testable import WindowSwitch

final class WindowRecencyTests: XCTestCase {
    func testSingleWindowKeepsRecentApplicationUseWhenWindowFocusIsMissing() {
        var history = WindowRecency()
        let oldUse = Date(timeIntervalSince1970: 100)
        let closedAt = oldUse.addingTimeInterval(20)
        history.recordWindow(key: "rednote-old", pid: 1, isPrimary: false, at: oldUse)
        history.recordWindow(key: "browser", pid: 2, isPrimary: false, at: oldUse.addingTimeInterval(10))
        history.recordApplication(pid: 1, at: closedAt)
        history.retain(windowKeys: ["rednote-new", "browser"], pids: [1, 2])
        let recent = history.date(key: "rednote-new", pid: 1, isApplication: false, prefersPrimary: false, isOnlyWindow: true)
        XCTAssertEqual(recent, closedAt)
        XCTAssertGreaterThan(recent, history.date(key: "browser", pid: 2, isApplication: false, prefersPrimary: false))
    }

    func testApplicationActivationDoesNotPromoteEveryWindowOrClosedPrimary() {
        var history = WindowRecency()
        let oldUse = Date(timeIntervalSince1970: 100)
        history.recordWindow(key: "old", pid: 1, isPrimary: true, at: oldUse)
        history.recordWindow(key: "new", pid: 1, isPrimary: false, at: oldUse.addingTimeInterval(10))
        history.recordApplication(pid: 1, at: oldUse.addingTimeInterval(20))
        XCTAssertEqual(history.date(key: "old", pid: 1, isApplication: false, prefersPrimary: false), oldUse)
        XCTAssertEqual(history.date(key: "old", pid: 1, isApplication: false, prefersPrimary: true), oldUse)
        XCTAssertEqual(history.date(key: "app:1", pid: 1, isApplication: true, prefersPrimary: true, isOnlyWindow: true), oldUse)
    }

    func testMixedSingleWindowApplicationsFollowActualActivationOrder() {
        var history = WindowRecency()
        let oldUse = Date(timeIntervalSince1970: 100)
        history.recordWindow(key: "wechat", pid: 1, isPrimary: true, at: oldUse)
        history.recordWindow(key: "rednote", pid: 2, isPrimary: false, at: oldUse)
        history.recordWindow(key: "browser", pid: 3, isPrimary: false, at: oldUse)
        // Focus notifications can be missed; all three live singleton windows
        // must still agree with the actual application activation sequence.
        history.recordApplication(pid: 2, at: oldUse.addingTimeInterval(10))
        history.recordApplication(pid: 1, at: oldUse.addingTimeInterval(20))
        history.recordApplication(pid: 3, at: oldUse.addingTimeInterval(30))
        let windows: [(key: String, pid: pid_t, primary: Bool)] = [
            ("wechat", 1, true), ("rednote", 2, false), ("browser", 3, false)
        ]
        let ordered = windows.sorted {
            history.date(key: $0.key, pid: $0.pid, isApplication: false, prefersPrimary: $0.primary, isOnlyWindow: true) >
            history.date(key: $1.key, pid: $1.pid, isApplication: false, prefersPrimary: $1.primary, isOnlyWindow: true)
        }
        XCTAssertEqual(ordered.map(\.key), ["browser", "wechat", "rednote"])
    }

    func testClosedPrimaryKeepsApplicationUseWhenCloseFocusNotificationIsMissing() {
        var history = WindowRecency()
        let firstUse = Date(timeIntervalSince1970: 100)
        let closeUse = firstUse.addingTimeInterval(20)
        history.recordWindow(key: "main", pid: 1, isPrimary: true, at: firstUse)
        history.recordApplication(pid: 1, at: closeUse)
        history.retain(windowKeys: ["app:1"], pids: [1])
        XCTAssertEqual(history.date(key: "app:1", pid: 1, isApplication: true, prefersPrimary: true), closeUse)
        // A late old notification must not change the most recently used window.
        history.recordWindow(key: "chat", pid: 1, isPrimary: false, at: firstUse.addingTimeInterval(-1))
        XCTAssertEqual(history.date(key: "app:1", pid: 1, isApplication: true, prefersPrimary: true), closeUse)
    }

    func testOtherWindowApplicationUseDoesNotPromoteClosedPrimary() {
        var history = WindowRecency()
        let firstUse = Date(timeIntervalSince1970: 100)
        history.recordWindow(key: "main", pid: 1, isPrimary: true, at: firstUse)
        history.recordWindow(key: "mini", pid: 1, isPrimary: false, at: firstUse.addingTimeInterval(10))
        history.recordApplication(pid: 1, at: firstUse.addingTimeInterval(20))
        history.retain(windowKeys: ["app:1", "mini"], pids: [1])
        XCTAssertEqual(history.date(key: "app:1", pid: 1, isApplication: true, prefersPrimary: true), firstUse)
    }

    func testAutomaticReturnPrefersPreviousApplicationOverMRU() {
        XCTAssertEqual(AutomaticReturnPolicy.targetPID(previousPID: 2, eligiblePIDs: [3, 1, 2], excludedFallbackPID: 1), 2)
        XCTAssertEqual(AutomaticReturnPolicy.targetPID(previousPID: 1, eligiblePIDs: [3, 1, 2], excludedFallbackPID: 1), 1)
    }

    func testUnavailablePreviousApplicationFallsBackWithoutOpeningSettings() {
        XCTAssertEqual(AutomaticReturnPolicy.targetPID(previousPID: 4, eligiblePIDs: [1, 3, 2], excludedFallbackPID: 1), 3)
        XCTAssertEqual(AutomaticReturnPolicy.targetPID(previousPID: nil, eligiblePIDs: [1, 2], excludedFallbackPID: 1), 2)
        XCTAssertNil(AutomaticReturnPolicy.targetPID(previousPID: 4, eligiblePIDs: [1], excludedFallbackPID: 1))
        XCTAssertNil(AutomaticReturnPolicy.targetPID(previousPID: 2, eligiblePIDs: [], excludedFallbackPID: 1))
    }

    func testSettingsArePreviousOnlyWhenActivatedImmediatelyBeforeSource() {
        var history = ApplicationActivationHistory()
        history.record(pid: 1) // settings
        history.record(pid: 2) // WeChat
        history.record(pid: 2) // duplicate notification
        XCTAssertEqual(history.previousPID, 1)
        XCTAssertEqual(history.currentPID, 2)
        history.record(pid: 3) // another application
        history.record(pid: 2)
        XCTAssertEqual(history.previousPID, 3)
        XCTAssertEqual(history.currentPID, 2)
    }

    func testCatalogObservationSurvivesMissingOrOlderDisplayHistory() {
        var history = WindowRecency()
        let recent = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(history.date(key: "boardly", pid: 1, isApplication: false, prefersPrimary: false, observedAt: recent), recent)
        history.recordWindow(key: "boardly", pid: 1, isPrimary: false, at: recent.addingTimeInterval(-10))
        XCTAssertEqual(history.date(key: "boardly", pid: 1, isApplication: false, prefersPrimary: false, observedAt: recent), recent)
        history.recordWindow(key: "boardly", pid: 1, isPrimary: false, at: recent.addingTimeInterval(10))
        XCTAssertEqual(history.date(key: "boardly", pid: 1, isApplication: false, prefersPrimary: false, observedAt: recent), recent.addingTimeInterval(10))
    }

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

    func testCloseObservationRefreshesReopenRankWithoutFocusNotification() {
        var history = WindowRecency()
        let oldUse = Date(timeIntervalSince1970: 100)
        let browserUse = oldUse.addingTimeInterval(10)
        let closeUse = oldUse.addingTimeInterval(20)
        history.recordWindow(key: "wechat-main", pid: 1, isPrimary: true, at: oldUse)
        history.recordWindow(key: "browser", pid: 2, isPrimary: false, at: browserUse)
        history.recordWindow(key: "wechat-main", pid: 1, isPrimary: true, at: closeUse)
        history.retain(windowKeys: ["app:1", "browser"], pids: [1, 2])
        let reopened = history.date(key: "app:1", pid: 1, isApplication: true, prefersPrimary: true)
        XCTAssertEqual(reopened, closeUse)
        XCTAssertGreaterThan(reopened, history.date(key: "browser", pid: 2, isApplication: false, prefersPrimary: false))
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
