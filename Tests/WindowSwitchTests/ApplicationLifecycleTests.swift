// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit
import XCTest
@testable import WindowSwitch

final class ApplicationLifecycleTests: XCTestCase {
    func testStaleReopenEntryDoesNotLaunchApplication() {
        let item = entry(pid: -1)
        let catalog = WindowCatalog()
        var completionCount = 0
        var error: String?
        catalog.focus(item, onFronted: { XCTFail("Exited application must not be activated") }) {
            completionCount += 1
            error = $0
        }
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(error, "目标应用已经退出，请重新选择。")
    }

    func testLiveWindowlessApplicationStillHasValidReopenEntry() throws {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier > 0
        }) else { throw XCTSkip("Requires a running macOS application") }
        let item = entry(pid: app.processIdentifier, application: app)
        XCTAssertTrue(item.isApplicationEntry)
        XCTAssertTrue(item.isRunning)
    }

    private func entry(pid: pid_t, application: NSRunningApplication = .current) -> WindowItem {
        WindowItem(key: "app:\(pid)", pid: pid, windowID: nil,
            application: application, element: nil, appName: "测试应用", title: "测试应用",
            minimized: false, size: .zero)
    }
}
