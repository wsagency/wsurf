// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CCef
import CefKit
import Foundation

/// Chromium's native navigation history as the page reads it: from CEF's navigation entries in process, from the list the service
/// pushes (`historyChanged`, `ChromiumRemoteBrowser.history`) out of process. WSurf's own list (`history`) is built from it and from
/// the entries WSurf restored itself (`historyRecord`, D3b), and the startup page is kept out of Back.
extension ChromiumPage {
    private static let startupResetAttempts = 10
    private static let startupResetRetryDelay: Duration = .milliseconds(100)

    /// Back must never reach the startup page. The reset keeps only the committed entry, so it may run only while the history
    /// is exactly the startup page and that entry: once the page added an entry (`pushState`) or a later page committed, it
    /// would drop real Back entries. Chromium refuses it while the first commit is still swapping renderers, which the DevTools
    /// session waits out; a refusal of another kind is retried here. A reset that does not land leaves the startup entry hidden from Back.
    ///
    /// Out of process the windowless browser starts on about:blank too, but the first load usually REPLACES that entry (measured in
    /// D4-4b: one entry after the load), and the same check then finds nothing to drop (`landed`, with no reset sent). A load that
    /// comes after about:blank has finished keeps both entries, and the service's one-turn `collapseHistory` drops the startup one.
    func dropStartupEntry() {
        startupEntry = .resetting
        guard raw != nil || remote != nil, !closing, !isClosed else { return }
        Task { [weak self] in
            guard let self else { return }
            var outcome = StartupReset.refused
            for attempt in 1...Self.startupResetAttempts {
                outcome = await resetNavigationHistory()
                guard outcome == .refused, attempt < Self.startupResetAttempts else { break }
                try? await Task.sleep(for: Self.startupResetRetryDelay)
                guard !closing, !isClosed else { return }
            }
            guard !closing, !isClosed else { return }
            startupEntry = outcome == .landed ? .dropped : .kept
            owner?.canGoBack = logicalCanGoBack()
            await loadHistory()
        }
    }

    private enum StartupReset {
        case landed, refused, skipped
    }

    private struct StartupResetBlocked: Error {
        let outcome: StartupReset
    }

    /// The history check runs in the same synchronous turn that sends the reset, and Chromium applies the reset while it is
    /// sent, so no entry can arrive in between. The test seam replaces only the command. Out of process the check and the reset
    /// are the service's, in one turn of its UI thread (`collapseHistory`), against the list this side last saw.
    private func resetNavigationHistory() async -> StartupReset {
        if let remote, startupResetCommand == nil {
            if let outcome = startupResetBlocker() {
                return outcome
            }
            guard let list = remote.history, list.count == 2 else { return .refused }
            switch await remote.collapseHistory(keeping: list[1].id, ifEntriesAre: list.map(\.id)) {
            case .landed:
                // The list now holds the kept entry alone: the service pushes it too, a moment later, and until then the mirror must not
                // show a Back to the startup page that is gone.
                remote.collapseMirror(keeping: list[1].id)
                return .landed
            case .skipped:
                return .skipped
            case .refused:
                return .refused
            }
        }
        do {
            if let startupResetCommand {
                if let outcome = startupResetBlocker() {
                    return outcome
                }
                try await startupResetCommand()
            } else {
                _ = try await devTools.command("Page.resetNavigationHistory", dispatchCheck: { [weak self] in
                    guard let self else { throw StartupResetBlocked(outcome: .refused) }
                    if let outcome = startupResetBlocker() {
                        throw StartupResetBlocked(outcome: outcome)
                    }
                })
            }
            return .landed
        } catch let blocked as StartupResetBlocked {
            return blocked.outcome
        } catch {
            return .refused
        }
    }

    /// Nil while Chromium's history is exactly the startup page and the committed entry, the one state in which the reset
    /// drops nothing else; otherwise the outcome to report instead. The commit event can arrive before Chromium records the
    /// entry, so a history of the startup page alone is retried like a refusal.
    private func startupResetBlocker() -> StartupReset? {
        guard let native = nativeHistory() else { return .refused }
        if native.first != "about:blank" {
            return .landed
        }
        if native.count > 2 {
            return .skipped
        }
        return native.count == 2 && native.current == 1 ? nil : .refused
    }

