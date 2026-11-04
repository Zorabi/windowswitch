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
    private var actionReceivedAt: TimeInterval?
    private var cachedItems: [WindowItem] = []
    private var displayRecency = WindowRecency()
    private var observedFocus: [pid_t: (key: String, date: Date)] = [:]
    private var scanInFlight = false
    private var lastScan = Date.distantPast
    private var scanWaiters: [([WindowItem]) -> Void] = []
    private struct CloseWindowHandoff {
        let id = UUID()
        let source: NSRunningApplication
        let windowID: CGWindowID
        let startedAt = ProcessInfo.processInfo.systemUptime
        var targetPID: pid_t?
        var deferredActions: [KeyboardTap.Action] = []
    }
    private var closeWindowHandoff: CloseWindowHandoff?

    func start() {
        PreferencesWindow.applyAppearance()
        _ = SwitchStatistics.shared
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: icon) {
            NSApp.applicationIconImage = image
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "窗序")
        catalog.onWindowFocused = { [weak self] item, date in
            self?.recordDisplayUse(item, at: date)
        }
        keyboard.onAction = { [weak self] action in
            let receivedAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self else { return }
                self.actionReceivedAt = receivedAt
                defer { self.actionReceivedAt = nil }
                self.handle(action)
            }
        }
        keyboard.onCloseShortcut = { [weak self] in self?.prepareCloseWindowHandoff() }
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
            if let handoff = self.closeWindowHandoff,
               let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               pid != handoff.source.processIdentifier, pid != handoff.targetPID {
                self.cancelCloseWindowHandoff()
            }
            self.recordForegroundWindowUse()
            self.catalog.noteFocusedWindow()
            if self.session == nil {
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
        cancelCloseWindowHandoff()
        catalog.cancelPendingFocus()
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
        if case .next = action, let handoff = closeWindowHandoff, handoff.targetPID == nil {
            returnFocusAfterClose(handoff.id)
        }
        if closeWindowHandoff?.targetPID != nil {
            switch action {
            case .next:
                closeWindowHandoff?.deferredActions.append(action)
                return
            case .commit, .search:
                if closeWindowHandoff?.deferredActions.isEmpty == false {
                    closeWindowHandoff?.deferredActions.append(action)
                    return
                }
            default: break
            }
        }
        cancelCloseWindowHandoff()
        switch action {
        case .next(let reverse):
            if session != nil {
                if loading { pendingSteps += reverse ? -1 : 1 }
                else { switcher.step(reverse: reverse) }
                return
            }
            catalog.cancelPendingFocus()
            recordForegroundWindowUse()
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
            let index = initialSelectionIndex(in: immediate, steps: pendingSteps)
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
                let index = self.searchPinned ? 0 : self.initialSelectionIndex(in: items, steps: self.pendingSteps)
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

    private func cancel(restoreFocus: Bool = true, keepPanelForHandoff: Bool = false) {
        cancelCloseWindowHandoff()
        catalog.cancelPendingFocus()
        session = nil
        sessionSourcePID = nil
        scanWaiters.removeAll()
        keyboard.panelPresented = false
        loading = false
        pendingCommit = false
        searchPinned = false
        keyboard.finish()
        if !keepPanelForHandoff { switcher.hide(restoreFocus: restoreFocus) }
    }

    private func cancelCloseWindowHandoff() {
        if closeWindowHandoff?.targetPID != nil { catalog.cancelPendingFocus() }
        closeWindowHandoff = nil
    }

    private func prepareCloseWindowHandoff() {
        guard trusted, !paused, recorder == nil, session == nil, !switcher.panel.isVisible,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        if let bundleID = app.bundleIdentifier, ApplicationFilters.shared.mode(for: bundleID) == .hidden { return }
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = rows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
        }
        guard let windowID = visibleWindowIDs(in: windows).first else { return }
        cancelCloseWindowHandoff()
        let handoff = CloseWindowHandoff(source: app, windowID: windowID)
        closeWindowHandoff = handoff
        // Give the original key event time to reach the application. Poll only
        // this bounded close request; the normal catalog scan interval is unchanged.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.returnFocusAfterClose(handoff.id)
        }
    }

    private func returnFocusAfterClose(_ id: UUID) {
        guard let handoff = closeWindowHandoff, handoff.id == id, handoff.targetPID == nil else { return }
        guard trusted, !paused, recorder == nil, session == nil, !switcher.panel.isVisible,
              ProcessInfo.processInfo.systemUptime - handoff.startedAt < 0.6,
              !handoff.source.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == handoff.source.processIdentifier else {
            cancelCloseWindowHandoff()
            return
        }
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let remaining = rows.filter { row in
            (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == handoff.source.processIdentifier
        }
        // Some applications keep closed windows registered with WindowServer.
        // Only visible windows block handoff, including uncached confirmations.
        let remainingIDs = visibleWindowIDs(in: remaining)
        let originalStillVisible = remainingIDs.contains(handoff.windowID)
        let hasOtherVisibleWindow = remainingIDs.contains { $0 != handoff.windowID }
        if originalStillVisible || hasOtherVisibleWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.returnFocusAfterClose(id)
            }
            return
        }
        let visibleIDs = Set(visibleWindowIDs(in: rows))
        let items = immediateWindowItems(applyFilters: false)
        cachedItems = items
        guard let target = items.first(where: {
            $0.pid != handoff.source.processIdentifier && $0.canRepresentForegroundWindow &&
            !$0.minimized && !$0.application.isHidden &&
            $0.windowID.map(visibleIDs.contains) == true && ApplicationFilters.shared.allows($0)
        }) else {
            cancelCloseWindowHandoff()
            return
        }
        closeWindowHandoff?.targetPID = target.pid
        let finish = { [weak self] in
            guard self?.closeWindowHandoff?.id == id else { return }
            self?.resumeSwitchingAfterClose(id)
            guard self?.closeWindowHandoff?.id == id else { return }
            self?.closeWindowHandoff = nil
        }
        if target.isLocalSettings, let preferences {
            let startedAt = ProcessInfo.processInfo.systemUptime
            preferences.present()
            DispatchQueue.main.async { [weak self, weak preferences] in
                guard self?.closeWindowHandoff?.id == id else { return }
                if preferences?.window?.isKeyWindow == true, NSApp.isActive {
                    SwitchStatistics.shared.record(origin: .automaticReturn, isReopen: false,
                        outcome: "confirmed", milliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                }
                finish()
            }
        } else {
            catalog.focus(target, origin: .automaticReturn, onFronted: { [weak self] in
                self?.resumeSwitchingAfterClose(id)
            }) { _ in finish() }
        }
    }

    private func visibleWindowIDs(in rows: [[String: Any]]) -> [CGWindowID] {
        rows.compactMap { row in
            guard (row[kCGWindowIsOnscreen as String] as? Bool) == true,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.05,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 70, rect.height >= 70 else { return nil }
            return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    private func resumeSwitchingAfterClose(_ id: UUID) {
        guard let handoff = closeWindowHandoff, handoff.id == id,
              !handoff.deferredActions.isEmpty else { return }
        closeWindowHandoff = nil
        handoff.deferredActions.forEach { handle($0) }
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
        let requestedAt = actionReceivedAt ?? ProcessInfo.processInfo.systemUptime
        cancel(restoreFocus: false, keepPanelForHandoff: !item.isLocalSettings)
        if item.isLocalSettings {
            preferences?.window?.deminiaturize(nil)
            showPreferences()
            return
        }
        let releasePanel = switcher.beginFocusHandoff { [weak self] reason in
            self?.catalog.notePanelRelease(reason)
        }
        catalog.focus(item, requestedAt: requestedAt, onFronted: releasePanel) { [weak self] error in
            releasePanel()
            guard let self, self.session == nil else { return }
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
        recordForegroundWindowUse()
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
            let livePIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            self.displayRecency.retain(windowKeys: Set(items.map(\.key)), pids: livePIDs)
            self.observedFocus = self.observedFocus.filter { livePIDs.contains($0.key) }
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
    /// Closed windows become eligible application entries without waiting for AX.
    private func immediateWindowItems(applyFilters: Bool = true) -> [WindowItem] {
        guard !cachedItems.isEmpty else { return [] }
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = Set(rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let settings = localSettingsItems().first
        let live = cachedItems.filter {
            !$0.application.isTerminated && !$0.isLocalSettings && ($0.windowID.map(ids.contains) ?? true)
        }
        let liveWindows = Dictionary(grouping: live.filter { !$0.isApplicationEntry }, by: \.pid)
        var items: [WindowItem] = []
        var seen = Set<String>()
        for old in cachedItems where !old.application.isTerminated {
            let item: WindowItem?
            if old.isLocalSettings { item = settings }
            else {
                let titles = (liveWindows[old.pid] ?? []).map(\.title)
                let includesReopen = old.policy.shouldIncludeApplicationEntry(
                    isRegular: old.application.activationPolicy == .regular, windowTitles: titles)
                if old.isApplicationEntry { item = includesReopen ? old : nil }
                else if let current = live.first(where: { $0.key == old.key }) { item = current }
                else if includesReopen, old.isPrimaryWindow || old.policy.primaryWindowTitles.isEmpty {
                    item = old.applicationReopenEntry
                } else { item = nil }
            }
            if let item, seen.insert(item.key).inserted { items.append(item) }
        }
        if let settings, seen.insert(settings.key).inserted { items.append(settings) }
        items = items.enumerated().sorted { left, right in
            let leftDate = displayRecency.date(key: left.element.key, pid: left.element.pid,
                isApplication: left.element.element == nil, prefersPrimary: left.element.isPrimaryWindow)
            let rightDate = displayRecency.date(key: right.element.key, pid: right.element.pid,
                isApplication: right.element.element == nil, prefersPrimary: right.element.isPrimaryWindow)
            return leftDate == rightDate ? left.offset < right.offset : leftDate > rightDate
        }.map(\.element)
        let foregroundPID = switcher.panel.isVisible ? sessionSourcePID : NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let foregroundPID {
            let firstKnown = rows.first { row in
                (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == foregroundPID &&
                (row[kCGWindowIsOnscreen as String] as? Bool) == true &&
                items.contains { $0.windowID == (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            }
            let frontID = (firstKnown?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            let observedIndex = observedFocus[foregroundPID].flatMap { focus in
                items.firstIndex {
                    $0.pid == foregroundPID && $0.key == focus.key &&
                    $0.canRepresentForegroundWindow
                }
            }
            // An application can remain the foreground process briefly after Cmd+W.
            // Reopen actions keep their MRU rank instead of being fronted.
            let index = observedIndex ?? items.firstIndex(where: {
                $0.pid == foregroundPID && $0.canRepresentForegroundWindow &&
                (frontID == nil || $0.windowID == frontID)
            })
            if let index { items.insert(items.remove(at: index), at: 0) }
        }
        return applyFilters ? items.filter { ApplicationFilters.shared.allows($0) } : items
    }

    private func recordDisplayUse(_ item: WindowItem, at date: Date) {
        guard !item.application.isTerminated else { return }
        displayRecency.recordWindow(key: item.key, pid: item.pid, isPrimary: item.isPrimaryWindow, at: date)
        if date >= (observedFocus[item.pid]?.date ?? .distantPast) {
            observedFocus[item.pid] = (item.key, date)
        }
        // Delivery reconciles and sorts the cache when needed. Focus notifications
        // only update history, so window scanning cannot delay the panel handoff.
    }

    private func recordForegroundWindowUse() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = rows.first { row in
            (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier &&
            cachedItems.contains { $0.windowID == (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
        let id = (front?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        let observed = observedFocus[app.processIdentifier].flatMap { focus in
            cachedItems.first { $0.pid == app.processIdentifier && $0.key == focus.key &&
                ($0.windowID.map { knownID in rows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == knownID } } ?? false) }
        }
        let frontItem = id.flatMap { id in cachedItems.first { $0.pid == app.processIdentifier && $0.windowID == id } }
        if let item = observed ?? frontItem, catalog.shouldRecordWindowUse(item) {
            recordDisplayUse(item, at: Date())
        }
    }

    private func initialSelectionIndex(in items: [WindowItem], steps: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        // If the current application was filtered out, the most recent eligible
        // window is already the first alternative; do not skip it.
        let offset = items.first?.pid == sessionSourcePID || steps <= 0 ? steps : steps - 1
        return ((offset % items.count) + items.count) % items.count
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
        catalog.cancelPendingFocus()
        if session != nil || switcher.panel.isVisible { cancel(restoreFocus: false) }
        if preferences == nil {
            let settings = PreferencesWindow()
            settings.onFiltersChanged = { [weak self] in
                guard let self else { return }
                self.switcher.updateItems(self.immediateWindowItems())
            }
            settings.onClearShortcut = { [weak self] in self?.clearShortcut(search: false) }
            settings.onClearSearchShortcut = { [weak self] in self?.clearShortcut(search: true) }
            settings.onFocused = { [weak self] in
                guard let self else { return }
                self.catalog.noteLocalWindowUse(key: "local:settings", pid: NSRunningApplication.current.processIdentifier)
                if let item = self.localSettingsItems().first { self.recordDisplayUse(item, at: Date()) }
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
        guard NSApp.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier,
              let keyWindow = NSApp.keyWindow else { return }
        if keyWindow === switcher.panel, session != nil {
            cancel()
        } else if let settings = preferences?.window {
            if let sheet = settings.attachedSheet, keyWindow === sheet {
                settings.endSheet(sheet, returnCode: .cancel)
            } else if keyWindow === settings, settings.attachedSheet == nil {
                settings.performClose(nil)
            }
        }
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
