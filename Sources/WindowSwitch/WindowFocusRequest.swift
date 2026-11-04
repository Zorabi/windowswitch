// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
import Foundation

/// A request remains cancellable across the WindowServer and AX queues.
final class WindowFocusRequest {
    let pid: pid_t
    private var windowID: UInt32?
    let startedAt: TimeInterval
    private let origin: WindowFocusOrigin
    private let isReopen: Bool
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var stages: [[String: Any]] = []
    private let diagnosticFile: String
    private static let outputQueue = DispatchQueue(label: "dongx.windowswitch.focus-diagnostics", qos: .utility)
    // Accessed only on outputQueue; a late old request cannot replace newer evidence.
    private static var newestStarts: [String: TimeInterval] = [:]

    init(pid: pid_t, windowID: UInt32?, startedAt: TimeInterval, diagnosticFile: String,
         origin: WindowFocusOrigin, isReopen: Bool) {
        self.pid = pid
        self.windowID = windowID
        self.startedAt = startedAt
        self.diagnosticFile = diagnosticFile
        self.origin = origin
        self.isReopen = isReopen
        mark("main_received")
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !finished
    }

    var targetWindowID: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return windowID
    }

    var age: TimeInterval { ProcessInfo.processInfo.systemUptime - startedAt }

    func updateTarget(_ id: UInt32?) {
        lock.lock()
        windowID = id
        lock.unlock()
    }

    func mark(_ name: String, result: Int32? = nil, windowID: UInt32? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        var stage: [String: Any] = ["phase": name, "elapsedMs": age * 1000]
        if let result { stage["result"] = result }
        if let windowID { stage["focusedWindowID"] = windowID }
        stages.append(stage)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish("cancelled")
    }

    func finish(_ outcome: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let resolvedOutcome = cancelled ? "cancelled" : outcome
        let milliseconds = age * 1000
        let snapshot: [String: Any] = [
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": pid, "windowID": windowID ?? 0, "outcome": resolvedOutcome,
            "elapsedMs": milliseconds, "stages": stages, "origin": origin.rawValue,
            "isReopen": isReopen
        ]
        lock.unlock()
        SwitchStatistics.shared.record(origin: origin, isReopen: isReopen,
                                       outcome: resolvedOutcome, milliseconds: milliseconds)
        let start = startedAt
        let filename = diagnosticFile
        Self.outputQueue.async {
            guard start >= (Self.newestStarts[filename] ?? 0) else { return }
            Self.newestStarts[filename] = start
            guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("dongx.windowswitch") else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            } catch { /* Timing evidence must never interfere with focus. */ }
        }
    }
}
