// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import AppKit

struct SwitchShortcut {
    let keyCode: Int64
    let modifiers: CGEventFlags
    let keyName: String

    static let unassigned = SwitchShortcut(keyCode: -1, modifiers: [], keyName: "")
    var isAssigned: Bool { keyCode >= 0 && !modifiers.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty }

    static let standard = SwitchShortcut(keyCode: 48, modifiers: .maskAlternate, keyName: "Tab")
    static let searchStandard = SwitchShortcut(keyCode: 49, modifiers: .maskAlternate, keyName: "Space")
    static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    var label: String {
        guard isAssigned else { return "未设置" }
        return [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
            .filter { modifiers.contains($0.0) }.map { $0.1 }.joined() + keyName
    }

    static func load(prefix: String = "switch", fallback: SwitchShortcut = .standard) -> SwitchShortcut {
        let d = UserDefaults.standard
        if d.object(forKey: "\(prefix)Enabled") != nil, !d.bool(forKey: "\(prefix)Enabled") { return .unassigned }
        guard d.object(forKey: "\(prefix)KeyCode") != nil else { return fallback }
        let flags = CGEventFlags(rawValue: UInt64(d.integer(forKey: "\(prefix)Modifiers")))
        guard !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty else { return fallback }
        return SwitchShortcut(keyCode: Int64(d.integer(forKey: "\(prefix)KeyCode")), modifiers: flags, keyName: d.string(forKey: "\(prefix)KeyName") ?? fallback.keyName)
    }

    func save(prefix: String = "switch") {
        UserDefaults.standard.set(isAssigned, forKey: "\(prefix)Enabled")
        guard isAssigned else {
            for suffix in ["KeyCode", "Modifiers", "KeyName"] { UserDefaults.standard.removeObject(forKey: prefix + suffix) }
            return
        }
        UserDefaults.standard.set(Int(keyCode), forKey: "\(prefix)KeyCode")
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: "\(prefix)Modifiers")
        UserDefaults.standard.set(keyName, forKey: "\(prefix)KeyName")
    }
}

final class KeyboardTap {
    enum Action { case next(Bool), commit, cancel, openSearch, search(NSEvent) }
    var onAction: ((Action) -> Void)?
    var onRecord: ((Int64, CGEventFlags, String?) -> Void)?
    var shortcut = SwitchShortcut.load()
    var searchShortcut = SwitchShortcut.load(prefix: "search", fallback: .searchStandard)
    var commitOnRelease = UserDefaults.standard.bool(forKey: "commitOnRelease")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var switching = false
    private var enteringText = false
    private var searchPinned = false
    var panelPresented = false
    private var swallowFindKeyUp = false

    func start() -> Bool {
        if let tap { return CGEvent.tapIsEnabled(tap: tap) }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyboardTap>.fromOpaque(context).takeUnretainedValue().receive(type, event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        switching = false
        enteringText = false
        searchPinned = false
    }

    func finish() { switching = false; enteringText = false; searchPinned = false }
    func pinSearch() { switching = false; searchPinned = true }

    func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, let onRecord {
            onRecord(code, event.flags, NSEvent(cgEvent: event)?.charactersIgnoringModifiers)
            return nil
        }
        if type == .keyUp, code == 3, swallowFindKeyUp {
            swallowFindKeyUp = false
            return nil
        }
        let flags = event.flags.intersection(SwitchShortcut.relevant)
        // Handle the panel command before stripping held switching modifiers
        // for text input, including Cmd+F while Option is still held.
        if panelPresented, code == 3, type == .keyDown, flags.contains(.maskCommand),
           flags.subtracting(.maskCommand).isSubset(of: shortcut.modifiers) {
            swallowFindKeyUp = true
            pinSearch()
            onAction?(.openSearch)
            return nil
        }
        if searchShortcut.isAssigned, code == searchShortcut.keyCode, flags == searchShortcut.modifiers, type != .flagsChanged {
            if type == .keyDown { pinSearch(); onAction?(.openSearch) }
            return nil
        }
        let required = shortcut.modifiers.subtracting(.maskShift)
        if type == .flagsChanged, flags.intersection(required).isEmpty { enteringText = false }
        if type == .flagsChanged, switching, flags.intersection(required) != required {
            switching = false
            if commitOnRelease { onAction?(.commit) }
        }
        let reverseFlags = shortcut.modifiers.symmetricDifference(.maskShift)
        if shortcut.isAssigned, code == shortcut.keyCode, (flags == shortcut.modifiers || flags == reverseFlags), type != .flagsChanged {
            if type == .keyDown {
                switching = !searchPinned
                enteringText = false
                onAction?(.next(flags == reverseFlags))
            }
            return nil
        }
        if switching || enteringText, type == .keyDown {
            if switching && (code == 3 || code == 49) { pinSearch(); onAction?(.openSearch); return nil }
            if code == 53 { finish(); onAction?(.cancel); return nil }
            if code == 36 { finish(); onAction?(.commit); return nil }
            if code == 125 || code == 126 { onAction?(.next(code == 126)); return nil }
            if let native = NSEvent(cgEvent: event) {
                let retained: NSEvent.ModifierFlags = native.modifierFlags.intersection([.shift, .capsLock])
                let characters = native.characters(byApplyingModifiers: retained) ?? ""
                let printable = characters.unicodeScalars.contains { $0.value >= 0x20 && $0.value < 0xF700 }
                if printable || code == 51 || code == 117 {
                    if let input = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: retained,
                        timestamp: native.timestamp, windowNumber: native.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters, isARepeat: native.isARepeat, keyCode: native.keyCode) {
                        pinSearch()
                        enteringText = true
                        onAction?(.search(input))
                        return nil
                    }
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
