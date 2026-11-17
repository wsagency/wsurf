// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-11: the history and collapse sections of `RemoteBrowser`, moved out of `RemoteBrowser.swift` unchanged (only the access of the members it shares
// with that file was loosened from `private`), to keep both files under the lint length limit.

import CCef
import CefKit
import Foundation

extension RemoteBrowser {
    // MARK: History

    // The ids WSurf keeps history by are Chromium's navigation-entry ids, and only CDP carries them (`Page.getNavigationHistory`;
    // CEF's own entry objects have none). CEF's navigation-entry visitor adds what CDP lacks (`has_post_data`) and is the only
    // read that is synchronous on the UI thread. So `historyChanged` is built from both: a CDP read (its result arrives in a
    // later turn), then, in the turn it arrives, a visitor read that must agree with it (count, current index, every URL); a
    // list that does not agree is read again, a few times, then sent without `has_post_data`. `collapseHistory` needs the
    // check and the reset in ONE turn, so it checks the visitor's list against the last list sent (the one with ids) and
    // refuses when they disagree: a retry then finds the refreshed list.

    /// Asks Chromium for its navigation list. Calls while one is in flight are folded into one more read after it.
    func refreshHistory() {
        guard !hasClosed, !isClosing else { return }
        guard historyCommand == nil else {
            historyDirty = true
            return
        }
        withHost { [weak self] host in
            guard let self, historyCommand == nil else { return }
            #if WSURF_SERVICE_DEBUG_OPS
            if heldHistoryReads > 0 {
                heldHistoryReads -= 1
                if heldHistoryDelay <= 0 {
                    // Sent to nobody: the read has a command id and no answer will ever come, as for a renderer that went away.
                    historyCommand = nextServiceCommand
                    nextServiceCommand += 1
                    armHistoryTimer()
                    return
                }
                delayNextResult = heldHistoryDelay
            }
            #endif
            let sent = sendServiceCommand(
                "Page.getNavigationHistory", host: host, track: { self.historyCommand = $0 }, untrack: { _ in self.historyCommand = nil })
            if sent {
                armHistoryTimer()
            } else {
                // Chromium would not take the read: nothing will answer what waits for it.
                answerParkedCollapses(.refused)
            }
        }
    }

    #if WSURF_SERVICE_DEBUG_OPS
    func holdHistoryReads(_ count: Int, delay: TimeInterval) {
        heldHistoryReads = max(0, count)
        heldHistoryDelay = max(0, delay)
    }
    #endif