    /// The first native entry Back may reach: not the startup page while it is Chromium's first entry, and not an entry a hop left
    /// below its floor (`ChromiumHistoryRecord.floor`, found by id in the last list read).
    private func firstReachable(firstAddress: String?, in list: [CefRemote.HistoryEntry]) -> Int {
        let startup = startupEntry != .dropped && firstAddress == "about:blank" ? 1 : 0
        return max(startup, historyRecord.floorIndex(in: list))
    }

    /// Back is possible to an entry other than the startup page, from Chromium's history as it is now.
    func nativeCanGoBack() -> Bool {
        guard let native = nativeHistory() else { return false }
        return native.current > firstReachable(firstAddress: native.first, in: historyRecord.native)
    }

    /// Back is possible natively or to an entry WSurf restored.
    func logicalCanGoBack() -> Bool {
        nativeCanGoBack() || !historyRecord.back.isEmpty
    }

    /// Chromium's entry count, current index and first URL. In process the visitor runs before the call returns on the UI thread, so
    /// the answer is current in the same turn. Out of process it is the last list the service pushed (a read cannot cross the
    /// process), which the service sends after every commit, address change and end of loading.
    func nativeHistory() -> (count: Int, current: Int, first: String)? {
        if let remote {
            return remote.nativeHistory
        }
        guard let read = nativeEntries(), let first = read.entries.first else { return nil }
        return (read.entries.count, read.current, first.url)
    }

