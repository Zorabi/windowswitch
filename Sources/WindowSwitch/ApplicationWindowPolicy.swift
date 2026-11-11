// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import Foundation

/// Application quirks select reusable window operations; bundle checks stay here.
struct ApplicationWindowPolicy {
    enum FocusMethod {
        case accessibility
        case windowID
    }

    let includesNonRegularApplication: Bool
    let allowsApplicationEntry: Bool
    let discoversAdditionalWindows: Bool
    let focusMethod: FocusMethod
    let primaryWindowTitles: Set<String>
    let unnamedWindowName: String
    let applicationEntryDetail: String
    let focusDiagnosticFile: String

    init(includesNonRegularApplication: Bool = false, allowsApplicationEntry: Bool = true,
         discoversAdditionalWindows: Bool = false, focusMethod: FocusMethod = .accessibility,
         primaryWindowTitles: Set<String> = [], unnamedWindowName: String = "未命名窗口",
         applicationEntryDetail: String = "打开应用",
         focusDiagnosticFile: String = "last-focus.json") {
        self.includesNonRegularApplication = includesNonRegularApplication
        self.allowsApplicationEntry = allowsApplicationEntry
        self.discoversAdditionalWindows = discoversAdditionalWindows
        self.focusMethod = focusMethod
        self.primaryWindowTitles = primaryWindowTitles
        self.unnamedWindowName = unnamedWindowName
        self.applicationEntryDetail = applicationEntryDetail
        self.focusDiagnosticFile = focusDiagnosticFile
    }

    private static let standard = ApplicationWindowPolicy()
    private static let overrides: [String: ApplicationWindowPolicy] = [
        "com.tencent.xinWeChat": ApplicationWindowPolicy(
            includesNonRegularApplication: true, discoversAdditionalWindows: true,
            focusMethod: .windowID, primaryWindowTitles: ["微信", "WeChat", "Weixin"],
            unnamedWindowName: "微信 · 其他窗口", applicationEntryDetail: "微信 · 重新打开主窗口",
            focusDiagnosticFile: "last-wechat-focus.json"),
        "com.tencent.flue.WeChatAppEx": ApplicationWindowPolicy(
            includesNonRegularApplication: true, discoversAdditionalWindows: true,
            focusMethod: .windowID, focusDiagnosticFile: "last-wechat-focus.json"),
        "com.tencent.flue.WeApp": ApplicationWindowPolicy(
            includesNonRegularApplication: true, allowsApplicationEntry: false,
            discoversAdditionalWindows: true, focusMethod: .windowID,
            focusDiagnosticFile: "last-wechat-focus.json")
    ]

    static func forApplication(bundleID: String?) -> ApplicationWindowPolicy {
        bundleID.flatMap { overrides[$0] } ?? standard
    }

    func isPrimaryWindow(title: String, isApplicationEntry: Bool = false) -> Bool {
        !primaryWindowTitles.isEmpty && (isApplicationEntry || primaryWindowTitles.contains(title))
    }

    func retainsUnreportedWindow(isPrimary: Bool, isMinimized: Bool, isApplicationHidden: Bool,
                                 isOnscreen: Bool, hasReliableWindowList: Bool) -> Bool {
        // A closed WeChat main window can keep its CGWindowID after disappearing
        // from AX. Live minimized/hidden windows must remain switchable.
        !isPrimary || isMinimized || isApplicationHidden || isOnscreen || !hasReliableWindowList
    }

    func shouldIncludeApplicationEntry(isRegular: Bool, windowTitles: [String]) -> Bool {
        guard isRegular, allowsApplicationEntry else { return false }
        if primaryWindowTitles.isEmpty { return windowTitles.isEmpty }
        return !windowTitles.contains(where: primaryWindowTitles.contains)
    }
}

/// Retains the application-entry contract used independently of the window catalog.
enum ApplicationEntryPolicy {
    static func shouldInclude(bundleID: String?, isRegular: Bool, windowTitles: [String]) -> Bool {
        ApplicationWindowPolicy.forApplication(bundleID: bundleID)
            .shouldIncludeApplicationEntry(isRegular: isRegular, windowTitles: windowTitles)
    }
}
