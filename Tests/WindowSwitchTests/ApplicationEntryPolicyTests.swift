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

    func testWindowlessProxyDoesNotDuplicateHostedMiniProgram() {
        XCTAssertFalse(ApplicationEntryPolicy.shouldInclude(bundleID: "com.tencent.flue.WeApp", isRegular: true, windowTitles: []))
        XCTAssertFalse(ApplicationEntryPolicy.shouldInclude(bundleID: "com.tencent.flue.WeChatAppEx", isRegular: false, windowTitles: []))
        XCTAssertTrue(ApplicationEntryPolicy.shouldInclude(bundleID: "com.apple.TextEdit", isRegular: true, windowTitles: []))
        XCTAssertFalse(ApplicationEntryPolicy.shouldInclude(bundleID: "com.apple.TextEdit", isRegular: true, windowTitles: ["文稿"]))
    }
}