    /// In process only: every entry with its address, title and POST flag, read now (the visitor runs before the call returns).
    func nativeEntries() -> (entries: [NavigationEntryReader.Entry], current: Int)? {
        guard remote == nil else { return nil }
        let reader = NavigationEntryReader()
        let visitor = ChromiumInterop.allocate(cef_navigation_entry_visitor_t.self, owner: reader)
        visitor.pointee.visit = { visitorSelf, entry, current, index, total in
            // Callback object arguments arrive with a reference. An entry that cannot be read counts as made by a POST: never saved.
            let read = entry.map {
                NavigationEntryReader.Entry(
                    url: ChromiumInterop.takeString($0.pointee.get_url?($0)),
                    title: ChromiumInterop.takeString($0.pointee.get_title?($0)),
                    hasPostData: $0.pointee.has_post_data?($0) != 0)
            } ?? NavigationEntryReader.Entry(url: "", title: "", hasPostData: true)
            if let entry {
                ChromiumInterop.release(UnsafeMutableRawPointer(entry))
            }
            guard let visitorSelf,
                  let reader = ChromiumInterop.owner(NavigationEntryReader.self, of: UnsafeMutableRawPointer(visitorSelf)) else { return 0 }
            MainActor.assumeIsolated {
                reader.record(read, isCurrent: current != 0, index: Int(index), total: Int(total))
            }
            return 1
        }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(visitor)) }
        // The call consumes the reference it is given.
        ChromiumInterop.retain(UnsafeMutableRawPointer(visitor))
        let visited = withHost { host -> Bool in
            guard let entries = host.pointee.get_navigation_entries else { return false }
            entries(host, visitor, 0)
            return true
        } ?? false
        if !visited {
            ChromiumInterop.release(UnsafeMutableRawPointer(visitor))
        }
        guard let entries = reader.entries, !entries.isEmpty else { return nil }
        return (entries, reader.current)
    }

    func refreshHistory() {
        guard raw != nil || remote != nil, !closing, !isClosed else { return }
        if remote != nil {
            // The service pushes the list; what this side has of it is applied now.
            applyRemoteHistory()
            return
        }
        Task { [weak self] in
            await self?.loadHistory()
        }
    }

    /// Reads Chromium's history into `history`. False when the read fails. Only CDP has the entries' ids; only the visitor has their
    /// POST flags, read when the answer is handled. A visitor list that does not match (count, current entry, addresses) leaves every
    /// entry of this read counted as made by a POST, so none of them is saved.
    @discardableResult
    func loadHistory() async -> Bool {
        if remote != nil {
            return applyRemoteHistory()
        }
        guard raw != nil, !closing, !isClosed, let response = try? await command("Page.getNavigationHistory"),
              let index = response["currentIndex"] as? Int,
              let entries = response["entries"] as? [[String: Any]] else { return false }
        guard !closing, !isClosed else { return false }
        setHistory(ChromiumHistoryRecord.nativeList(entries, current: index, visited: nativeEntries()))
        return true
    }

    /// WSurf's list from the service's last `historyChanged`. False while the service has pushed none.
    @discardableResult
    func applyRemoteHistory() -> Bool {
        guard !closing, !isClosed, let list = remote?.history else { return false }
        setHistory(list)
        return true
    }

    private func setHistory(_ list: [CefRemote.HistoryEntry]) {
        if remote == nil {
            applyToRecord(list)
            // A hop's entry is in this list but not applied: the list it started from stays, which Back and Forward move in (`rehop`).
            if historyRecord.hopHasMoved(navigation: navigation) {
                return
            }
        }
        let index = list.firstIndex(where: \.isCurrent) ?? -1
        let items = list.enumerated().compactMap { position, entry -> (Int, PageHistoryItem)? in
            guard entry.id >= 0, let url = URL(string: entry.url) else { return nil }
            return (position, PageHistoryItem(url: url, title: entry.title, chromiumIndex: Int(entry.id)))
        }
        // Until a reset drops it, Chromium's first entry is the startup page, which Back never reaches.
        let reachable = firstReachable(firstAddress: list.first?.url, in: list)
        func restored(_ entries: [ChromiumHistoryRecord.Restored]) -> [PageHistoryItem] {
            entries.compactMap { item in URL(string: item.entry.url).map { PageHistoryItem(url: $0, title: item.entry.title, restoredID: item.id) } }
        }
        history = PageHistoryList(
            backList: restored(historyRecord.back) + items.filter { $0.0 < index && $0.0 >= reachable }.map(\.1),
            forwardList: items.filter { $0.0 > index }.map(\.1) + restored(historyRecord.forward),
            currentItem: items.first { $0.0 == index }?.1)
        owner?.onHistoryChanged?()
    }

    // MARK: Restored entries (D3b)

    private func applyToRecord(_ list: [CefRemote.HistoryEntry]) {
        switch historyRecord.update(native: list, navigation: navigation) {
        case .unchanged:
            return
        case .forwardDropped:
            break
        case let .collapse(keeping, count):
            collapseHistory(keeping: keeping, count: count)
        }
        owner?.canGoBack = logicalCanGoBack()
        owner?.canGoForward = list.last?.isCurrent == false || !historyRecord.forward.isEmpty
    }

    /// The list to save for this page: nil out of process (D4-33 connects it) and when there is nothing to go back or forward to.
    func savedHistory() -> ChromiumHistoryRecord.Saved? {
        guard !runsRemotely else { return nil }
        let list = historyRecord.native
        let reachable = firstReachable(firstAddress: list.first?.url, in: list)
        let current = list.firstIndex(where: \.isCurrent) ?? -1
        return historyRecord.saved(window: Array(list.dropFirst(reachable)), current: current - reachable)
    }

    /// A saved list, before the tab's address is loaded: its entries load only when visited. Out of process the tab keeps loading its
    /// address alone until D4-33.
    func seedHistory(_ saved: ChromiumHistoryRecord.Saved) {
        guard !runsRemotely else { return }
        historyRecord.seed(saved)
        setHistory(historyRecord.native)
        owner?.canGoBack = !historyRecord.back.isEmpty
        owner?.canGoForward = !historyRecord.forward.isEmpty
    }

    /// The person's (or the agent's) Back: natively while Chromium has an entry to go to, else a hop to the newest restored entry. While
    /// a hop's entry is in Chromium's list but not yet applied (`ChromiumHistoryRecord.hopHasMoved`), from where it started (`rehop`).
    func goBackInHistory() -> PageNavigation? {
        if historyRecord.hopHasMoved(navigation: navigation) {
            return rehop(-1)
        }
        if remote == nil, !nativeCanGoBack(), let target = historyRecord.back.last {
            return hop(to: target.id)
        }
        return goBack()
    }

    func goForwardInHistory() -> PageNavigation? {
        if historyRecord.hopHasMoved(navigation: navigation) {
            return rehop(1)
        }
        if remote == nil, let target = historyRecord.forward.first, let read = nativeEntries(), read.current == read.entries.count - 1 {
            return hop(to: target.id)
        }
        return goForward()
    }

    func goInHistory(to item: PageHistoryItem) -> PageNavigation? {
        guard let id = item.restoredID else { return go(to: item) }
        return remote == nil ? hop(to: id) : nil
    }

    /// WSurf's error document replaced the failed load `failed`: a hop that was that load keeps its place through the document.
    func keepHopThroughErrorDocument(failed: PageNavigation?) {
        historyRecord.failedHop(failed, errorDocument: navigation)
    }

    /// Whether the page's navigation is a hop backward in the list. A load the engine router moves to the other engine must then not
    /// keep this page for Back: Back from there would go forward in time.
    var hopsBackward: Bool {
        historyRecord.hopsBackward(navigation: navigation)
    }

    /// Loads a restored entry by a plain GET, through the same navigation decision as any load: nothing is imported and nothing
    /// is sent again. The list moves only once the hop's own entry appears (`ChromiumHistoryRecord.update`); a hop that never commits
    /// (cancelled, blocked, moved to the other engine) moves nothing.
    private func hop(to id: Int) -> PageNavigation? {
        guard let url = historyRecord.address(of: id), let read = nativeEntries() else { return nil }
        let reachable = firstReachable(firstAddress: read.entries.first?.url, in: historyRecord.native)
        let window = read.entries.dropFirst(reachable).map {
            CefRemote.HistoryEntry(id: -1, url: $0.url, title: $0.title, hasPostData: $0.hasPostData)
        }
        guard let next = load(URLRequest(url: url)) else { return nil }
        historyRecord.startHop(to: id, window: window, current: read.current - reachable, navigation: next)
        return next
    }

    /// Back (`step` -1) or Forward (1) while a hop has moved Chromium's list unapplied: the entry next to the one the hop started at, by GET, in the hop's own
    /// list (`ChromiumHistoryRecord.entryFromHop`), so two quick Backs move one step (S5).
    private func rehop(_ step: Int) -> PageNavigation? {
        guard let entry = historyRecord.entryFromHop(step), let next = load(URLRequest(url: entry.url)) else { return nil }
        historyRecord.retargetHop(to: entry.index, navigation: next)
        return next
    }

    private struct CollapseBlocked: Error {}

    /// After a hop: drops every native entry before its own, in the same turn as a check that nothing was added after it. Chromium
    /// refuses the reset while a cross-site hop is still swapping renderers, so a refusal is retried as the startup reset's is; a
    /// failed check is not. Until it lands, or when it cannot, those entries stay hidden below the floor.
    private func collapseHistory(keeping address: String, count: Int) {
        Task { [weak self] in
            guard let self else { return }
            await historyRecord.beforeCollapse?()
            attempts: for attempt in 1...Self.startupResetAttempts {
                guard raw != nil, !closing, !isClosed else { return }
                do {
                    _ = try await devTools.command("Page.resetNavigationHistory", dispatchCheck: { [weak self] in
                        guard let self, let read = nativeEntries(), read.entries.count == count, read.current == count - 1,
                              read.entries.last?.url == address else { throw CollapseBlocked() }
                    })
                    break attempts
                } catch is CollapseBlocked {
                    break attempts
                } catch {
                    guard attempt < Self.startupResetAttempts else { break attempts }
                    try? await Task.sleep(for: Self.startupResetRetryDelay)
                }
            }
            await loadHistory()
        }
    }
}