    /// A read that is not answered must not stop `historyChanged` for good (review F8): `historyCommand` is what folds every later
    /// refresh into "dirty", and only its result cleared it. So the wait has an end.
    private func armHistoryTimer() {
        historyTimer?.cancel()
        guard let command = historyCommand else { return }
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.historyReadTimedOut(command) }
        }
        historyTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historyReadTimeout, execute: timer)
    }

    private func historyReadTimedOut(_ command: Int64) {
        guard historyCommand == command else { return }
        note("browser \(id): the history read got no answer in \(Self.historyReadTimeout) s: given up")
        ServiceCounters.historyTimeouts.withLock { $0 += 1 }
        consecutiveHistoryTimeouts += 1
        abandonHistoryRead(readAgain: consecutiveHistoryTimeouts < 3)
    }

    /// Gives up on the read in flight (no answer will come: the renderer or the agent is gone, or the wait ran out). What waited on
    /// it is answered `refused`, and the next refresh reads again. With `readAgain` one is made now, because the list is unknown
    /// until one lands; a browser whose reads keep failing is left alone until its next event (the caller's cap).
    func abandonHistoryRead(readAgain: Bool = false) {
        historyTimer?.cancel()
        historyTimer = nil
        historyCommand = nil
        historyRetryPending = false
        historyDirty = false
        answerParkedCollapses(.refused)
        if readAgain {
            refreshHistory()
        }
    }

    /// The agent behind the observer is gone (a navigation swapped it, or the renderer died): a read in flight is lost.
    func devToolsAgentDetached() {
        abandonHistoryRead()
        send(event(CefRemote.Event.devToolsDetached))
    }

    /// The result of a read that `debug.holdHistory` delayed, unless the read was given up meanwhile.
    func lateHistoryResult(_ commandID: Int64, success: Bool, data: Data) {
        guard historyCommand == commandID else { return }
        historyCommand = nil
        historyResult(success: success, data: data)
    }

    func historyResult(success: Bool, data: Data) {
        historyTimer?.cancel()
        historyTimer = nil
        // The list is the one Chromium holds now, and nothing asked for a newer one meanwhile: parked collapses may run on it.
        var settled = false
        defer {
            if historyDirty {
                historyDirty = false
                refreshHistory()
            } else if settled {
                runParkedCollapses()
            } else if !historyRetryPending {
                answerParkedCollapses(.refused)
            }
        }
        guard !hasClosed, !isClosing else { return }
        guard success, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["currentIndex"] as? Int, let list = object["entries"] as? [[String: Any]] else {
            note("browser \(id): the history read failed (ok \(success), \(data.count) bytes)")
            return
        }
        var entries: [CefRemote.HistoryEntry] = []
        for (index, item) in list.enumerated() {
            guard let entryID = item["id"] as? Int, let url = item["url"] as? String else {
                note("browser \(id): the history read has an entry without an id or URL")
                return
            }
            entries.append(CefRemote.HistoryEntry(id: Int64(entryID), url: url, title: item["title"] as? String ?? "", isCurrent: index == current))
        }
        consecutiveHistoryTimeouts = 0
        let native = readNativeEntries()
        if let native, RemoteBrowser.agree(native, with: entries) {
            for index in entries.indices {
                entries[index].hasPostData = native[index].hasPostData
                if !native[index].title.isEmpty {
                    entries[index].title = native[index].title
                }
            }
            historyMismatches = 0
        } else if historyMismatches < 3 {
            // Chromium's two lists were read in different turns and the list moved between them: read again shortly.
            historyMismatches += 1
            historyRetryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    self?.historyRetryPending = false
                    self?.refreshHistory()
                }
            }
            return
        } else {
            historyMismatches = 0
        }
        settled = true
        guard entries != lastHistory else { return }
        lastHistory = entries
        send(CefRemoteMessage.historyChanged(browser: id, entries: entries))
    }

    // MARK: Collapse that waits for a fresh list

    /// Whether `lastHistory`, which a collapse is checked against, may be older than what Chromium holds: a read is in flight, or
    /// asked for, or due again in a moment, or there is no list yet.
    private var historyMayBeStale: Bool {
        historyCommand != nil || historyDirty || historyRetryPending || lastHistory == nil || !collapses.isEmpty
    }

    /// Runs the parked collapses on the list that was just confirmed, each in this one turn (check and reset together). One that
    /// finds the cache and Chromium disagreeing stays parked for the read it asks for.
    private func runParkedCollapses() {
        guard !parkedCollapses.isEmpty else { return }
        let waiting = parkedCollapses
        parkedCollapses.removeAll()
        withHost { [weak self] host in
            guard let self else { return }
            for parked in waiting {
                collapseHistory(request: parked.request, keeping: parked.keep, expected: parked.expected, host: host, wasParked: true)
            }
        }
    }

    func answerParkedCollapses(_ outcome: CefRemote.CollapseOutcome) {
        let waiting = parkedCollapses
        parkedCollapses.removeAll()
        for parked in waiting {
            send(CefRemoteMessage.historyCollapsed(browser: id, request: parked.request, outcome: outcome))
        }
    }

    /// Whether the visitor's list is the same list as `entries`: same length, same current entry, same URL at every position.
    private static func agree(_ native: [NativeEntry], with entries: [CefRemote.HistoryEntry]) -> Bool {
        native.count == entries.count
            && native.firstIndex(where: \.isCurrent) == entries.firstIndex(where: \.isCurrent)
            && zip(native, entries).allSatisfy { $0.url == $1.url }
    }

    /// "Collapse to `keeping` if the native list is exactly `expected`", checked and sent in one turn (the caller's, on the UI
    /// thread), so no entry can arrive between the check and the reset.
    func collapseHistory(
        request: Int64, keeping: Int64, expected: [Int64], host: UnsafeMutablePointer<cef_browser_host_t>, wasParked: Bool = false
    ) {
        func answer(_ outcome: CefRemote.CollapseOutcome) {
            send(CefRemoteMessage.historyCollapsed(browser: id, request: request, outcome: outcome))
        }
        // The cache the ids come from may be older than Chromium's list (a commit's read has not landed yet): wait for it instead of
        // refusing, because a refusal has no retry trigger when the re-read turns out identical (review F5). The wait ends with the
        // read (`historyResult`), its timeout, or the browser's close.
        if historyMayBeStale {
            parkedCollapses.append(ParkedCollapse(request: request, keep: keeping, expected: expected))
            if historyCommand == nil, !historyRetryPending {
                refreshHistory()
            }
            return
        }
        guard let known = lastHistory, let native = readNativeEntries(), RemoteBrowser.agree(native, with: known) else {
            // The list WSurf's ids come from is not the list Chromium holds now: nothing can be said about the ids. Asked for the
            // first time, it waits for the read this starts; one that already waited has had its read, and is refused (its caller
            // asks again), so a list that never agrees cannot keep it parked.
            if wasParked {
                answer(.refused)
            } else {
                parkedCollapses.append(ParkedCollapse(request: request, keep: keeping, expected: expected))
            }
            refreshHistory()
            return
        }
        if let verdict = CefRemote.collapseVerdict(native: known, keeping: keeping, expected: expected) {
            answer(verdict)
            return
        }
        let sent = sendServiceCommand("Page.resetNavigationHistory", host: host, track: { self.collapses[$0] = request }, untrack: { self.collapses[$0] = nil })
        if !sent {
            answer(.refused)
        }
    }

    /// Chromium's entries as CEF's visitor reports them, read now on the UI thread: the visitor runs before the call returns.
    private func readNativeEntries() -> [NativeEntry]? {
        guard let host = hostReference() else { return nil }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        guard let visit = host.pointee.get_navigation_entries else { return nil }
        let reader = NativeEntryReader()
        let visitor = Native.allocate(cef_navigation_entry_visitor_t.self, owner: reader)
        visitor.pointee.visit = { visitorSelf, entry, current, _, _ in
            guard let entry else { return 1 }
            let item = NativeEntry(
                url: Native.take(entry.pointee.get_url?(entry)), title: Native.take(entry.pointee.get_title?(entry)),
                hasPostData: entry.pointee.has_post_data?(entry) == 1, isCurrent: current != 0)
            // Callback object arguments arrive with a reference.
            Native.release(UnsafeMutableRawPointer(entry))
            guard let reader = Native.owner(NativeEntryReader.self, visitorSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            reader.entries.append(item)
            return 1
        }
        defer { Native.release(UnsafeMutableRawPointer(visitor)) }
        // The call takes a reference to the visitor.
        Native.retain(UnsafeMutableRawPointer(visitor))
        visit(host, visitor, 0)
        return reader.entries
    }
}

/// One entry as CEF's visitor reports it.
private struct NativeEntry {
    var url: String
    var title: String
    var hasPostData: Bool
    var isCurrent: Bool
}

/// What the navigation-entry visitor collects. A class of its own: the visitor's C callback must not be isolated.
private final class NativeEntryReader: @unchecked Sendable {
    var entries: [NativeEntry] = []
}
