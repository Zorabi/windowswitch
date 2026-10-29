// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit
import UniformTypeIdentifiers

final class PreferencesWindow: NSWindowController, NSWindowDelegate {
    enum Page: Int, CaseIterable {
        case general, shortcuts, filters, privacy, about
        var title: String { ["通用", "快捷键", "应用过滤", "权限与隐私", "关于窗序"][rawValue] }
        var symbol: String { ["slider.horizontal.3", "keyboard", "line.3.horizontal.decrease.circle", "hand.raised", "info.circle"][rawValue] }
        var subtitle: String {
            ["以窗口为单位，保持你的工作节奏。", "熟悉的操作，由你定义。", "决定哪些应用和重开入口参与切换。", "只为切换窗口，使用必要的权限。", "让每个窗口，各归其位。"][rawValue]
        }
    }
    var onFiltersChanged: (() -> Void)?
    var onRecord: (() -> Void)?
    var onClearShortcut: (() -> Void)?
    var onClearSearchShortcut: (() -> Void)?
    var onRecordSearch: (() -> Void)?
    var onResetSearchShortcut: (() -> Void)?
    var onResetShortcut: (() -> Void)?
    var onPermission: (() -> Void)?
    var onSearch: (() -> Void)?
    var onCommitModeChange: ((Bool) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?
    var onFocused: (() -> Void)?
    var onEndRecording: (() -> Void)?
    private let content = NSView()
    private let sidebarStatus = ProductStyle.label("准备就绪", size: 11, color: .secondaryLabelColor)
    private let statusIcon = ProductStyle.symbol("checkmark.circle.fill", size: 12, color: .systemGreen)
    private let serviceTitle = ProductStyle.label("窗口切换已开启", size: 14, weight: .semibold)
    private let serviceDetail = ProductStyle.label("", size: 12, color: .secondaryLabelColor)
    private let enabledSwitch = NSSwitch()
    private let permissionTitle = ProductStyle.label("辅助功能已授权", size: 14, weight: .semibold)
    private let permissionDetail = ProductStyle.label("", size: 12, color: .secondaryLabelColor)
    private let permissionButton = ProductButton("打开系统设置")
    private let shortcutButton = ProductButton("⌥Tab")
    private let searchShortcutButton = ProductButton("⌥Space")
    private let shortcutSummary = ProductStyle.label("⌥Tab", size: 23, weight: .medium)
    private let recordingHint = ProductStyle.label("点击上方快捷键，按下新的组合。", size: 12, color: .secondaryLabelColor)
    private let feedback = ProductStyle.label("", size: 12, color: .secondaryLabelColor)
    private var navigation: [ProductButton] = []
    private var page: Page = .general
    private var shortcut = "⌥Tab"
    private var searchShortcut = "⌥Space"
    private var recordingSearch = false
    private var isTrusted = false
    private var isEnabled = true
    private var isReady = false
    private var recording = false
    private var commitOnRelease = false
    private var suspendedForSwitcher = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "窗序"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildShell()
        configureControls()
        select(.general)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func showSection(_ index: Int) { if let page = Page(rawValue: index) { select(page) } }

    func showAbout() { select(.about); present() }

    var hasOpenSettings: Bool { suspendedForSwitcher || window?.isVisible == true || window?.isMiniaturized == true }

    func suspendIfInBackground() {
        guard !suspendedForSwitcher, let window, window.isVisible, !window.isMiniaturized,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        suspendedForSwitcher = true
        window.orderOut(nil)
    }

    func restoreAfterSwitcher() {
        // Restoring while our app is still active can make settings become its
        // next key window. Keep it suspended until the foreground handoff ends.
        guard suspendedForSwitcher,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        suspendedForSwitcher = false
        window?.orderBack(nil)
    }

    func present() {
        suspendedForSwitcher = false
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(trusted: Bool, enabled: Bool, ready: Bool, shortcut: String, searchShortcut: String, commitOnRelease: Bool) {
        isTrusted = trusted
        isEnabled = enabled
        isReady = ready
        self.shortcut = shortcut
        self.searchShortcut = searchShortcut
        self.commitOnRelease = commitOnRelease
        enabledSwitch.state = enabled ? .on : .off
        serviceTitle.stringValue = !trusted ? "完成授权，开始切换" : (enabled ? (ready ? "窗口切换已开启" : "快捷键暂不可用") : "窗口切换已暂停")
        serviceDetail.stringValue = !trusted ? "请在系统设置中允许窗序使用辅助功能。"
            : (enabled ? (ready ? "窗序在菜单栏待命，随时切换到目标窗口。" : "请退出后重新打开窗序，再试一次。") : "开启后即可继续使用切换快捷键。")
        sidebarStatus.stringValue = !trusted ? "等待授权" : (!enabled ? "已暂停" : (ready ? "已就绪" : "需要处理"))
        statusIcon.image = NSImage(systemSymbolName: trusted && enabled && ready ? "checkmark.circle.fill" : "pause.circle", accessibilityDescription: nil)
        statusIcon.contentTintColor = trusted && enabled && ready ? .systemGreen : .secondaryLabelColor
        permissionTitle.stringValue = trusted ? "辅助功能已授权" : "需要辅助功能权限"
        permissionDetail.stringValue = trusted ? "窗序可以读取窗口列表，并聚焦你选择的窗口。" : "用于识别应用窗口、接收切换快捷键和聚焦目标窗口。"
        permissionButton.title = trusted ? "管理权限" : "前往授权"
        shortcutSummary.stringValue = shortcut
        if !recording || recordingSearch { shortcutButton.title = shortcut }
        if !recording || !recordingSearch { searchShortcutButton.title = searchShortcut }
    }

    func setRecording(_ value: Bool, search: Bool = false, hint: String? = nil) {
        recording = value
        recordingSearch = search
        shortcutButton.title = value && !search ? "请按下快捷键…" : shortcut
        searchShortcutButton.title = value && search ? "请按下快捷键…" : searchShortcut
        shortcutButton.selected = value && !search
        searchShortcutButton.selected = value && search
        recordingHint.stringValue = hint ?? (value ? "至少包含 ⌥、⌘ 或 ⌃，按 Esc 取消。" : "点击快捷键即可录制，点“清除”可设为未设置。")
        recordingHint.textColor = value ? ProductStyle.accent : .secondaryLabelColor
    }

    func showFeedback(_ message: String) { feedback.stringValue = message }

    private func buildShell() {
        guard let root = window?.contentView else { return }
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(content)
        feedback.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(feedback)
        feedback.maximumNumberOfLines = 2
        NSLayoutConstraint.activate([
            feedback.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            feedback.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            feedback.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 212),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let name = ProductStyle.label("窗序", size: 22, weight: .semibold)
        let caption = ProductStyle.label("窗口切换工具", size: 11, color: .secondaryLabelColor)
        let brand = ProductStyle.stack([icon, ProductStyle.stack([name, caption], spacing: 3)], vertical: false, spacing: 8)
        let section = ProductStyle.label("偏好设置", size: 11, weight: .medium, color: .secondaryLabelColor)
        let nav = ProductStyle.stack([], spacing: 6)
        for page in Page.allCases {
            let button = ProductButton(page.title, kind: .navigation) { [weak self] in self?.select(page) }
            button.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel(page.title)
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            navigation.append(button)
            nav.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }
        let status = ProductStyle.stack([statusIcon, sidebarStatus], vertical: false, spacing: 7)
        let foot = ProductStyle.stack([status, ProductStyle.label("关闭设置后，仍在菜单栏运行", size: 10, color: .secondaryLabelColor)], spacing: 7)
        for view in [brand, section, nav, foot] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 62),
            section.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 25),
            section.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 38),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            nav.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 12),
            foot.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            foot.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -28)
        ])
    }

    private func configureControls() {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        enabledSwitch.focusRingType = .none
        enabledSwitch.setAccessibilityLabel("启用窗口切换")
        permissionButton.onPress = { [weak self] in self?.onPermission?() }
        shortcutButton.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        shortcutButton.onPress = { [weak self] in self?.onRecord?() }
        shortcutButton.setAccessibilityLabel("录制切换快捷键")
        shortcutButton.widthAnchor.constraint(equalToConstant: 166).isActive = true
        shortcutButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        searchShortcutButton.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        searchShortcutButton.onPress = { [weak self] in self?.onRecordSearch?() }
        searchShortcutButton.setAccessibilityLabel("录制固定搜索快捷键")
        searchShortcutButton.widthAnchor.constraint(equalToConstant: 166).isActive = true
        searchShortcutButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func select(_ page: Page) {
        onEndRecording?()
        self.page = page
        navigation.enumerated().forEach { $0.element.selected = $0.offset == page.rawValue }
        content.subviews.filter { $0 !== feedback }.forEach { $0.removeFromSuperview() }
        let header = ProductStyle.stack([
            ProductStyle.label(page.title, size: 27, weight: .semibold),
            ProductStyle.label(page.subtitle, size: 13, color: .secondaryLabelColor)
        ], spacing: 9)
        let body: NSStackView
        switch page {
        case .general: body = generalPage()
        case .shortcuts: body = shortcutsPage()
        case .filters: body = filtersPage()
        case .privacy: body = privacyPage()
        case .about: body = aboutPage()
        }
        let stack = ProductStyle.stack([header, body], spacing: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 57),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window?.recalculateKeyViewLoop()
    }

    private func card(_ rows: [NSView], spacing: CGFloat = 18) -> NSView {
        let card = SurfaceView()
        let stack = ProductStyle.stack(rows, spacing: spacing)
        ProductStyle.pin(stack, in: card, inset: 20)
        rows.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return card
    }
    private func row(_ title: String, _ detail: String, control: NSView) -> NSView {
        var labels: [NSView] = [ProductStyle.label(title, size: 13, weight: .medium)]
        if !detail.isEmpty { labels.append(ProductStyle.label(detail, size: 12, color: .secondaryLabelColor)) }
        let text = ProductStyle.stack(labels, spacing: 5)
        let row = ProductStyle.stack([text, control], vertical: false, spacing: 24)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }
    private func divider() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }
    private func fit(_ stack: NSStackView) -> NSStackView {
        stack.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func generalPage() -> NSStackView {
        let statusText = ProductStyle.stack([serviceTitle, serviceDetail], spacing: 6)
        let status = ProductStyle.stack([statusText, enabledSwitch], vertical: false, spacing: 20)
        statusText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let change = ProductButton("更改快捷键", kind: .quiet) { [weak self] in self?.select(.shortcuts) }
        let shortcutRow = row("切换快捷键", "打开列表，搜索或选择窗口。", control: ProductStyle.stack([shortcutSummary, change], vertical: false, spacing: 16))
        let appearance = ChoicePicker(labels: ["跟随系统", "浅色", "深色"],
            selected: ["system", "light", "dark"].firstIndex(of: UserDefaults.standard.string(forKey: "appearance") ?? "system") ?? 0) { index in
                UserDefaults.standard.set(["system", "light", "dark"][index], forKey: "appearance")
                Self.applyAppearance()
            }
        let confirmation = ChoicePicker(labels: ["回车确认", "松开即切换"],
            selected: UserDefaults.standard.bool(forKey: "commitOnRelease") ? 1 : 0) { [weak self] index in
                self?.onCommitModeChange?(index == 1)
            }
        let browse = ProductButton("打开窗口列表", kind: .primary) { [weak self] in self?.onSearch?() }
        let bottom = ProductStyle.stack([
            ProductStyle.label("在菜单栏点击窗序图标，也可以搜索窗口或暂停切换。", size: 12, color: .secondaryLabelColor), browse
        ], vertical: false, spacing: 20)
        return fit(ProductStyle.stack([
            card([status]),
            card([shortcutRow, divider(), row("切换方式", "回车确认时，无需一直按住修饰键。", control: confirmation), divider(), row("外观", "选择适合当前环境的界面。", control: appearance)]),
            bottom
        ], spacing: 18))
    }

    private func shortcutsPage() -> NSStackView {
        let reset = ProductButton("恢复默认", kind: .quiet) { [weak self] in self?.onResetShortcut?() }
        let resetSearch = ProductButton("恢复默认", kind: .quiet) { [weak self] in self?.onResetSearchShortcut?() }
        let clear = ProductButton("清除", kind: .quiet) { [weak self] in self?.onClearShortcut?() }
        let clearSearch = ProductButton("清除", kind: .quiet) { [weak self] in self?.onClearSearchShortcut?() }
        let switching = ProductStyle.stack([shortcutButton, reset, clear], vertical: false, spacing: 8)
        let searching = ProductStyle.stack([searchShortcutButton, resetSearch, clearSearch], vertical: false, spacing: 8)
        return fit(ProductStyle.stack([
            card([
                row("切换窗口", "遵循通用设置中的切换方式。", control: switching),
                divider(),
                row("固定搜索", "按一次打开，松开修饰键后继续输入。", control: searching),
                recordingHint
            ], spacing: 16),
            card([
                row("选择窗口", "", control: ProductStyle.label("Tab / ⇧Tab / ↑ ↓", size: 12, weight: .medium)),
                divider(),
                row("确认与取消", "", control: ProductStyle.label("↩ 切换 · Esc 取消 · ⌘W 关闭", size: 12, weight: .medium)),
                divider(),
                row("转入固定搜索", "松键模式下也不必一直按住修饰键。", control: ProductStyle.label("搜索快捷键 / 空格 / ⌘F", size: 12, weight: .medium))
            ], spacing: 14),
            ProductStyle.label("⌘, 设置    ⌘1–5 设置页面    ⌘M 最小化设置    ⌘Q 退出", size: 12, color: .secondaryLabelColor),
            ProductStyle.label("设置为 ⌘Tab 会接管系统应用切换。按住切换修饰键时，按 F 或空格，即可松开修饰键继续搜索。", size: 12, color: .secondaryLabelColor)
        ], spacing: 18))
    }

    private func filtersPage() -> NSStackView {
        let filters = ApplicationFilters.shared
        let list = ProductStyle.stack([], spacing: 0)
        for app in filters.applications() {
            let icon = NSImageView(image: app.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            let name = ProductStyle.label(app.name, size: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let picker = ApplicationFilterPicker(mode: filters.mode(for: app.id)) { [weak self] mode in
                if let url = app.url { filters.remember(url) }
                filters.set(mode, for: app.id)
                self?.onFiltersChanged?()
            }
            picker.setAccessibilityLabel("\(app.name)的过滤方式")
            picker.widthAnchor.constraint(equalToConstant: 124).isActive = true
            let entry = ProductStyle.stack([icon, name, picker], vertical: false, spacing: 12)
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            entry.heightAnchor.constraint(equalToConstant: 50).isActive = true
            list.addArrangedSubview(entry)
            entry.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = ApplicationFilterListView()
        scroll.documentView = document
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        let surface = SurfaceView()
        ProductStyle.pin(scroll, in: surface, inset: 0)
        let add = ProductButton("添加应用…", kind: .quiet) { [weak self] in
            guard let self, let window = self.window else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = "添加"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                filters.remember(url)
                self?.select(.filters)
            }
        }
        return fit(ProductStyle.stack([
            surface,
            ProductStyle.label("屏蔽重开：保留已有窗口，隐藏没有窗口时的打开入口。\n完全屏蔽：该应用的所有条目均不参与切换和搜索。", size: 12, color: .secondaryLabelColor),
            add,
            ProductStyle.label("显示正在运行及已添加的应用，规则自动保存，仅影响窗序。", size: 12, color: .secondaryLabelColor)
        ], spacing: 16))
    }

    private func privacyPage() -> NSStackView {
        let permission = ProductStyle.stack([ProductStyle.stack([permissionTitle, permissionDetail], spacing: 6), permissionButton], vertical: false, spacing: 20)
        permission.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        func privacyRow(_ icon: String, _ title: String, _ detail: String) -> NSView {
            let symbol = ProductStyle.symbol(icon, size: 19)
            symbol.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return ProductStyle.stack([symbol, ProductStyle.stack([ProductStyle.label(title, size: 13, weight: .medium), ProductStyle.label(detail, size: 12, color: .secondaryLabelColor)], spacing: 5)], vertical: false, spacing: 12)
        }
        return fit(ProductStyle.stack([
            card([permission]),
            card([
                privacyRow("rectangle.slash", "无需屏幕录制", "使用窗口名称与应用图标，不截取屏幕画面。"), divider(),
                privacyRow("internaldrive", "数据保留在本机", "不上传窗口信息；诊断记录不包含窗口标题或聊天内容。"), divider(),
                privacyRow("cursorarrow.click", "由你决定切换目标", "只有选择窗口后，窗序才会发出聚焦或打开请求。")
            ])
        ], spacing: 18))
    }

    private func aboutPage() -> NSStackView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let brand = ProductStyle.stack([icon, ProductStyle.stack([
            ProductStyle.label("窗序", size: 24, weight: .semibold),
            ProductStyle.label("WindowSwitch · 版本 \(version) (\(build))", size: 12, color: .secondaryLabelColor),
            ProductStyle.label("轻巧、直接的 macOS 窗口切换工具。", size: 13, color: .secondaryLabelColor)
        ], spacing: 7)], vertical: false, spacing: 18)
        let license = ProductButton("查看开源许可证", kind: .quiet) {
            if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(url) }
        }
        return fit(ProductStyle.stack([
            card([brand]),
            card([
                row("以窗口为单位", "", control: ProductStyle.symbol("rectangle.on.rectangle", size: 19)),
                divider(),
                row("按最近使用排序", "返回刚用过的窗口；关闭主窗口后保留原有切换顺序。", control: ProductStyle.symbol("clock.arrow.circlepath", size: 19))
            ]),
            ProductStyle.label("需要 macOS 13 或更高版本。窗口可见性和聚焦效果取决于目标应用与系统提供的能力。", size: 12, color: .secondaryLabelColor),
            license,
            ProductStyle.label("Copyright © 2026 dongx · AGPL-3.0-only", size: 11, color: .secondaryLabelColor)
        ], spacing: 18))
    }

    @objc private func toggleEnabled() { onEnabledChange?(enabledSwitch.state == .on) }
    func windowDidBecomeKey(_ notification: Notification) { onFocused?() }
    func windowDidResignKey(_ notification: Notification) { onEndRecording?() }
    func windowWillClose(_ notification: Notification) { onEndRecording?() }
}
