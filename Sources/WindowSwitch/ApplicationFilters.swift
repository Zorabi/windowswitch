// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit

/// Rules affect WindowSwitch entries only, never another application's reopen behavior.
enum ApplicationFilterMode: String, CaseIterable {
    case allowed, hideReopen, hidden
    var title: String {
        switch self {
        case .allowed: return "不屏蔽"
        case .hideReopen: return "屏蔽重开"
        case .hidden: return "完全屏蔽"
        }
    }
}

final class ApplicationFilters {
    static let shared = ApplicationFilters()
    private let defaults = UserDefaults.standard
    private let rulesKey = "applicationFilterRules"
    private let appsKey = "applicationFilterApps"

    func mode(for bundleID: String) -> ApplicationFilterMode {
        let rules = defaults.dictionary(forKey: rulesKey) as? [String: String] ?? [:]
        if let value = rules[bundleID], let mode = ApplicationFilterMode(rawValue: value) { return mode }
        return bundleID == "com.apple.finder" ? .hideReopen : .allowed
    }

    func set(_ mode: ApplicationFilterMode, for bundleID: String) {
        var rules = defaults.dictionary(forKey: rulesKey) as? [String: String] ?? [:]
        rules[bundleID] = mode.rawValue
        defaults.set(rules, forKey: rulesKey)
    }

    func allows(_ item: WindowItem) -> Bool {
        guard let bundleID = item.application.bundleIdentifier else { return true }
        switch mode(for: bundleID) {
        case .allowed: return true
        case .hideReopen: return item.element != nil || item.isLocalSettings
        case .hidden: return false
        }
    }

    func remember(_ url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        var apps = defaults.dictionary(forKey: appsKey) as? [String: String] ?? [:]
        apps[id] = url.path
        defaults.set(apps, forKey: appsKey)
    }

    struct Application {
        let id: String
        let name: String
        let url: URL?
    }

    func applications() -> [Application] {
        var apps: [String: Application] = [:]
        let stored = defaults.dictionary(forKey: appsKey) as? [String: String] ?? [:]
        for (id, path) in stored {
            let url = URL(fileURLWithPath: path)
            apps[id] = Application(id: id, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""), url: url)
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier else { continue }
            apps[id] = Application(id: id, name: app.localizedName ?? id, url: app.bundleURL)
        }
        if apps["com.apple.finder"] == nil {
            apps["com.apple.finder"] = Application(id: "com.apple.finder", name: "Finder", url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        }
        return apps.values.sorted {
            if $0.id == "com.apple.finder" { return true }
            if $1.id == "com.apple.finder" { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

final class ApplicationFilterPicker: NSPopUpButton {
    var onChange: ((ApplicationFilterMode) -> Void)?
    init(mode: ApplicationFilterMode, onChange: @escaping (ApplicationFilterMode) -> Void) {
        super.init(frame: .zero, pullsDown: false)
        self.onChange = onChange
        addItems(withTitles: ApplicationFilterMode.allCases.map(\.title))
        selectItem(at: ApplicationFilterMode.allCases.firstIndex(of: mode) ?? 0)
        focusRingType = .none
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() {
        guard ApplicationFilterMode.allCases.indices.contains(indexOfSelectedItem) else { return }
        onChange?(ApplicationFilterMode.allCases[indexOfSelectedItem])
    }
}

/// Keep the first application visible when the document grows beyond the viewport.
final class ApplicationFilterListView: NSView {
    override var isFlipped: Bool { true }
}
