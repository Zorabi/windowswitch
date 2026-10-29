// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit
import ApplicationServices
import Carbon
import WindowFocus

enum ApplicationEntryPolicy {
    static let weChatMainTitles: Set<String> = ["微信", "WeChat", "Weixin"]
    static func shouldInclude(bundleID: String?, isRegular: Bool, windowTitles: [String]) -> Bool {
        guard isRegular, bundleID != "com.tencent.flue.WeApp" else { return false }
        if bundleID == "com.tencent.xinWeChat" {
            return !windowTitles.contains(where: weChatMainTitles.contains)
        }
        return windowTitles.isEmpty
    }
}

struct WindowItem {
    let key: String
    let pid: pid_t
    let windowID: CGWindowID?
    let application: NSRunningApplication
    let element: AXUIElement?
    let appName: String
    let title: String
    let minimized: Bool
    let size: CGSize

    var isLocalSettings: Bool { key == "local:settings" }

    var isWeChatMain: Bool {
        application.bundleIdentifier == "com.tencent.xinWeChat" && (element == nil || ApplicationEntryPolicy.weChatMainTitles.contains(title))
    }
}

enum AXRead {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(source, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = value(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &result) else { return nil }
        return result
    }

    // Optional, read-only bridge between AX and CoreGraphics window identities.
    // Selection and focus still work using the AX element if this symbol is unavailable.
    private static let idFunction: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32).self)
    }()

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var result: CGWindowID = 0
        guard idFunction?(element, &result) == 0, result != 0 else { return nil }
        return result
    }

    static func key(pid: pid_t, element: AXUIElement) -> String {
        if let id = windowID(element) { return "\(pid):\(id)" }
        return "\(pid):ax:\(CFHash(element))"
    }
}

final class WindowCatalog {
    private let queue = DispatchQueue(label: "dongx.windowswitch.windows", qos: .userInitiated)
    private let focusQueue = DispatchQueue(label: "dongx.windowswitch.focus", qos: .userInteractive)
    private var recency = WindowRecency()
    private var cached: [String: WindowItem] = [:]
    private var observers: [pid_t: AXObserver] = [:]

