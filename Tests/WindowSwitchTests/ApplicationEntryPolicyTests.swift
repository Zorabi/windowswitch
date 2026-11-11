// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import XCTest
@testable import WindowSwitch

final class ApplicationEntryPolicyTests: XCTestCase {
    func testClosedWeChatMainKeepsReopenEntryWhileMiniProgramIsOpen() {
        XCTAssertTrue(ApplicationEntryPolicy.shouldInclude(bundleID: "com.tencent.xinWeChat", isRegular: true, windowTitles: ["小程序测试窗口"]))
        XCTAssertTrue(ApplicationEntryPolicy.shouldInclude(bundleID: "com.tencent.xinWeChat", isRegular: true, windowTitles: []))
    }

    func testVisibleWeChatMainAvoidsDuplicateApplicationEntry() {
        for title in ["微信", "WeChat", "Weixin"] {
            XCTAssertFalse(ApplicationEntryPolicy.shouldInclude(bundleID: "com.tencent.xinWeChat", isRegular: true, windowTitles: [title, "小程序测试窗口"]))
        }
    }

    func testUnreportedClosedWeChatPrimaryDoesNotSuppressReopenEntry() {
        let policy = ApplicationWindowPolicy.forApplication(bundleID: "com.tencent.xinWeChat")
        XCTAssertFalse(policy.retainsUnreportedWindow(isPrimary: true, isMinimized: false,
            isApplicationHidden: false, isOnscreen: false, hasReliableWindowList: true))
        XCTAssertTrue(policy.shouldIncludeApplicationEntry(isRegular: true, windowTitles: ["图片和视频"]))
    }

    func testUnreportedWindowsAreRetainedWhenClosureIsUncertain() {
        let policy = ApplicationWindowPolicy.forApplication(bundleID: "com.tencent.xinWeChat")
        for state in [(true, false, false, true), (false, true, false, true),
                      (false, false, true, true), (false, false, false, false)] {
            XCTAssertTrue(policy.retainsUnreportedWindow(isPrimary: true, isMinimized: state.0,
                isApplicationHidden: state.1, isOnscreen: state.2, hasReliableWindowList: state.3))
        }
        XCTAssertTrue(policy.retainsUnreportedWindow(isPrimary: false, isMinimized: false,
            isApplicationHidden: false, isOnscreen: false, hasReliableWindowList: true))
    }

    func testWindowlessProxyDoesNotDuplicateHostedMiniProgram() {
        XCTAssertFalse(ApplicationEntryPolicy.shouldInclude(bundleID: "com.tencent.flue.WeApp", isRegular: true, windowTitles: []))
        XCTAssertFalse(ApplicationEntryPolicy.shouldInclude(bundleID: "com.tencent.flue.WeChatAppEx", isRegular: false, windowTitles: []))
        XCTAssertTrue(ApplicationEntryPolicy.shouldInclude(bundleID: "com.apple.TextEdit", isRegular: true, windowTitles: []))
        XCTAssertFalse(ApplicationEntryPolicy.shouldInclude(bundleID: "com.apple.TextEdit", isRegular: true, windowTitles: ["文稿"]))
    }
}
