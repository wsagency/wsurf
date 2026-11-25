// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import MCP

/// Who may run a call now. A call holds the lanes of what it touches: the tab it acts on, and the one global lane when it can
/// show a sheet or move what the person sees (`requestAccess`, `requestUserLogin`, `switchTab`, `newTab`, `navigate`...). Calls on
/// different tabs run side by side; calls on one tab, from any connection, run one at a time in arrival order. Each lane queues at
/// most `queueLimit` waiting calls and refuses the next, so a client that floods one tab is told to wait instead of piling up work.
///
/// Lanes are always taken in one order (global first, then tabs by ID), so two calls never wait on each other.
@MainActor
final class MCPCallLanes {
    nonisolated enum Lane: Hashable, Comparable, Sendable {
        case global
        case tab(UUID)

        static func < (lhs: Lane, rhs: Lane) -> Bool {
            switch (lhs, rhs) {
            case (.global, .tab):
                true
            case (.tab(let a), .tab(let b)):
                a.uuidString < b.uuidString
            default:
                false
            }
        }
    }

    nonisolated enum Admission: Equatable, Sendable {
        case admitted
        /// The lane already has `queueLimit` calls waiting.
        case full
        /// The call was cancelled, or its connection ended or lost the tab, while it waited.
        case cancelled
    }

    nonisolated static let queueLimit = 4

    private struct Waiter {
        let id: UUID
        let session: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var busy: Set<Lane> = []
    private var waiting: [Lane: [Waiter]] = [:]

    /// How many calls wait for `lane` now. For tests and diagnostics.
    func queued(_ lane: Lane) -> Int {
        waiting[lane]?.count ?? 0
    }

    func isBusy(_ lane: Lane) -> Bool {
        busy.contains(lane)
    }

    /// Takes every lane in `lanes`, waiting in line for each. On anything but `.admitted` nothing is held.
    func acquire(_ lanes: [Lane], session: UUID) async -> Admission {
        var held: [Lane] = []
        for lane in Set(lanes).sorted() {
            let admission = await acquire(lane, session: session)
            guard admission == .admitted else {
                release(held)
                return admission
            }
            held.append(lane)
        }
        return .admitted
    }

    private func acquire(_ lane: Lane, session: UUID) async -> Admission {
        guard busy.contains(lane) else {
            busy.insert(lane)
            return .admitted
        }
        guard queued(lane) < Self.queueLimit else { return .full }
        let id = UUID()
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting[lane, default: []].append(Waiter(id: id, session: session, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dropWaiters { waiter, _ in waiter.id == id } }
        }
        return admitted ? .admitted : .cancelled
    }

    /// Gives each lane to the next call waiting for it, or frees it.
    func release(_ lanes: [Lane]) {
        for lane in Set(lanes) {
            if var queue = waiting[lane], !queue.isEmpty {
                let next = queue.removeFirst()
                waiting[lane] = queue.isEmpty ? nil : queue
                // The lane stays busy: it now belongs to `next`.
                next.continuation.resume(returning: true)
            } else {
                busy.remove(lane)
            }
        }
    }

    /// Ends the waiting calls of `session` (on `lane` only, when given): each one returns `.cancelled` without running.
    func drain(session: UUID, lane: Lane? = nil) {
        dropWaiters { waiter, waitingLane in waiter.session == session && (lane == nil || lane == waitingLane) }
    }

    private func dropWaiters(_ matches: (Waiter, Lane) -> Bool) {
        for (lane, queue) in waiting {
            let (gone, kept) = (queue.filter { matches($0, lane) }, queue.filter { !matches($0, lane) })
            guard !gone.isEmpty else { continue }
            waiting[lane] = kept.isEmpty ? nil : kept
            gone.forEach { $0.continuation.resume(returning: false) }
        }
    }
    // MARK: Which lanes a call takes

    /// Tools that can put a sheet in front of the person or change what the window shows, so only one runs at a time.
    nonisolated static let globalTools: Set<String> = [
        "requestAccess", "requestUserLogin", "switchTab", "newTab", "navigate", "openComparison", "compareTabs", "closeTab",
        "browser_navigate", "browser_navigate_back", "browser_tabs", "browser_close",
    ]

    /// Tools that touch no tab and no sheet: they run at once.
    nonisolated static let freeTools: Set<String> = ["listTabs"]

    /// The lanes a call of `name` with `arguments` takes. A Playwright name acts on the connection's current tab.
    nonisolated static func lanes(tool name: String, arguments: [String: Value], playwrightTab: UUID?) -> [Lane] {
        guard !freeTools.contains(name) else { return [] }
        var lanes: [Lane] = globalTools.contains(name) ? [.global] : []
        let tabID = arguments["tabID"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? (name.hasPrefix("browser_") ? playwrightTab : nil)
        if let tabID {
            lanes.append(.tab(tabID))
        }
        return lanes.isEmpty ? [.global] : lanes
    }
}
