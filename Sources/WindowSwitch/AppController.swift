// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit
import ApplicationServices

final class AppController: NSObject {
    private let catalog = WindowCatalog()
    private let keyboard = KeyboardTap()
    private let switcher = SwitcherPanel()
    private var statusItem: NSStatusItem!
    private var preferences: PreferencesWindow?
    private var recordingSearchShortcut = false
    private var recorder: Any?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var session: UUID?
    private var sessionSourcePID: pid_t?
    private var loading = false
    private var searchPinned = false
    private var pendingCommit = false
    private var pendingSteps = 0
    private var paused = UserDefaults.standard.bool(forKey: "switchingPaused")
    private var trusted = false
    private var sampledInitialFocus = false
    private var lastSwitchError: String?
    private var cachedItems: [WindowItem] = []
    private var scanInFlight = false
    private var lastScan = Date.distantPast
    private var scanWaiters: [([WindowItem]) -> Void] = []

    func start() {
        PreferencesWindow.applyAppearance()
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: icon) {
            NSApp.applicationIconImage = image
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "窗序")
        keyboard.onAction = { [weak self] action in
            DispatchQueue.main.async { self?.handle(action) }
        }
        switcher.onWillActivate = { [weak self] in self?.preferences?.suspendIfInBackground() }
        switcher.onDidHide = { [weak self] in self?.preferences?.restoreAfterSwitcher() }
        switcher.onSelect = { [weak self] item in self?.focus(item) }
        switcher.onCancel = { [weak self] in self?.cancel() }
        switcher.onSearch = { [weak self] in
            self?.searchPinned = true
            self?.pendingCommit = false
            self?.keyboard.pinSearch()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.trusted else { return }
            self.catalog.noteFocusedWindow()
            if self.session == nil {
                self.cachedItems = self.immediateWindowItems(applyFilters: false)
                self.refreshWindowSnapshot(force: true)
            }
            if !self.switcher.panel.isVisible { self.preferences?.restoreAfterSwitcher() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkPermission() }
        checkPermission()
        updateMenu()
        UserDefaults.standard.removeObject(forKey: "showSettingsOnLaunch")
        if !trusted { showPreferences() }
    }

    func stop() {
        keyboard.stop()
        timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let recorder { NSEvent.removeMonitor(recorder) }
    }

    private func checkPermission() {
        trusted = AXIsProcessTrusted()
        var ready = false
        if trusted, recorder != nil {
            ready = true
        } else if trusted, !paused {
            if !sampledInitialFocus {
                catalog.noteFocusedWindow()
                sampledInitialFocus = true
            }
            ready = keyboard.start()
        } else {
            keyboard.stop()
            if !trusted { cancel() }
        }
        if trusted, session == nil, recorder == nil { refreshWindowSnapshot() }
        preferences?.update(trusted: trusted, enabled: !paused, ready: ready, shortcut: keyboard.shortcut.label, searchShortcut: keyboard.searchShortcut.label, commitOnRelease: keyboard.commitOnRelease)
    }

    private func handle(_ action: KeyboardTap.Action) {
        guard trusted, !paused, recorder == nil else { return }
        switch action {
        case .next(let reverse):
            if session != nil {
                if loading { pendingSteps += reverse ? -1 : 1 }
                else { switcher.step(reverse: reverse) }
                return
            }
            catalog.cancelPendingReopen()
            catalog.noteFocusedWindow()
            let id = UUID()
            sessionSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            session = id
            keyboard.panelPresented = true
            searchPinned = false
            pendingCommit = false
            pendingSteps = reverse ? -1 : 1
            let immediate = immediateWindowItems()
            loading = cachedItems.isEmpty
            let index = immediate.isEmpty ? 0 : ((pendingSteps % immediate.count) + immediate.count) % immediate.count
            switcher.show(immediate, index: index, searching: false, shortcut: keyboard.shortcut.label,
                          commitOnRelease: keyboard.commitOnRelease, loading: loading)
            refreshWindowSnapshot(force: true) { [weak self] items in
                guard let self, self.session == id else { return }
                if !self.loading {
                    self.switcher.updateItems(self.immediateWindowItems())
                    return
                }
                self.loading = false
                guard !items.isEmpty else {
                    self.cancel()
                    return
                }
                let index = self.searchPinned ? 0 : ((self.pendingSteps % items.count) + items.count) % items.count
                if self.pendingCommit { self.focus(items[index]) }
                else { self.switcher.show(items, index: index, searching: self.searchPinned, shortcut: self.keyboard.shortcut.label, commitOnRelease: self.keyboard.commitOnRelease) }
            }
        case .openSearch:
            searchWindows()
        case .search(let event):
            guard session != nil else { return }
            searchPinned = true
            pendingCommit = false
            switcher.enterSearch(with: event)
        case .commit:
            guard session != nil else { return }
            if loading { pendingCommit = true }
            else { switcher.commit() }
        case .cancel: cancel()
        }
    }

