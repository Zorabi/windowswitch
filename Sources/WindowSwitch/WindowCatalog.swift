// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit
import ApplicationServices
import Carbon
import WindowFocus

enum ApplicationEntryPolicy {
    static let weChatBundleIDs: Set<String> = ["com.tencent.xinWeChat", "com.tencent.flue.WeChatAppEx", "com.tencent.flue.WeApp"]
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
    var isWeChat: Bool { ApplicationEntryPolicy.weChatBundleIDs.contains(application.bundleIdentifier ?? "") }

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
    var onWindowFocused: ((WindowItem, Date) -> Void)?
    private let queue = DispatchQueue(label: "dongx.windowswitch.windows", qos: .userInitiated)
    private let windowCommandQueue = DispatchQueue(label: "dongx.windowswitch.window-commands", qos: .userInteractive)
    private let focusQueue = DispatchQueue(label: "dongx.windowswitch.focus", qos: .userInteractive)
    private var recency = WindowRecency()
    private var cached: [String: WindowItem] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    // Accessed only on the main thread, along with focus request delivery.
    private var pendingReopenID: UUID?
    private var activeFocusRequest: WindowFocusRequest?

    private func windowTitle(_ title: String, application: NSRunningApplication, size: CGSize) -> String {
        guard title.isEmpty else { return title }
        let name = application.bundleIdentifier == "com.tencent.xinWeChat" ? "微信 · 其他窗口" : "未命名窗口"
        return "\(name) · \(Int(size.width)) × \(Int(size.height))"
    }

