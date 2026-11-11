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

    func date(key: String, pid: pid_t, isApplication: Bool, prefersPrimary: Bool, observedAt: Date = .distantPast) -> Date {
        max(observedAt, recordedDate(key: key, pid: pid, isApplication: isApplication, prefersPrimary: prefersPrimary))
    }

    private func recordedDate(key: String, pid: pid_t, isApplication: Bool, prefersPrimary: Bool) -> Date {
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

/// Repeated activation notifications must not erase the actual previous application.
struct ApplicationActivationHistory {
    private(set) var currentPID: pid_t?
    private(set) var previousPID: pid_t?

    mutating func record(pid: pid_t) {
        guard currentPID != pid else { return }
        previousPID = currentPID
        currentPID = pid
    }
}

/// Prefer the actual previous application, then fall back to eligible MRU windows.
enum AutomaticReturnPolicy {
    static func targetPID(previousPID: pid_t?, eligiblePIDs: [pid_t], excludedFallbackPID: pid_t) -> pid_t? {
        if let previousPID, eligiblePIDs.contains(previousPID) { return previousPID }
        return eligiblePIDs.first { $0 != excludedFallbackPID }
    }
}