    private func cancel(restoreFocus: Bool = true) {
        catalog.cancelPendingReopen()
        session = nil
        sessionSourcePID = nil
        scanWaiters.removeAll()
        keyboard.panelPresented = false
        loading = false
        pendingCommit = false
        searchPinned = false
        keyboard.finish()
        switcher.hide(restoreFocus: restoreFocus)
    }

    private func localSettingsItems() -> [WindowItem] {
        guard let preferences, preferences.hasOpenSettings, let window = preferences.window else { return [] }
        let app = NSRunningApplication.current
        return [WindowItem(key: "local:settings", pid: app.processIdentifier,
            windowID: window.windowNumber > 0 ? CGWindowID(window.windowNumber) : nil,
            application: app, element: nil, appName: "窗序", title: "窗序 · 设置",
            minimized: window.isMiniaturized, size: window.frame.size)]
    }

    private func focus(_ item: WindowItem) {
        guard ApplicationFilters.shared.allows(item) else { cancel(); return }
        cancel(restoreFocus: false)
        if item.isLocalSettings {
            preferences?.window?.deminiaturize(nil)
            showPreferences()
            return
        }
        catalog.focus(item) { [weak self] error in
            guard let self else { return }
            if let error { self.showResult(error) }
            else {
                self.lastSwitchError = nil
                self.statusItem.button?.toolTip = "窗序"
                self.preferences?.showFeedback("")
                self.updateMenu()
            }
            if !self.switcher.panel.isVisible { self.preferences?.restoreAfterSwitcher() }
        }
    }

    private func showResult(_ message: String) {
        // A failed or unconfirmed focus must not activate our own settings window.
        lastSwitchError = message
        statusItem.button?.toolTip = "窗序：" + message
        preferences?.showFeedback(message)
        updateMenu()
    }

    @objc func searchWindows() {
        guard trusted else { showPreferences(); return }
        if session != nil {
            searchPinned = true
            pendingCommit = false
            keyboard.pinSearch()
            switcher.focusSearch(selectAll: true)
            return
        }
        cancel()
        keyboard.pinSearch()
        let id = UUID()
        sessionSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        session = id
        keyboard.panelPresented = true
        pendingCommit = false
        searchPinned = true
        catalog.noteFocusedWindow()
        let immediate = immediateWindowItems()
        loading = cachedItems.isEmpty
        switcher.show(immediate, index: 0, searching: true, shortcut: keyboard.shortcut.label,
                      commitOnRelease: keyboard.commitOnRelease, loading: loading)
        refreshWindowSnapshot(force: true) { [weak self] items in
            guard let self, self.session == id else { return }
            if self.loading {
                self.loading = false
                self.switcher.show(items, index: 0, searching: true, shortcut: self.keyboard.shortcut.label, commitOnRelease: self.keyboard.commitOnRelease)
            } else { self.switcher.updateItems(self.immediateWindowItems()) }
        }
    }

    /// Main-thread cache delivery. Only one expensive AX scan may be outstanding.
    private func refreshWindowSnapshot(force: Bool = false, completion: (([WindowItem]) -> Void)? = nil) {
        guard trusted else { return }
        if let completion { scanWaiters.append(completion) }
        guard !scanInFlight else { return }
        guard force || Date().timeIntervalSince(lastScan) >= 3 else { return }
        scanInFlight = true
        catalog.load(additionalItems: localSettingsItems()) { [weak self] items in
            guard let self else { return }
            self.cachedItems = items
            self.lastScan = Date()
            self.scanInFlight = false
            let waiters = self.scanWaiters
            self.scanWaiters.removeAll()
            let current = self.immediateWindowItems(applyFilters: false)
            self.cachedItems = current
            let visible = current.filter { ApplicationFilters.shared.allows($0) }
            waiters.forEach { $0(visible) }
        }
    }

