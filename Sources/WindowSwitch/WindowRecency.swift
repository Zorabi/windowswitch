// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import Foundation

/// Keeps the last use of a primary window after its temporary window entry disappears.
struct WindowRecency {
    private var windows: [String: Date] = [:]
    private var applications: [pid_t: Date] = [:]
    private var primaryWindows: [pid_t: Date] = [:]

    mutating func recordApplication(pid: pid_t, at date: Date) {
        applications[pid] = max(applications[pid] ?? .distantPast, date)
    }

    mutating func recordWindow(key: String, pid: pid_t, isPrimary: Bool, at date: Date) {
        windows[key] = max(windows[key] ?? .distantPast, date)
        recordApplication(pid: pid, at: date)
        if isPrimary { primaryWindows[pid] = max(primaryWindows[pid] ?? .distantPast, date) }
    }

    func date(key: String, pid: pid_t, isApplication: Bool, prefersPrimary: Bool) -> Date {
        if prefersPrimary, let date = primaryWindows[pid] { return date }
        if isApplication { return applications[pid] ?? .distantPast }
        return windows[key] ?? .distantPast
    }

    mutating func retain(windowKeys: Set<String>, pids: Set<pid_t>) {
        windows = windows.filter { windowKeys.contains($0.key) }
        applications = applications.filter { pids.contains($0.key) }
        primaryWindows = primaryWindows.filter { pids.contains($0.key) }
    }
}