    private func remember(_ window: AXUIElement, application: NSRunningApplication) {
        let size = AXRead.size(window) ?? .zero
        guard size.width >= 70, size.height >= 70 else { return }
        let key = AXRead.key(pid: application.processIdentifier, element: window)
        let title = (AXRead.value(window, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cached[key] = WindowItem(key: key, pid: application.processIdentifier, windowID: AXRead.windowID(window),
            application: application, element: window, appName: application.localizedName ?? "应用",
            title: title.isEmpty ? "未命名窗口 · \(Int(size.width)) × \(Int(size.height))" : title,
            minimized: AXRead.bool(window, kAXMinimizedAttribute) == true, size: size)
    }

    private func observe(_ application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let catalog = Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue()
            catalog.noteFocusedWindow()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let source = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(source, 0.25)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
            _ = AXObserverAddNotification(observer, source, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    func noteFocusedWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let now = Date()
        queue.async { [self] in
            recency.recordApplication(pid: app.processIdentifier, at: now)
            let source = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(source, 0.15)
            if let window = AXRead.element(source, kAXFocusedWindowAttribute) {
                remember(window, application: app)
                let key = AXRead.key(pid: app.processIdentifier, element: window)
                recency.recordWindow(key: key, pid: app.processIdentifier, isPrimary: cached[key]?.isWeChatMain == true, at: now)
            }
            observe(app)
        }
    }

    func noteLocalWindowUse(key: String, pid: pid_t) {
        queue.async { [self] in recency.recordWindow(key: key, pid: pid, isPrimary: false, at: Date()) }
    }

    func load(additionalItems: [WindowItem] = [], completion: @escaping ([WindowItem]) -> Void) {
        let hosts: Set<String> = ["com.tencent.xinWeChat", "com.tencent.flue.WeChatAppEx", "com.tencent.flue.WeApp"]
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.activationPolicy == .regular || hosts.contains($0.bundleIdentifier ?? "")) && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        queue.async { [self] in
            let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            var order: [CGWindowID: Int] = [:]
            for (index, row) in cgWindows.enumerated() {
                if let id = row[kCGWindowNumber as String] as? NSNumber { order[id.uint32Value] = index }
            }
            var items: [WindowItem] = []
            var seen: Set<String> = []
            var diagnostics: [[String: Any]] = []
            for app in apps {
                observe(app)
                let source = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(source, hosts.contains(app.bundleIdentifier ?? "") ? 1.0 : 0.25)
                var raw: CFTypeRef?
                let readResult = AXUIElementCopyAttributeValue(source, kAXWindowsAttribute as CFString, &raw)
                let windows = raw as? [AXUIElement] ?? []
                let before = items.count
                var windowDetails: [[String: Any]] = []
                for window in windows {
                    AXUIElementSetMessagingTimeout(window, 0.25)
                    let role = AXRead.value(window, kAXRoleAttribute) as? String
                    let subrole = AXRead.value(window, kAXSubroleAttribute) as? String
                    let size = AXRead.size(window) ?? .zero
                    windowDetails.append(["role": role ?? "", "subrole": subrole ?? "", "width": size.width, "height": size.height, "id": AXRead.windowID(window) ?? 0])
                    guard role == nil || role == kAXWindowRole else { continue }
                    guard subrole != kAXFloatingWindowSubrole else { continue }
                    guard (size == .zero) || (size.width >= 70 && size.height >= 70) else { continue }
                    let key = AXRead.key(pid: app.processIdentifier, element: window)
                    guard seen.insert(key).inserted else { continue }
                    let title = (AXRead.value(window, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let item = WindowItem(
                        key: key, pid: app.processIdentifier, windowID: AXRead.windowID(window),
                        application: app, element: window, appName: app.localizedName ?? "应用",
                        title: title.isEmpty ? "未命名窗口 · \(Int(size.width)) × \(Int(size.height))" : title,
                        minimized: AXRead.bool(window, kAXMinimizedAttribute) == true, size: size
                    )
                    items.append(item)
                    cached[key] = item
                }
                diagnostics.append([
                    "bundleID": app.bundleIdentifier ?? "", "pid": app.processIdentifier,
                    "activationPolicy": app.activationPolicy.rawValue, "axError": readResult.rawValue,
                    "reportedWindows": windows.count, "listedWindows": items.count - before, "windows": windowDetails
                ])
                for item in cached.values where item.pid == app.processIdentifier && !seen.contains(item.key) {
                    guard let element = item.element,
                          item.windowID == AXRead.windowID(element),
                          item.windowID.map({ order[$0] != nil }) == true || AXRead.bool(element, kAXMinimizedAttribute) == true || app.isHidden else { continue }
                    items.append(item)
                    seen.insert(item.key)
                }
                let titles = items.filter { $0.pid == app.processIdentifier && $0.element != nil }.map(\.title)
                if ApplicationEntryPolicy.shouldInclude(bundleID: app.bundleIdentifier, isRegular: app.activationPolicy == .regular, windowTitles: titles) {
                    let name = app.localizedName ?? "应用"
                    items.append(WindowItem(key: "app:\(app.processIdentifier)", pid: app.processIdentifier,
                        windowID: nil, application: app, element: nil, appName: name,
                        title: name, minimized: false, size: .zero))
                }
            }
            items.append(contentsOf: additionalItems)
            let livePIDs = Set(apps.map(\.processIdentifier) + additionalItems.map(\.pid))
            cached = cached.filter { livePIDs.contains($0.value.pid) }
            for (pid, observer) in observers where !livePIDs.contains(pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                observers.removeValue(forKey: pid)
            }
            if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("dongx.windowswitch") {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let data = try JSONSerialization.data(withJSONObject: ["scannedAt": ISO8601DateFormatter().string(from: Date()), "applications": diagnostics], options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: directory.appendingPathComponent("last-scan.json"), options: .atomic)
                } catch { /* Diagnostics must never prevent window switching. */ }
            }
            let liveKeys = Set(items.map(\.key))
            recency.retain(windowKeys: liveKeys, pids: livePIDs)
            items.sort { left, right in
                let leftDate = recency.date(key: left.key, pid: left.pid, isApplication: left.element == nil, prefersPrimary: left.isWeChatMain)
                let rightDate = recency.date(key: right.key, pid: right.pid, isApplication: right.element == nil, prefersPrimary: right.isWeChatMain)
                if leftDate != rightDate { return leftDate > rightDate }
                let leftOrder = left.windowID.flatMap { order[$0] } ?? Int.max
                let rightOrder = right.windowID.flatMap { order[$0] } ?? Int.max
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return left.key < right.key
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    func focus(_ item: WindowItem, completion: @escaping (String?) -> Void) {
        guard let selectedElement = item.element else {
            queue.async { [self] in
                recency.recordWindow(key: item.key, pid: item.pid, isPrimary: item.isWeChatMain, at: Date())
            }
            // This is an explicitly selected application entry, not a fallback
            // from a failed window focus. Closed main windows need a reopen event.
            guard let url = item.application.bundleURL else {
                completion("无法定位该应用，请从访达中打开。")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                DispatchQueue.main.async { completion(error.map { "打开应用失败：\($0.localizedDescription)" }) }
            }
            return
        }
        focusQueue.async { [self] in
            guard !item.application.isTerminated else {
                DispatchQueue.main.async { completion("目标应用已经退出，请重新选择窗口。") }
                return
            }
            let source = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(source, 0.2)
            let current = AXRead.value(source, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let currentTarget = current.first { candidate in
                if let id = item.windowID { return AXRead.windowID(candidate) == id }
                return CFEqual(candidate, selectedElement)
            }
            let stableCached = item.windowID != nil && AXRead.windowID(selectedElement) == item.windowID
            guard let window = currentTarget ?? (stableCached ? selectedElement : nil) else {
                DispatchQueue.main.async { completion("目标窗口已经关闭，请重新选择。") }
                return
            }
            AXUIElementSetMessagingTimeout(window, 0.2)
            if AXRead.bool(window, kAXMinimizedAttribute) == true {
                let restored = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                guard restored == .success else {
                    DispatchQueue.main.async { completion("目标应用未接受窗口恢复请求。") }
                    return
                }
            }
            // Name the chosen window before process activation. Never reopen the app,
            // activate all windows, or minimize sibling windows to simulate isolation.
            let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            let focused = AXUIElementSetAttributeValue(source, kAXFocusedWindowAttribute as CFString, window)
            let activation = WSActivateFrontWindowOnly(item.pid)
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            focusQueue.asyncAfter(deadline: .now() + 0.18) { [self] in
                let actual = AXRead.element(source, kAXFocusedWindowAttribute)
                let confirmed = (actual.map { CFEqual($0, window) } ?? false) || AXRead.bool(window, kAXFocusedAttribute) == true
                let success = activation == noErr && confirmed
                if success {
                    let usedAt = Date()
                    queue.async { [self] in recency.recordWindow(key: item.key, pid: item.pid, isPrimary: item.isWeChatMain, at: usedAt) }
                }
                if !success {
                    NSLog("Window focus unconfirmed: pid=%d activate=%d raise=%d main=%d focus=%d", item.pid, activation, raised.rawValue, main.rawValue, focused.rawValue)
                }
                // AX confirmation is diagnostic only: some applications do not
                // report focus reliably even after accepting the switch request.
                // Recency still changes only when focus was actually confirmed.
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