    private func remember(_ window: AXUIElement, application: NSRunningApplication) {
        let size = AXRead.size(window) ?? .zero
        guard size.width >= 70, size.height >= 70 else { return }
        let key = AXRead.key(pid: application.processIdentifier, element: window)
        let title = (AXRead.value(window, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cached[key] = WindowItem(key: key, pid: application.processIdentifier, windowID: AXRead.windowID(window),
            application: application, element: window, appName: application.localizedName ?? "应用",
            title: windowTitle(title, application: application, size: size),
            minimized: AXRead.bool(window, kAXMinimizedAttribute) == true, size: size)
    }

    private func observe(_ application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let catalog = Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue()
            catalog.noteWindowEvent(element, notification: notification as String)
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

    private func noteWindowEvent(_ element: AXUIElement, notification: String) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        let now = Date()
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let onlyTarget = activeFocusRequest?.isPending == true && activeFocusRequest?.pid == app.processIdentifier
        let expectedID = activeFocusRequest?.targetWindowID
        // Capture the element delivered by AX. Reading the frontmost application
        // later can lose a window when several windows are created in succession.
        queue.async { [self] in
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role = AXRead.value(element, kAXRoleAttribute) as? String
            let isWindow = role == kAXWindowRole || role == kAXSheetRole
            let window = isWindow ? element : AXRead.element(element, kAXFocusedWindowAttribute)
            guard let window else { return }
            remember(window, application: app)
            if notification == kAXFocusedWindowChangedNotification, wasFrontmost {
                let key = AXRead.key(pid: app.processIdentifier, element: window)
                guard !onlyTarget || (expectedID != nil && cached[key]?.windowID == expectedID) else { return }
                recency.recordWindow(key: key, pid: app.processIdentifier,
                    isPrimary: cached[key]?.isWeChatMain == true, at: now)
                if let item = cached[key] { publishFocusedWindow(item, at: now) }
            }
        }
    }

    func shouldRecordWindowUse(_ item: WindowItem) -> Bool {
        guard let request = activeFocusRequest, request.isPending, request.pid == item.pid else { return true }
        // Activation can expose the old main window before the target is ready.
        // Verified focus and actual AX events publish their own timestamps.
        return false
    }

    private func publishFocusedWindow(_ item: WindowItem, at date: Date) {
        // UI MRU delivery must not wait behind another full catalog scan.
        DispatchQueue.main.async { [weak self] in self?.onWindowFocused?(item, date) }
    }

    func noteFocusedWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let now = Date()
        let onlyTarget = activeFocusRequest?.isPending == true && activeFocusRequest?.pid == app.processIdentifier
        let expectedID = activeFocusRequest?.targetWindowID
        queue.async { [self] in
            recency.recordApplication(pid: app.processIdentifier, at: now)
            let source = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(source, 0.15)
            if let window = AXRead.element(source, kAXFocusedWindowAttribute) {
                remember(window, application: app)
                let key = AXRead.key(pid: app.processIdentifier, element: window)
                if !onlyTarget || (expectedID != nil && cached[key]?.windowID == expectedID) {
                    recency.recordWindow(key: key, pid: app.processIdentifier, isPrimary: cached[key]?.isWeChatMain == true, at: now)
                    if let item = cached[key] { publishFocusedWindow(item, at: now) }
                }
            }
            observe(app)
        }
    }

    func noteLocalWindowUse(key: String, pid: pid_t) {
        let now = Date()
        queue.async { [self] in recency.recordWindow(key: key, pid: pid, isPrimary: false, at: now) }
    }

    func load(additionalItems: [WindowItem] = [], completion: @escaping ([WindowItem]) -> Void) {
        let hosts = ApplicationEntryPolicy.weChatBundleIDs
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.activationPolicy == .regular || hosts.contains($0.bundleIdentifier ?? "")) && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        queue.async { [self] in
            let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let allCGWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let liveWindowIDs = Set(allCGWindows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
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
                let reportedWindows = raw as? [AXUIElement] ?? []
                var windows = reportedWindows
                if hosts.contains(app.bundleIdentifier ?? "") {
                    // WeChat can expose only its current window through AXWindows.
                    // Other top-level references still identify separate windows.
                    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                        if let window = AXRead.element(source, attribute) { windows.append(window) }
                    }
                    let children = AXRead.value(source, kAXChildrenAttribute) as? [AXUIElement] ?? []
                    for child in children {
                        AXUIElementSetMessagingTimeout(child, 0.15)
                        let role = AXRead.value(child, kAXRoleAttribute) as? String
                        if role == kAXWindowRole || role == kAXSheetRole { windows.append(child) }
                    }
                    // Some independent-looking WeChat windows are exposed as sheets
                    // attached to a parent instead of appearing in AXWindows.
                    for window in windows {
                        AXUIElementSetMessagingTimeout(window, 0.25)
                        let children = AXRead.value(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
                        for child in children {
                            AXUIElementSetMessagingTimeout(child, 0.15)
                            if AXRead.value(child, kAXRoleAttribute) as? String == kAXSheetRole { windows.append(child) }
                        }
                    }
                }
                let before = items.count
                var windowDetails: [[String: Any]] = []
                var candidateKeys = Set<String>()
                for window in windows {
                    AXUIElementSetMessagingTimeout(window, 0.25)
                    let key = AXRead.key(pid: app.processIdentifier, element: window)
                    guard candidateKeys.insert(key).inserted else { continue }
                    AXUIElementSetMessagingTimeout(window, 0.25)
                    let role = AXRead.value(window, kAXRoleAttribute) as? String
                    let subrole = AXRead.value(window, kAXSubroleAttribute) as? String
                    let size = AXRead.size(window) ?? .zero
                    windowDetails.append(["role": role ?? "", "subrole": subrole ?? "", "width": size.width, "height": size.height, "id": AXRead.windowID(window) ?? 0])
                    let isWeChatDialog = hosts.contains(app.bundleIdentifier ?? "") &&
                        (role == kAXSheetRole) && AXRead.windowID(window) != nil
                    guard role == nil || role == kAXWindowRole || isWeChatDialog else { continue }
                    guard subrole != kAXFloatingWindowSubrole else { continue }
                    guard (size == .zero) || (size.width >= 70 && size.height >= 70) else { continue }
                    guard seen.insert(key).inserted else { continue }
                    let title = (AXRead.value(window, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let item = WindowItem(
                        key: key, pid: app.processIdentifier, windowID: AXRead.windowID(window),
                        application: app, element: window, appName: app.localizedName ?? "应用",
                        title: windowTitle(title, application: app, size: size),
                        minimized: AXRead.bool(window, kAXMinimizedAttribute) == true, size: size
                    )
                    items.append(item)
                    cached[key] = item
                }
                for item in cached.values where item.pid == app.processIdentifier && !seen.contains(item.key) {
                    guard let element = item.element,
                          item.windowID == AXRead.windowID(element),
                          item.windowID.map(liveWindowIDs.contains) == true || AXRead.bool(element, kAXMinimizedAttribute) == true || app.isHidden else { continue }
                    items.append(item)
                    seen.insert(item.key)
                }
                diagnostics.append([
                    "bundleID": app.bundleIdentifier ?? "", "pid": app.processIdentifier,
                    "activationPolicy": app.activationPolicy.rawValue, "axError": readResult.rawValue,
                    "reportedWindows": reportedWindows.count, "candidateWindows": candidateKeys.count,
                    "listedWindows": items.count - before, "windows": windowDetails,
                    "systemWindows": allCGWindows.filter {
                        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
                    }.compactMap { row -> [String: Any]? in
                        guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                              let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber,
                              width.doubleValue >= 70, height.doubleValue >= 70 else { return nil }
                        return ["id": row[kCGWindowNumber as String] ?? 0,
                                "width": width, "height": height,
                                "layer": row[kCGWindowLayer as String] ?? 0]
                    }
                ])
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

    func cancelPendingFocus() {
        pendingReopenID = nil
        activeFocusRequest?.cancel()
        activeFocusRequest = nil
    }

    func notePanelRelease(_ reason: String) { activeFocusRequest?.mark("panel_" + reason) }

    private func reopenWeChatMain(_ item: WindowItem, request: WindowFocusRequest,
                                  onFronted: @escaping () -> Void, completion: @escaping (String?) -> Void) {
        guard let url = item.application.bundleURL else {
            request.finish("application_url_unavailable")
            completion("无法定位该应用，请从访达中打开。")
            return
        }
        let id = UUID()
        pendingReopenID = id
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        request.mark("reopen_requested")
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self, self.pendingReopenID == id, !request.isCancelled else { return }
                request.mark("reopen_returned")
                if let error {
                    self.pendingReopenID = nil
                    request.finish("reopen_failed")
                    completion("打开应用失败：\(error.localizedDescription)")
                } else {
                    self.waitForWeChatMain(item, requestID: id, request: request, attempt: 0, onFronted: onFronted, completion: completion)
                }
            }
        }
    }

    private func waitForWeChatMain(_ item: WindowItem, requestID: UUID, request: WindowFocusRequest, attempt: Int,
                                   onFronted: @escaping () -> Void, completion: @escaping (String?) -> Void) {
        guard pendingReopenID == requestID, !request.isCancelled else { return }
        guard !item.application.isTerminated else {
            pendingReopenID = nil
            request.finish("application_exited")
            completion("目标应用已经退出，请重新选择窗口。")
            return
        }
        focusQueue.async { [self] in
            guard !request.isCancelled else { return }
            let source = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(source, 0.15)
            var windows = AXRead.value(source, kAXWindowsAttribute) as? [AXUIElement] ?? []
            for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                if let window = AXRead.element(source, attribute) { windows.append(window) }
            }
            windows.append(contentsOf: AXRead.value(source, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            var found: WindowItem?
            var seen = Set<String>()
            for window in windows {
                guard !request.isCancelled else { return }
                AXUIElementSetMessagingTimeout(window, 0.15)
                let key = AXRead.key(pid: item.pid, element: window)
                guard seen.insert(key).inserted,
                      AXRead.value(window, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
                let title = (AXRead.value(window, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard ApplicationEntryPolicy.weChatMainTitles.contains(title) else { continue }
                found = WindowItem(key: key, pid: item.pid, windowID: AXRead.windowID(window),
                    application: item.application, element: window, appName: item.appName, title: title,
                    minimized: AXRead.bool(window, kAXMinimizedAttribute) == true, size: AXRead.size(window) ?? .zero)
                break
            }
            let target = found
            DispatchQueue.main.async { [self] in
                guard pendingReopenID == requestID, !request.isCancelled else { return }
                if let target {
                    request.updateTarget(target.windowID)
                    request.mark("reopen_main_found")
                    pendingReopenID = nil
                    if let window = target.element {
                        queue.async { [self] in remember(window, application: target.application) }
                    }
                    // Use the same single-window focus path as an existing window.
                    focusWeChatWindow(target, request: request, onFronted: onFronted, completion: completion)
                } else if attempt < 12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        self?.waitForWeChatMain(item, requestID: requestID, request: request, attempt: attempt + 1, onFronted: onFronted, completion: completion)
                    }
                } else {
                    pendingReopenID = nil
                    NSLog("WeChat main window unavailable after background reopen: pid=%d", item.pid)
                    request.finish("reopen_unconfirmed")
                    completion(nil)
                }
            }
        }
    }

    private func focusWeChatWindow(_ item: WindowItem, request: WindowFocusRequest,
                                   onFronted: @escaping () -> Void, completion: @escaping (String?) -> Void) {
        guard !request.isCancelled else { return }
        guard item.windowID != nil, !item.application.isTerminated else {
            request.finish("target_unavailable")
            completion("目标窗口不可用，请重新选择。")
            return
        }
        if item.minimized {
            focusQueue.async { [self] in
                guard !request.isCancelled else { return }
                request.mark("restore_started")
                let source = AXUIElementCreateApplication(item.pid)
                AXUIElementSetMessagingTimeout(source, 0.15)
                let candidates = AXRead.value(source, kAXWindowsAttribute) as? [AXUIElement] ?? []
                let current = candidates.first { AXRead.windowID($0) == item.windowID }
                let cached = item.element.flatMap { AXRead.windowID($0) == item.windowID ? $0 : nil }
                guard !request.isCancelled else { return }
                guard let window = current ?? cached else {
                    request.finish("restore_window_unavailable")
                    DispatchQueue.main.async { if !request.isCancelled { completion("目标窗口暂时不可用，请重新选择。") } }
                    return
                }
                AXUIElementSetMessagingTimeout(window, 0.15)
                let restored = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                request.mark("restore_returned", result: restored.rawValue)
                guard !request.isCancelled else { return }
                guard restored == .success else {
                    request.finish("restore_failed")
                    DispatchQueue.main.async { if !request.isCancelled { completion("目标应用未接受窗口恢复请求。") } }
                    return
                }
                activateWeChatWindow(item, request: request, onFronted: onFronted, completion: completion)
            }
        } else {
            activateWeChatWindow(item, request: request, onFronted: onFronted, completion: completion)
        }
    }

    private func activateWeChatWindow(_ item: WindowItem, request: WindowFocusRequest,
                                     onFronted: @escaping () -> Void, completion: @escaping (String?) -> Void) {
        request.mark("activation_queued")
        windowCommandQueue.async { [self] in
            guard !request.isCancelled else { return }
            request.mark("activation_started")
            guard !item.application.isTerminated, let id = item.windowID else {
                request.finish("target_unavailable")
                DispatchQueue.main.async { if !request.isCancelled { completion("目标窗口不可用，请重新选择。") } }
                return
            }
            let activation = WSActivateWindow(item.pid, id)
            request.mark("activation_returned", result: activation)
            guard !request.isCancelled else { return }
            guard activation == noErr else {
                request.finish("activation_failed")
                DispatchQueue.main.async { if !request.isCancelled { onFronted(); completion(nil) } }
                return
            }
            // This step transfers key focus; fronting by window ID alone does not.
            let key = WSMakeWindowKey(item.pid, id)
            request.mark("key_returned", result: key)
            guard !request.isCancelled else { return }
            DispatchQueue.main.async {
                guard !request.isCancelled else { return }
                request.mark("handoff_callback")
                onFronted()
                completion(nil)
            }
            guard key == noErr else { request.finish("key_unconfirmed"); return }
            focusQueue.async { [self] in
                // The app may have accepted the WindowServer requests while its
                // own key/main window still names the chat window. Complete the
                // app-internal raise before checking focus, as in AltTab's pipeline.
                raiseWeChatTarget(item, request: request)
                guard !request.isCancelled else { return }
                focusQueue.asyncAfter(deadline: .now() + 0.05) { [self] in
                    verifyWeChatFocus(item, request: request)
                }
            }
        }
    }

    private func raiseWeChatTarget(_ item: WindowItem, request: WindowFocusRequest) {
        guard !request.isCancelled, request.age < 0.35,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == item.pid,
              let id = item.windowID else { return }
        request.mark("target_raise_started")
        var result: AXError = .invalidUIElement
        if let cached = item.element {
            AXUIElementSetMessagingTimeout(cached, 0.12)
            if AXRead.windowID(cached) == id, !request.isCancelled {
                result = AXUIElementPerformAction(cached, kAXRaiseAction as CFString)
                request.mark("cached_raise_returned", result: result.rawValue)
            }
        }
        // Rebind an invalid AX proxy by exact ID once. Never select the current
        // chat window merely because it is the only window AX happens to expose.
        if result == .invalidUIElement, !request.isCancelled, request.age < 0.35 {
            let source = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(source, 0.12)
            let windows = AXRead.value(source, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let fresh = windows.first(where: { AXRead.windowID($0) == id }),
               !request.isCancelled, request.age < 0.35,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == item.pid {
                AXUIElementSetMessagingTimeout(fresh, 0.12)
                result = AXUIElementPerformAction(fresh, kAXRaiseAction as CFString)
                request.mark("fresh_raise_returned", result: result.rawValue)
                queue.async { [self] in remember(fresh, application: item.application) }
            }
        }
    }

    private func verifyWeChatFocus(_ item: WindowItem, request: WindowFocusRequest) {
        guard !request.isCancelled else { return }
        guard request.age < 0.6 else { request.finish("verification_expired"); return }
        request.mark("verification_started")
        let source = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(source, 0.12)
        let actual = AXRead.element(source, kAXFocusedWindowAttribute)
        let actualID = actual.flatMap(AXRead.windowID)
        let confirmed = actualID == item.windowID
        request.mark("focus_observed", windowID: actualID ?? 0)
        guard !request.isCancelled else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == item.pid else {
            request.finish("foreground_changed")
            return
        }
        // Retry only the selected window's internal raise, and only with evidence
        // that it has key focus but remains covered. Never replay the key event.
        if confirmed, request.age < 0.35, isWindowCovered(item), let window = actual,
           AXRead.windowID(window) == item.windowID, !request.isCancelled {
            AXUIElementSetMessagingTimeout(window, 0.12)
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            request.mark("occlusion_raise_returned", result: raised.rawValue)
        }
        guard !request.isCancelled else { return }
        if confirmed {
            let usedAt = Date()
            publishFocusedWindow(item, at: usedAt)
            queue.async { [self] in
                recency.recordWindow(key: item.key, pid: item.pid, isPrimary: item.isWeChatMain, at: usedAt)
            }
        }
        request.finish(confirmed ? "confirmed" : "fronted_key_unconfirmed")
    }

    private func isWindowCovered(_ item: WindowItem) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let index = rows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == item.windowID }),
              let bounds = rows[index][kCGWindowBounds as String] as? [String: Any],
              let target = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return rows[..<index].contains { row in
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.05,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.width >= 70 && rect.height >= 70 && rect.intersects(target)
        }
    }

    func focus(_ item: WindowItem, requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
               onFronted: @escaping () -> Void = {}, completion: @escaping (String?) -> Void) {
        cancelPendingFocus()
        let request = WindowFocusRequest(pid: item.pid, windowID: item.windowID, startedAt: requestedAt, isWeChat: item.isWeChat)
        activeFocusRequest = request
        guard let selectedElement = item.element else {
            if item.isWeChatMain {
                reopenWeChatMain(item, request: request, onFronted: onFronted, completion: completion)
                return
            }
            // This is an explicitly selected application entry, not a fallback
            // from a failed window focus. Closed main windows need a reopen event.
            guard let url = item.application.bundleURL else {
                request.finish("application_url_unavailable")
                completion("无法定位该应用，请从访达中打开。")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            request.mark("application_reopen_requested")
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    guard !request.isCancelled else { return }
                    request.finish(error == nil ? "application_opened" : "application_open_failed")
                    if error == nil {
                        let usedAt = Date()
                        self.publishFocusedWindow(item, at: usedAt)
                        self.queue.async { [self] in
                            self.recency.recordWindow(key: item.key, pid: item.pid, isPrimary: item.isWeChatMain, at: usedAt)
                        }
                    }
                    onFronted()
                    completion(error.map { "打开应用失败：\($0.localizedDescription)" })
                }
            }
            return
        }
        if item.isWeChat {
            focusWeChatWindow(item, request: request, onFronted: onFronted, completion: completion)
            return
        }
        request.mark("legacy_queued")
        focusQueue.async { [self] in
            guard !request.isCancelled else { return }
            request.mark("legacy_started")
            guard !item.application.isTerminated else {
                request.finish("application_exited")
                DispatchQueue.main.async { if !request.isCancelled { completion("目标应用已经退出，请重新选择窗口。") } }
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
                request.finish("window_closed")
                DispatchQueue.main.async { if !request.isCancelled { completion("目标窗口已经关闭，请重新选择。") } }
                return
            }
            guard !request.isCancelled else { return }
            AXUIElementSetMessagingTimeout(window, 0.2)
            if AXRead.bool(window, kAXMinimizedAttribute) == true {
                let restored = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                guard restored == .success else {
                    request.finish("restore_failed")
                    DispatchQueue.main.async { if !request.isCancelled { completion("目标应用未接受窗口恢复请求。") } }
                    return
                }
            }
            guard !request.isCancelled else { return }
            // Other applications retain the existing AX focus path.
            let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            guard !request.isCancelled else { return }
            let focused = AXUIElementSetAttributeValue(source, kAXFocusedWindowAttribute as CFString, window)
            guard !request.isCancelled else { return }
            let activation = WSActivateFrontWindowOnly(item.pid)
            request.mark("legacy_activation_returned", result: activation)
            DispatchQueue.main.async { if !request.isCancelled { onFronted() } }
            guard !request.isCancelled else { return }
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            focusQueue.asyncAfter(deadline: .now() + 0.18) { [self] in
                guard !request.isCancelled else { return }
                let actual = AXRead.element(source, kAXFocusedWindowAttribute)
                let confirmed = (actual.map { CFEqual($0, window) } ?? false) || AXRead.bool(window, kAXFocusedAttribute) == true
                let success = activation == noErr && confirmed &&
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == item.pid
                guard !request.isCancelled else { return }
                request.finish(success ? "confirmed" : "legacy_unconfirmed")
                if success {
                    let usedAt = Date()
                    publishFocusedWindow(item, at: usedAt)
                    queue.async { [self] in recency.recordWindow(key: item.key, pid: item.pid, isPrimary: item.isWeChatMain, at: usedAt) }
                }
                if !success {
                    NSLog("Window focus unconfirmed: pid=%d activate=%d raise=%d main=%d focus=%d", item.pid, activation, raised.rawValue, main.rawValue, focused.rawValue)
                }
                // AX confirmation is diagnostic only: some applications do not
                // report focus reliably even after accepting the switch request.
                // Recency still changes only when focus was actually confirmed.
                DispatchQueue.main.async { if !request.isCancelled { completion(nil) } }
            }
        }
    }
}
