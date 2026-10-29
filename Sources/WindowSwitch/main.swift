// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let root = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "关于窗序", action: #selector(AppController.showAbout), keyEquivalent: "")
        about.target = controller
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(AppController.showPreferences), keyEquivalent: ",")
        settings.target = controller
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏窗序", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出窗序", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu
        menu.addItem(root)
        let editRoot = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editRoot.submenu = editMenu
        menu.addItem(editRoot)
        let windowRoot = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let search = NSMenuItem(title: "固定搜索…", action: #selector(AppController.searchWindows), keyEquivalent: "f")
        search.target = controller
        windowMenu.addItem(search)
        windowMenu.addItem(withTitle: "最小化设置窗口", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let close = NSMenuItem(title: "关闭窗口", action: #selector(AppController.closeCurrentWindow), keyEquivalent: "w")
        close.target = controller
        windowMenu.addItem(close)
        windowMenu.addItem(.separator())
        for (index, title) in PreferencesWindow.Page.allCases.map(\.title).enumerated() {
            let item = NSMenuItem(title: title, action: #selector(AppController.showSettingsSection(_:)), keyEquivalent: String(index + 1))
            item.target = controller
            item.tag = index
            windowMenu.addItem(item)
        }
        windowRoot.submenu = windowMenu
        menu.addItem(windowRoot)
        NSApp.mainMenu = menu
        controller.start()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showPreferences()
        return false
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let search = NSMenuItem(title: "搜索窗口…", action: #selector(AppController.searchWindows), keyEquivalent: "")
        search.target = controller
        menu.addItem(search)
        let settings = NSMenuItem(title: "设置…", action: #selector(AppController.showPreferences), keyEquivalent: "")
        settings.target = controller
        menu.addItem(settings)
        return menu
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { controller.stop() }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
