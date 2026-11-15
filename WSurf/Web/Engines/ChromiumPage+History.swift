// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CCef
import CefKit
import Foundation

/// Chromium's native navigation history as the page reads it: from CEF's navigation entries in process, from the list the service
/// pushes (`historyChanged`, `ChromiumRemoteBrowser.history`) out of process. WSurf's own list (`history`) is built from it, and
/// the startup page is kept out of Back.
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
            owner?.canGoBack = nativeCanGoBack()
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

    /// Back is possible to an entry other than the startup page, from Chromium's history as it is now.
    func nativeCanGoBack() -> Bool {
        guard let native = nativeHistory() else { return false }
        let floor = startupEntry != .dropped && native.first == "about:blank" ? 1 : 0
        return native.current > floor
    }

    /// Chromium's entry count, current index and first URL. In process the visitor runs before the call returns on the UI thread, so
    /// the answer is current in the same turn. Out of process it is the last list the service pushed (a read cannot cross the
    /// process), which the service sends after every commit, address change and end of loading.
    func nativeHistory() -> (count: Int, current: Int, first: String)? {
        if let remote {
            return remote.nativeHistory
        }
        let reader = NavigationEntryReader()
        let visitor = ChromiumInterop.allocate(cef_navigation_entry_visitor_t.self, owner: reader)
        visitor.pointee.visit = { visitorSelf, entry, current, index, total in
            // Callback object arguments arrive with a reference.
            let url = entry.map { ChromiumInterop.takeString($0.pointee.get_url?($0)) } ?? ""
            if let entry {
                ChromiumInterop.release(UnsafeMutableRawPointer(entry))
            }
            guard let visitorSelf,
                  let reader = ChromiumInterop.owner(NavigationEntryReader.self, of: UnsafeMutableRawPointer(visitorSelf)) else { return 0 }
            MainActor.assumeIsolated {
                reader.record(url: url, isCurrent: current != 0, index: Int(index), total: Int(total))
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
        guard let total = reader.total, let first = reader.first else { return nil }
        return (total, reader.current, first)
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

    /// Reads Chromium's history into `history`. False when the read fails.
    @discardableResult
    func loadHistory() async -> Bool {
        if remote != nil {
            return applyRemoteHistory()
        }
        guard raw != nil, !closing, !isClosed, let response = try? await command("Page.getNavigationHistory"),
              let index = response["currentIndex"] as? Int,
              let entries = response["entries"] as? [[String: Any]] else { return false }
        let items = entries.enumerated().compactMap { position, entry -> (Int, PageHistoryItem)? in
            guard let id = entry["id"] as? Int, let address = entry["url"] as? String,
                  let url = URL(string: address) else { return nil }
            return (position, PageHistoryItem(url: url, title: entry["title"] as? String, chromiumIndex: id))
        }
        setHistory(items, current: index, firstAddress: entries.first?["url"] as? String)
        return true
    }

    /// WSurf's list from the service's last `historyChanged`. False while the service has pushed none.
    @discardableResult
    func applyRemoteHistory() -> Bool {
        guard !closing, !isClosed, let list = remote?.history else { return false }
        let items = list.enumerated().compactMap { position, entry -> (Int, PageHistoryItem)? in
            guard let url = URL(string: entry.url) else { return nil }
            return (position, PageHistoryItem(url: url, title: entry.title, chromiumIndex: Int(entry.id)))
        }
        setHistory(items, current: list.firstIndex(where: \.isCurrent) ?? -1, firstAddress: list.first?.url)
        return true
    }

    private func setHistory(_ items: [(Int, PageHistoryItem)], current index: Int, firstAddress: String?) {
        // Until a reset drops it, Chromium's first entry is the startup page, which Back never reaches.
        let hidden = startupEntry != .dropped && firstAddress == "about:blank" ? 0 : -1
        history = PageHistoryList(
            backList: items.filter { $0.0 < index && $0.0 != hidden }.map(\.1),
            forwardList: items.filter { $0.0 > index }.map(\.1),
            currentItem: items.first { $0.0 == index }?.1)
        owner?.onHistoryChanged?()
    }
}
