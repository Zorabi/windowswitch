// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import XCTest
import CoreGraphics
@testable import WindowSwitch

final class KeyboardTapTests: XCTestCase {
    func testRecordingInterceptsSystemCommandTabWithoutStartingSwitchSession() {
        let tap = KeyboardTap()
        tap.shortcut = .standard
        var recordedCode: Int64?
        tap.onRecord = { code, _, _ in recordedCode = code }
        XCTAssertTrue(tap.receive(.keyDown, event(48, .maskCommand)) == nil)
        XCTAssertEqual(recordedCode, 48)
        XCTAssertFalse(tap.switching)
    }
    private func event(_ code: Int64, _ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.flags = flags
        return event
    }

    func testDefaultDoesNotInterceptSystemCommandTab() {
        let tap = KeyboardTap()
        tap.shortcut = .standard
        XCTAssertTrue(tap.receive(.keyDown, event(48, .maskCommand)) != nil)
        XCTAssertFalse(tap.switching)
    }

    func testOptionTabStartsAndModifierReleaseCommitsExactlyOnce() {
        let tap = KeyboardTap()
        tap.commitOnRelease = true
        tap.shortcut = .standard
        var next = 0
        var committed = 0
        tap.onAction = { action in
            switch action { case .next: next += 1; case .commit: committed += 1; default: break }
        }
        XCTAssertTrue(tap.receive(.keyDown, event(48, .maskAlternate)) == nil)
        XCTAssertTrue(tap.switching)
        _ = tap.receive(.flagsChanged, event(58, []))
        _ = tap.receive(.flagsChanged, event(58, []))
        XCTAssertEqual(next, 1)
        XCTAssertEqual(committed, 1)
        XCTAssertFalse(tap.switching)
    }

    func testReverseSelectionKeepsSessionUntilBaseModifierReleased() {
        let tap = KeyboardTap()
        tap.commitOnRelease = true
        tap.shortcut = .standard
        var reverse: Bool?
        var commits = 0
        tap.onAction = { action in
            if case .next(let value) = action { reverse = value }
            if case .commit = action { commits += 1 }
        }
        XCTAssertTrue(tap.receive(.keyDown, event(48, [.maskAlternate, .maskShift])) == nil)
        XCTAssertEqual(reverse, true)
        _ = tap.receive(.flagsChanged, event(56, .maskAlternate))
        XCTAssertTrue(tap.switching)
        XCTAssertEqual(commits, 0)
        _ = tap.receive(.flagsChanged, event(58, []))
        XCTAssertEqual(commits, 1)
    }

    func testEscapeCancelsWithoutLaterCommit() {
        let tap = KeyboardTap()
        tap.commitOnRelease = true
        tap.shortcut = .standard
        var cancelled = 0
        var committed = 0
        tap.onAction = { action in
            if case .cancel = action { cancelled += 1 }
            if case .commit = action { committed += 1 }
        }
        _ = tap.receive(.keyDown, event(48, .maskAlternate))
        XCTAssertTrue(tap.receive(.keyDown, event(53, .maskAlternate)) == nil)
        _ = tap.receive(.flagsChanged, event(58, []))
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(committed, 0)
    }

    func testCustomShortcutDoesNotKeepInterceptingDefault() {
        let tap = KeyboardTap()
        tap.shortcut = SwitchShortcut(keyCode: 40, modifiers: [.maskControl, .maskCommand], keyName: "K")
        XCTAssertTrue(tap.receive(.keyDown, event(48, .maskAlternate)) != nil)
        XCTAssertTrue(tap.receive(.keyDown, event(40, .maskCommand)) != nil)
        XCTAssertTrue(tap.receive(.keyDown, event(40, [.maskControl, .maskCommand])) == nil)
        XCTAssertTrue(tap.switching)
    }

    func testExtraUnrelatedModifiersAndRegularTypingPassThrough() {
        let tap = KeyboardTap()
        tap.shortcut = .standard
        XCTAssertTrue(tap.receive(.keyDown, event(48, [.maskAlternate, .maskControl])) != nil)
        XCTAssertTrue(tap.receive(.keyDown, event(0, [])) != nil)
        XCTAssertFalse(tap.switching)
    }
}
