// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit
import WindowFocus

private final class SwitchPanel: NSPanel {
    var onClose: (() -> Void)?
    override func performClose(_ sender: Any?) { onClose?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class WindowTable: NSTableView {
    var onMouseSelection: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if selectedRow >= 0 { onMouseSelection?() }
    }
}

private final class WindowRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        ProductStyle.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 10, yRadius: 10).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

private final class WindowCell: NSTableCellView {
    let icon = NSImageView()
    let title = ProductStyle.label("", size: 14, weight: .medium)
    let detail = ProductStyle.label("", size: 12, color: .secondaryLabelColor)
    let badge = ProductStyle.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField = title
        imageView = icon
        for view in [icon, title, detail, badge] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34), icon.heightAnchor.constraint(equalToConstant: 34),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SwitcherPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    var onSelect: ((WindowItem) -> Void)?
    var onCancel: (() -> Void)?
    var onSearch: (() -> Void)?
    var onWillActivate: (() -> Void)?
    var onDidHide: (() -> Void)?
    let panel: NSPanel
    private let search = SearchField()
    private let clearSearch = ProductButton("", kind: .quiet)
    private let table = WindowTable()
    private let count = ProductStyle.label("", size: 12, color: .secondaryLabelColor)
    private let footer = ProductStyle.label("", size: 11, color: .secondaryLabelColor)
    private let empty = ProductStyle.label("", size: 14, weight: .medium, color: .secondaryLabelColor)
    private let emptyDetail = ProductStyle.label("", size: 12, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private var emptyStack: NSStackView!
    private var all: [WindowItem] = []
    private var filtered: [WindowItem] = []
    private var localMonitor: Any?
    private var loading = false
    private var closing = false
    private var previousApplication: NSRunningApplication?
    var selected: WindowItem? {
        filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil
    }

    override init() {
        panel = SwitchPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 548), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "窗序 · 窗口切换"
        panel.level = .floating
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
        (panel as? SwitchPanel)?.onClose = { [weak self] in self?.onCancel?() }
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        // Let AppKit own the window silhouette. A full opaque surface avoids
        // the transparent corner cutouts of the old borderless layer mask.
        let material = SurfaceView()
        material.fill = .windowBackgroundColor
        material.radius = 0
        panel.contentView = material
        let brand = ProductStyle.symbol("rectangle.on.rectangle", size: 16)
        brand.widthAnchor.constraint(equalToConstant: 20).isActive = true
        brand.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let heading = NSTextField(labelWithString: "切换窗口")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let header = ProductStyle.stack([brand, heading], vertical: false, spacing: 8)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right
        count.maximumNumberOfLines = 1
        count.lineBreakMode = .byTruncatingTail
        search.placeholderAttributedString = NSAttributedString(string: "搜索窗口或应用", attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor
        ])
        search.setAccessibilityLabel("搜索窗口或应用")
        search.focusRingType = .none
        search.onMouseFocus = { [weak self] in self?.onSearch?(); self?.setSearchFooter() }
        search.isBezeled = false
        search.drawsBackground = false
        search.font = .systemFont(ofSize: 15)
        search.controlSize = .regular
        search.isBordered = false
        search.isEditable = true
        search.isSelectable = true
        search.usesSingleLineMode = true
        search.lineBreakMode = .byTruncatingTail
        (search.cell as? NSTextFieldCell)?.isScrollable = true
        search.delegate = self
        let searchSurface = SurfaceView()
        searchSurface.radius = 10
        searchSurface.fill = .textBackgroundColor
        let magnifier = ProductStyle.symbol("magnifyingglass", size: 17, color: .secondaryLabelColor)
        clearSearch.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearSearch.contentTintColor = .secondaryLabelColor
        clearSearch.setAccessibilityLabel("清空搜索")
        clearSearch.onPress = { [weak self] in
            guard let self else { return }
            self.search.stringValue = ""
            self.applyFilter(index: 0)
            self.focusSearch()
        }
        for view in [magnifier, search, clearSearch] {
            view.translatesAutoresizingMaskIntoConstraints = false
            searchSurface.addSubview(view)
        }
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 15),
            magnifier.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 18),
            magnifier.heightAnchor.constraint(equalToConstant: 18),
            search.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 11),
            search.trailingAnchor.constraint(equalTo: clearSearch.leadingAnchor, constant: -8),
            search.topAnchor.constraint(equalTo: searchSurface.topAnchor),
            search.bottomAnchor.constraint(equalTo: searchSurface.bottomAnchor),
            clearSearch.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -10),
            clearSearch.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            clearSearch.widthAnchor.constraint(equalToConstant: 26),
            clearSearch.heightAnchor.constraint(equalToConstant: 26)
        ])
        let section = ProductStyle.label("按最近使用排序", size: 11, weight: .medium, color: .secondaryLabelColor)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window")))
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.onMouseSelection = { [weak self] in self?.commit() }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("可切换的窗口，按最近使用排序")
        scroll.documentView = table
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        empty.alignment = .center
        emptyDetail.alignment = .center
        emptyStack = ProductStyle.stack([spinner, empty, emptyDetail], spacing: 10)
        emptyStack.alignment = .centerX
        let separator = NSBox()
        separator.boxType = .separator
        for view in [header, count, searchSurface, section, scroll, separator, footer, emptyStack!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 26),
            header.topAnchor.constraint(equalTo: material.topAnchor, constant: 20),
            count.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -26),
            header.heightAnchor.constraint(equalToConstant: 28),
            header.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -24),
            count.widthAnchor.constraint(equalToConstant: 60),
            count.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchSurface.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 24),
            searchSurface.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -24),
            searchSurface.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            searchSurface.heightAnchor.constraint(equalToConstant: 46),
            section.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            section.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 7),
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -10),
            separator.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 24),
            separator.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -24),
            separator.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -46),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: count.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -17),
            emptyStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyStack.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40)
        ])
    }

    func show(_ items: [WindowItem], index: Int, searching: Bool, shortcut: String, commitOnRelease: Bool = false, loading: Bool = false) {
        let wasVisible = panel.isVisible
        self.loading = loading
        if !wasVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApplication = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        }
        all = items
        if !panel.isVisible || loading { search.stringValue = "" }
        applyFilter(index: index)
        if loading {
            count.stringValue = "读取中"
            empty.stringValue = "正在整理窗口"
            emptyDetail.stringValue = "马上就好…"
            spinner.startAnimation(nil)
        } else { spinner.stopAnimation(nil) }
        footer.stringValue = searching
            ? "直接键入搜索    Tab / ↑ ↓ 选择    ↩ 切换    Esc 取消"
            : (commitOnRelease
                ? "\(shortcut) 选择 · 松开切换    F / 空格 固定搜索    Esc 取消"
                : "按住修饰键时 F / 空格 固定搜索    Tab / ↑ ↓ 选择    ↩ 切换    Esc 取消")
        if !wasVisible, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2 + 25))
        }
        closing = false
        if searching || !commitOnRelease { activateSearchPanel() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        updateCaret()
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                if event.keyCode == 3, event.modifierFlags.contains(.command),
                   event.modifierFlags.intersection([.control, .shift]).isEmpty {
                    self.focusSearch(selectAll: true)
                    return nil
                }
                if (self.search.currentEditor() as? NSTextView)?.hasMarkedText() == true { return event }
                switch event.keyCode {
                case 53: self.onCancel?(); return nil
                case 36: self.commit(); return nil
                case 48:
                    if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                        self.step(reverse: event.modifierFlags.contains(.shift)); return nil
                    }
                    return event
                case 125: self.step(reverse: false); return nil
                case 126: self.step(reverse: true); return nil
                default: return event
                }
            }
        }
    }

    func updateItems(_ items: [WindowItem]) {
        guard panel.isVisible else { return }
        let selectedKey = selected?.key
        all = items
        applyFilter(index: max(0, table.selectedRow), preserving: selectedKey)
    }

    func focusSearch(selectAll: Bool = false) {
        onSearch?()
        setSearchFooter()
        activateSearchPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        updateCaret()
        if selectAll { search.currentEditor()?.selectAll(nil) }
    }

    private func activateSearchPanel() {
        onWillActivate?()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateCaret() {
        (search.currentEditor() as? NSTextView)?.insertionPointColor = ProductStyle.accent
    }

    func controlTextDidBeginEditing(_ notification: Notification) { updateCaret() }

    func enterSearch(with event: NSEvent) {
        focusSearch()
        // Use the native field editor to preserve input-method composition.
        (search.currentEditor() as? NSTextView)?.keyDown(with: event)
    }

    private func setSearchFooter() {
        footer.stringValue = "直接键入搜索    Tab / ↑ ↓ 选择    ↩ 切换    Esc 取消"
    }

    func hide(restoreFocus: Bool = false) {
        closing = true
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if restoreFocus, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
           let previousApplication, !previousApplication.isTerminated {
            _ = WSActivateFrontWindowOnly(previousApplication.processIdentifier)
        }
        previousApplication = nil
        onDidHide?()
    }

    func step(reverse: Bool) {
        guard !filtered.isEmpty else { return }
        let row = (max(0, table.selectedRow) + (reverse ? -1 : 1) + filtered.count) % filtered.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func commit() { if let selected, !loading { onSelect?(selected) } }
    func controlTextDidChange(_ obj: Notification) {
        onSearch?()
        applyFilter(index: 0)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search, !textView.hasMarkedText() else { return false }
        switch NSStringFromSelector(selector) {
        case "insertTab:", "moveDown:": step(reverse: false)
        case "insertBacktab:", "moveUp:": step(reverse: true)
        case "insertNewline:": commit()
        case "cancelOperation:": onCancel?()
        default: return false
        }
        return true
    }
    func windowDidResignKey(_ notification: Notification) { if !closing { onCancel?() } }

    private func applyFilter(index: Int, preserving key: String? = nil) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = all.filter { query.isEmpty || "\($0.appName) \($0.title)".localizedStandardContains(query) }
        table.reloadData()
        clearSearch.isHidden = search.stringValue.isEmpty
        let height: CGFloat = loading ? 548 : max(300, min(548, 206 + CGFloat(filtered.count) * 66))
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: panel.isVisible)
        count.stringValue = "共 \(filtered.count) 项"
        emptyStack.isHidden = !filtered.isEmpty
        empty.stringValue = query.isEmpty ? "暂无可切换的窗口" : "没有匹配的窗口"
        emptyDetail.stringValue = query.isEmpty ? "打开一个应用窗口，然后再试一次。" : "试试其他窗口名称或应用名称。"
        if !filtered.isEmpty {
            let row = key.flatMap { selectedKey in filtered.firstIndex { $0.key == selectedKey } } ?? min(max(index, 0), filtered.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { WindowRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let item = filtered[row]
        let cell = WindowCell(frame: .zero)
        cell.icon.image = item.application.icon
        cell.title.stringValue = item.title
        if item.isLocalSettings {
            cell.detail.stringValue = "窗序"
            cell.badge.stringValue = item.minimized ? "已最小化" : ""
        } else if item.element == nil {
            cell.detail.stringValue = item.application.bundleIdentifier == "com.tencent.xinWeChat" ? "微信 · 重新打开主窗口" : "打开应用"
            cell.badge.stringValue = "重新打开"
        } else {
            cell.detail.stringValue = item.appName
            cell.badge.stringValue = item.minimized ? "已最小化" : ""
        }
        cell.setAccessibilityLabel("\(item.appName)，\(item.title)，\(cell.badge.stringValue)")
        return cell
    }
}