    /// Reconcile cached IDs with lightweight system metadata, without AX messages.
    /// This also replaces a newly closed WeChat main window at its original position.
    private func immediateWindowItems(applyFilters: Bool = true) -> [WindowItem] {
        guard !cachedItems.isEmpty else { return [] }
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = Set(rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let settings = localSettingsItems().first
        let live = cachedItems.filter {
            !$0.application.isTerminated && !$0.isLocalSettings && ($0.windowID.map(ids.contains) ?? true)
        }
        var items: [WindowItem] = []
        var seen = Set<String>()
        for old in cachedItems where !old.application.isTerminated {
            let item: WindowItem?
            if old.isLocalSettings { item = settings }
            else if let current = live.first(where: { $0.key == old.key }) { item = current }
            else if old.isWeChatMain, !live.contains(where: { $0.pid == old.pid && $0.isWeChatMain }) {
                item = WindowItem(key: "app:\(old.pid)", pid: old.pid, windowID: nil, application: old.application,
                    element: nil, appName: old.appName, title: old.appName, minimized: false, size: .zero)
            } else { item = nil }
            if let item, seen.insert(item.key).inserted { items.append(item) }
        }
        if let settings, seen.insert(settings.key).inserted { items.append(settings) }
        let foregroundPID = switcher.panel.isVisible ? sessionSourcePID : NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let foregroundPID {
            let firstKnown = rows.first { row in
                (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == foregroundPID &&
                (row[kCGWindowIsOnscreen as String] as? Bool) == true &&
                items.contains { $0.windowID == (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            }
            let frontID = (firstKnown?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            if let index = items.firstIndex(where: { $0.pid == foregroundPID && (frontID == nil || $0.windowID == frontID) }) {
                items.insert(items.remove(at: index), at: 0)
            }
        }
        return applyFilters ? items.filter { ApplicationFilters.shared.allows($0) } : items
    }

    @objc private func togglePause() {
        setEnabled(paused)
    }

    private func setEnabled(_ enabled: Bool) {
        paused = !enabled
        UserDefaults.standard.set(paused, forKey: "switchingPaused")
        cancel()
        checkPermission()
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "窗序 · \(keyboard.shortcut.label)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        if let lastSwitchError {
            let error = NSMenuItem(title: "上次切换：" + lastSwitchError, action: nil, keyEquivalent: "")
            error.isEnabled = false
            menu.addItem(error)
            menu.addItem(.separator())
        }
        for (title, action) in [("搜索窗口…", #selector(searchWindows)), ("设置…", #selector(showPreferences)), (paused ? "恢复快捷键" : "暂停快捷键", #selector(togglePause))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出窗序", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func showPreferences() {
        if session != nil { cancel(restoreFocus: false) }
        if preferences == nil {
            let settings = PreferencesWindow()
            settings.onFiltersChanged = { [weak self] in
                guard let self else { return }
                self.switcher.updateItems(self.immediateWindowItems())
            }
            settings.onClearShortcut = { [weak self] in self?.clearShortcut(search: false) }
            settings.onClearSearchShortcut = { [weak self] in self?.clearShortcut(search: true) }
            settings.onFocused = { [weak self] in
                self?.catalog.noteLocalWindowUse(key: "local:settings", pid: NSRunningApplication.current.processIdentifier)
            }
            settings.onRecord = { [weak self] in self?.recordShortcut() }
            settings.onRecordSearch = { [weak self] in self?.recordShortcut(search: true) }
            settings.onResetSearchShortcut = { [weak self] in
                guard let self else { return }
                self.finishRecording()
                guard !self.sameShortcut(self.keyboard.shortcut, .searchStandard) else {
                    self.preferences?.showFeedback("默认搜索快捷键已被切换快捷键使用，请先调整切换快捷键。")
                    return
                }
                self.keyboard.searchShortcut = .searchStandard
                self.keyboard.searchShortcut.save(prefix: "search")
                self.checkPermission()
                self.updateMenu()
            }
            settings.onResetShortcut = { [weak self] in
                guard let self else { return }
                self.finishRecording()
                guard !self.sameShortcut(self.keyboard.searchShortcut, .standard) else {
                    self.preferences?.showFeedback("默认切换快捷键已被搜索快捷键使用，请先调整搜索快捷键。")
                    return
                }
                self.keyboard.shortcut = .standard
                self.keyboard.shortcut.save()
                self.checkPermission()
                self.updateMenu()
            }
            settings.onCommitModeChange = { [weak self] value in
                self?.keyboard.commitOnRelease = value
                UserDefaults.standard.set(value, forKey: "commitOnRelease")
                self?.checkPermission()
            }
            settings.onPermission = { [weak self] in self?.requestPermission() }
            settings.onSearch = { [weak self] in self?.searchWindows() }
            settings.onEnabledChange = { [weak self] in self?.setEnabled($0) }
            settings.onEndRecording = { [weak self] in self?.finishRecording() }
            preferences = settings
        }
        checkPermission()
        preferences?.present()
    }

    @objc func closeCurrentWindow() {
        if session != nil { cancel() }
        else { preferences?.window?.performClose(nil) }
    }

    @objc func showSettingsSection(_ sender: NSMenuItem) {
        showPreferences()
        preferences?.showSection(sender.tag)
    }

    @objc func showAbout() {
        showPreferences()
        preferences?.showAbout()
    }

    @objc private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func recordShortcut(search: Bool = false) {
        guard recorder == nil else { return }
        recordingSearchShortcut = search
        cancel()
        preferences?.setRecording(true, search: search)
        // Keep an active tap while recording, so reserved system combinations
        // such as Command-Tab can be recorded instead of reaching the Dock.
        _ = keyboard.start()
        keyboard.onRecord = { [weak self] code, flags, name in
            DispatchQueue.main.async { self?.acceptShortcut(code: code, flags: flags, name: name) }
        }
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.preferences?.window else { return event }
            let native = event.modifierFlags.intersection([.command, .option, .control, .shift])
            var flags: CGEventFlags = []
            if native.contains(.command) { flags.insert(.maskCommand) }
            if native.contains(.option) { flags.insert(.maskAlternate) }
            if native.contains(.control) { flags.insert(.maskControl) }
            if native.contains(.shift) { flags.insert(.maskShift) }
            self.acceptShortcut(code: Int64(event.keyCode), flags: flags, name: event.charactersIgnoringModifiers)
            return nil
        }
    }

    private func acceptShortcut(code: Int64, flags: CGEventFlags, name: String?) {
        guard recorder != nil else { return }
        if code == 53 { finishRecording(); return }
        let flags = flags.intersection(SwitchShortcut.relevant)
        guard !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty else {
            preferences?.setRecording(true, search: recordingSearchShortcut, hint: "请同时按住 Option、Command 或 Control。")
            return
        }
        let names: [Int64: String] = [48: "Tab", 49: "Space", 36: "Return", 50: "`", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let shortcut = SwitchShortcut(keyCode: code, modifiers: flags, keyName: names[code] ?? name?.uppercased() ?? "Key \(code)")
        let other = recordingSearchShortcut ? keyboard.shortcut : keyboard.searchShortcut
        guard !sameShortcut(shortcut, other) else {
            preferences?.setRecording(true, search: recordingSearchShortcut, hint: "切换与搜索需要使用不同的快捷键。")
            return
        }
        if recordingSearchShortcut {
            keyboard.searchShortcut = shortcut
            shortcut.save(prefix: "search")
        } else {
            keyboard.shortcut = shortcut
            shortcut.save()
        }
        finishRecording()
    }

    private func clearShortcut(search: Bool) {
        finishRecording()
        cancel()
        if search {
            keyboard.searchShortcut = .unassigned
            keyboard.searchShortcut.save(prefix: "search")
        } else {
            keyboard.shortcut = .unassigned
            keyboard.shortcut.save()
        }
        checkPermission()
        updateMenu()
    }

    private func sameShortcut(_ a: SwitchShortcut, _ b: SwitchShortcut) -> Bool {
        // Shift is reserved for reverse switching, so that variant also conflicts.
        a.isAssigned && b.isAssigned && a.keyCode == b.keyCode && a.modifiers.subtracting(.maskShift) == b.modifiers.subtracting(.maskShift)
    }

    private func finishRecording() {
        guard recorder != nil || keyboard.onRecord != nil else { return }
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        keyboard.onRecord = nil
        preferences?.setRecording(false, search: recordingSearchShortcut)
        checkPermission()
        updateMenu()
    }

}
