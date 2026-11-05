// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import Foundation

enum WindowFocusOrigin: String {
    case switcher, automaticReturn
}

/// Aggregate counters only. All updates and persistence stay off the focus queues.
final class SwitchStatistics {
    static let shared = SwitchStatistics()

    struct Snapshot: Codable {
        var since = Date()
        var today = Date()
        var todaySwitches = 0
        var switches = 0
        var reopens = 0
        var automaticReturns = 0
        private var storedAutomaticReturnFailures: Int?
        var automaticReturnFailures: Int { storedAutomaticReturnFailures ?? 0 }

        mutating func recordAutomaticReturnFailure() {
            storedAutomaticReturnFailures = automaticReturnFailures + 1
        }
        var totalMilliseconds: Double = 0
        var lastMilliseconds: Double?
        var longestMilliseconds: Double?

        var averageMilliseconds: Double? {
            switches == 0 ? nil : totalMilliseconds / Double(switches)
        }

        mutating func updateDay(_ now: Date) {
            if !Calendar.current.isDate(today, inSameDayAs: now) {
                today = now
                todaySwitches = 0
            }
        }
    }

    private let queue = DispatchQueue(label: "dongx.windowswitch.statistics", qos: .utility)
    private let key = "switchStatistics.v1"
    private var state: Snapshot

    private init() {
        state = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    }

    func record(origin: WindowFocusOrigin, isReopen: Bool, outcome: String, milliseconds: Double) {
        let succeeded = outcome == "confirmed" || outcome == "application_opened"
        let failedReturn = origin == .automaticReturn && outcome != "cancelled" && outcome != "foreground_changed"
        guard (succeeded || failedReturn), milliseconds.isFinite, milliseconds >= 0 else { return }
        let finishedAt = Date()
        queue.async { [self] in
            state.updateDay(Date())
            switch origin {
            case .switcher:
                state.switches += 1
                if Calendar.current.isDate(finishedAt, inSameDayAs: state.today) { state.todaySwitches += 1 }
                if isReopen { state.reopens += 1 }
                state.totalMilliseconds += milliseconds
                state.lastMilliseconds = milliseconds
                state.longestMilliseconds = max(state.longestMilliseconds ?? 0, milliseconds)
            case .automaticReturn:
                if succeeded { state.automaticReturns += 1 }
                else { state.recordAutomaticReturnFailure() }
            }
            persist()
        }
    }

    func snapshot(_ completion: @escaping (Snapshot) -> Void) {
        queue.async { [self] in
            state.updateDay(Date())
            let snapshot = state
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func reset(_ completion: @escaping () -> Void) {
        queue.async { [self] in
            state = Snapshot()
            persist()
            DispatchQueue.main.async { completion() }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: key) }
    }
}
