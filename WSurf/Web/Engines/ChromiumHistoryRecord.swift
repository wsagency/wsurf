// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CefKit
import Foundation

/// WSurf's own record of a Chromium tab's Back and Forward list (D3b). Chromium can read its history but never take one back, so a
/// tab that sleeps, is restored after a relaunch, duplicated or reopened keeps its entries here and loads only its current address.
/// The other entries ("restored") load only when the person goes Back or Forward to them, by a plain GET (a hop). Nothing is imported
/// into Chromium, no form is sent again, and an entry made by a POST is never saved.
///
/// One store, one input: the native list as `[CefRemote.HistoryEntry]` (Chromium's entry ids, addresses, titles, POST flags). In
/// process `ChromiumPage` feeds it from `Page.getNavigationHistory` (ids) and CEF's entry visitor (POST flags, read in the turn they are
/// used); out of process the service already sends this shape (`history.changed`), which D4-33 connects.
struct ChromiumHistoryRecord {
    /// What is saved of an entry: its address and title, nothing else.
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var url: String
        var title: String
    }

    /// What a tab saves: `back` oldest first, `forward` nearest first. The current entry is the tab's own address.
    nonisolated struct Saved: Codable, Equatable, Sendable {
        var back: [Entry]
        var forward: [Entry]
    }

    struct Restored: Equatable {
        let id: Int
        let entry: Entry
    }

    /// A hop on its way: the whole list as it was when it started (nil where an entry is not kept), re-formed around `target` once the
    /// hop's own entry appears.
    private struct Hop {
        var navigation: PageNavigation
        let logical: [Entry?]
        /// The entry that was current when it started.
        let start: Int
        var target: Int
        let knownIDs: Set<Int64>
        /// The address the main frame committed for it (after any redirect). A hop that stays inside the document commits none, and
        /// is found by its own address. Empty after a retarget until the new load commits (`retargetHop`).
        var committedURL: String?
        /// Its load failed and WSurf's error document took its place (`failedHop`): that document's entry lands it.
        var failed = false

        var address: String {
            committedURL ?? logical[target]?.url ?? ""
        }

        var isBackward: Bool {
            target < start
        }
    }

    /// Chromium keeps 50 entries; the current one is the tab's address.
    static let maximumEntries = 49
    static let maximumTitleLength = 256
    /// Longer addresses are not saved: a page could otherwise grow the saved state by megabytes per entry (`pushState`).
    static let maximumURLLength = 8192

    private(set) var back: [Restored] = []
    private(set) var forward: [Restored] = []
    private var nextID = 1
    /// The native list as last read, with Chromium's ids.
    private(set) var native: [CefRemote.HistoryEntry] = []
    /// Native entries before this one are hidden: what a hop left behind until its collapse lands.
    private(set) var floor: Int64?
    private var hop: Hop?
    /// WSurf's error document that a failed hop landed on (its native address), and the entry it stands for in the list.
    private var errorDocument: (url: String, entry: Entry)?
    /// Test seam: awaited before a hop's collapse is sent, so a case can change the page in between.
    var beforeCollapse: (@MainActor () async -> Void)?

    /// Saved only: an http or https address that no POST made, at most `maximumURLLength` long and with no user name or password in
    /// it (dropped, not stripped: without them the entry would load something else).
    static func keeps(_ entry: CefRemote.HistoryEntry) -> Bool {
        guard !entry.hasPostData, entry.url.utf8.count <= maximumURLLength, let url = URL(string: entry.url), url.user == nil,
              url.password == nil, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The native list from a DevTools read (ids, addresses, titles) and the entry visitor's read handled in the same turn (POST flags).
    /// Only the visitor knows whether a POST made an entry: when the two reads do not describe the same list (count, current entry,
    /// addresses), no entry can be shown to be a GET, so every one counts as a POST and is never saved.
    static func nativeList(_ entries: [[String: Any]], current index: Int,
                           visited: (entries: [NavigationEntryReader.Entry], current: Int)?) -> [CefRemote.HistoryEntry] {
        let addresses: [String] = entries.map { $0["url"] as? String ?? "" }
        let posts: [Bool]? = visited.flatMap { $0.current == index && $0.entries.map(\.url) == addresses ? $0.entries.map(\.hasPostData) : nil }
        return entries.enumerated().map { position, entry in
            CefRemote.HistoryEntry(
                id: Int64(entry["id"] as? Int ?? -1), url: addresses[position], title: entry["title"] as? String ?? "",
                hasPostData: posts?[position] ?? true, isCurrent: position == index)
        }
    }

    private static func entry(_ native: CefRemote.HistoryEntry) -> Entry {
        Entry(url: native.url, title: native.title)
    }

    /// The entry a native one stands for in the list: the failed entry for the error document of a failed hop, else itself when it is
    /// kept, else none.
    private func standIn(for native: CefRemote.HistoryEntry) -> Entry? {
        if let errorDocument, native.url == errorDocument.url {
            return errorDocument.entry
        }
        return Self.keeps(native) ? Self.entry(native) : nil
    }

    /// `back` and `forward` with only http and https addresses, titles cut, and at most `maximumEntries` in all (the oldest back
    /// entries go first); nil when nothing is left.
    static func saved(back: [Entry], forward: [Entry]) -> Saved? {
        func clean(_ list: [Entry]) -> [Entry] {
            list.filter { Self.keeps(CefRemote.HistoryEntry(id: 0, url: $0.url, title: "")) }
                .map { Entry(url: $0.url, title: String($0.title.prefix(Self.maximumTitleLength))) }
        }
        var back = clean(back)
        var forward = clean(forward)
        while back.count + forward.count > Self.maximumEntries {
            if back.isEmpty {
                forward.removeLast()
            } else {
                back.removeFirst()
            }
        }
        return back.isEmpty && forward.isEmpty ? nil : Saved(back: back, forward: forward)
    }

    /// Where the hidden native entries end in `list`, by id: 0 when nothing is hidden.
    func floorIndex(in list: [CefRemote.HistoryEntry]) -> Int {
        floor.flatMap { id in list.firstIndex { $0.id == id } } ?? 0
    }

    /// Starts again from a saved list, before the tab's address is loaded.
    mutating func seed(_ saved: Saved) {
        let clean = Self.saved(back: saved.back, forward: saved.forward)
        native = []
        floor = nil
        hop = nil
        errorDocument = nil
        back = restored(clean?.back ?? [])
        forward = restored(clean?.forward ?? [])
    }

    private mutating func restored(_ entries: [Entry]) -> [Restored] {
        let base = nextID
        nextID += entries.count
        return entries.enumerated().map { Restored(id: base + $0.offset, entry: $0.element) }
    }

    /// The list to save, around the native entries Back can reach (`window`, with `current` in it). A hop that has committed but not
    /// yet been applied saves the list it re-forms.
    func saved(window: [CefRemote.HistoryEntry], current: Int) -> Saved? {
        if let hop, hop.committedURL != nil || hop.failed {
            return Self.saved(back: hop.logical[..<hop.target].compactMap(\.self), forward: hop.logical[(hop.target + 1)...].compactMap(\.self))
        }
        let nativeBack = window.prefix(max(current, 0)).compactMap { standIn(for: $0) }
        let nativeForward = window.dropFirst(max(current + 1, 0)).compactMap { standIn(for: $0) }
        return Self.saved(back: back.map(\.entry) + nativeBack, forward: nativeForward + forward.map(\.entry))
    }

    /// The address of the restored entry `id`.
    func address(of id: Int) -> URL? {
        (back + forward).first { $0.id == id }.flatMap { URL(string: $0.entry.url) }
    }

    /// A hop to the restored entry `id` started with `navigation`. `window` is the native list Back can reach, read now, with `current`.
    mutating func startHop(to id: Int, window: [CefRemote.HistoryEntry], current: Int, navigation: PageNavigation) {
        let older: [Entry?] = back.map { $0.entry }
        let reachable: [Entry?] = window.map { standIn(for: $0) }
        let newer: [Entry?] = forward.map { $0.entry }
        let logical = older + reachable + newer
        let target: Int
        if let index = back.firstIndex(where: { $0.id == id }) {
            target = index
        } else if let index = forward.firstIndex(where: { $0.id == id }) {
            target = back.count + window.count + index
        } else {
            return
        }
        hop = Hop(navigation: navigation, logical: logical, start: back.count + max(current, 0), target: target, knownIDs: Set(native.map(\.id)))
    }

    /// Whether the hop on its way with the page's `navigation` failed: Chromium's error entry for it is in its list until WSurf's error
    /// document lands the hop, and a retarget waits for its own commit. Back, Forward and picks then move from the entry it started at, in
    /// the list it started from (`entryFromHop`), never natively: a native move from the error entry would leave the failed entry in the
    /// list twice. A hop that committed its page lands on the next read.
    func hopHasMoved(navigation: PageNavigation?) -> Bool {
        guard let hop, hop.navigation === navigation else { return false }
        return hop.failed || hop.committedURL == "" || hop.committedURL?.hasPrefix("chrome-error:") == true
    }

    /// The nearest kept entry `step` away (-1 Back, 1 Forward) from where the hop on its way started, with its place in the hop's list:
    /// a second Back during a Back hop is its own target again (S5). With nothing that way, the entry it started at (else its target),
    /// so the hop still lands and its entry in Chromium's list is never left behind.
    func entryFromHop(_ step: Int) -> (index: Int, url: URL)? {
        guard let hop else { return nil }
        var index = hop.start + step
        while hop.logical.indices.contains(index), hop.logical[index] == nil {
            index += step
        }
        for candidate in [index, hop.start, hop.target] where hop.logical.indices.contains(candidate) {
            if let url = hop.logical[candidate].flatMap({ URL(string: $0.url) }) {
                return (candidate, url)
            }
        }
        return nil
    }

    /// The place of the restored entry `id` in the list of the hop on its way (a pick from the list while the hop has moved).
    func indexInHop(of id: Int) -> Int? {
        guard let hop else { return nil }
        if let index = back.firstIndex(where: { $0.id == id }) {
            return index
        }
        return forward.firstIndex { $0.id == id }.map { hop.logical.count - forward.count + $0 }
    }

    /// The hop on its way now goes to `index` of its list, loaded with `navigation`. Once the replaced load has committed (its page or
    /// its error entry), only an entry the new load commits lands the hop.
    mutating func retargetHop(to index: Int, navigation: PageNavigation) {
        hop?.navigation = navigation
        hop?.target = index
        hop?.failed = false
        if hop?.committedURL != nil {
            hop?.committedURL = ""
        }
    }

    /// The main frame committed `url` (a new document, or a move inside one) while `navigation` was the page's.
    mutating func noteCommit(_ url: URL?, navigation: PageNavigation?) {
        guard hop?.navigation === navigation, let url else { return }
        hop?.committedURL = url.absoluteString
    }

    /// The hop's load (`failed`) failed and WSurf's error document (`errorDocument`, the page's navigation now) replaced it. The hop
    /// is kept through that document: the failed entry stays in its place in the list, shown by the error document, and loads again
    /// by GET when the person comes back to it. Without this, the error document would count as a new navigation after the entry the
    /// hop left, so Back would go forward in time and Forward would lose the forward entries.
    mutating func failedHop(_ failed: PageNavigation?, errorDocument: PageNavigation?) {
        guard let errorDocument, hop?.navigation === failed, errorDocument !== failed else { return }
        hop?.navigation = errorDocument
        hop?.failed = true
    }

    /// Whether `navigation` is a hop backward in the list (an engine switch must then not keep the page it leaves for Back).
    func hopsBackward(navigation: PageNavigation?) -> Bool {
        hop?.navigation === navigation && hop?.isBackward == true
    }

    enum Change: Equatable {
        case unchanged
        /// The restored forward entries were dropped.
        case forwardDropped
        /// A hop was applied: native history may now be collapsed to its entry, which must be the last of `count` entries.
        case collapse(keeping: String, count: Int)
    }

    /// The native list changed. A hop whose entry is in it is applied. Otherwise a new navigation (a new entry right after the entry
    /// that was current, which is still there) drops the restored forward entries, as Chromium drops its own; a replacement, a
    /// traversal or a reload does not, and neither does WSurf's own error document (`data:`).
    mutating func update(native new: [CefRemote.HistoryEntry], navigation: PageNavigation?) -> Change {
        defer { native = new }
        if hop != nil, hop?.navigation !== navigation {
            hop = nil
        }
        // A failed hop lands on the error document's own entry, once it is current: never on an error entry Chromium committed for the
        // failed address, nor on an earlier error document a retarget left (the same `data:` address).
        if let hop, let landed = new.lastIndex(where: { !hop.knownIDs.contains($0.id) && (hop.failed ? $0.isCurrent && $0.url.hasPrefix("data:") : $0.url == hop.address) }) {
            back = restored(hop.logical[..<hop.target].compactMap(\.self))
            forward = restored(hop.logical[(hop.target + 1)...].compactMap(\.self))
            floor = new[landed].id
            if hop.failed, let failed = hop.logical[hop.target] {
                errorDocument = (new[landed].url, failed)
            }
            self.hop = nil
            return .collapse(keeping: new[landed].url, count: new.count)
        }
        if hop?.committedURL != nil || hop?.failed == true {
            // Committed (or failed), but its entry is not in this read yet.
            return .unchanged
        }
        guard !forward.isEmpty, let previous = native.first(where: \.isCurrent), previous.url != "about:blank",
              let index = new.firstIndex(where: { $0.id == previous.id }), index + 1 < new.count else { return .unchanged }
        let next = new[index + 1]
        guard !native.contains(where: { $0.id == next.id }), !next.url.hasPrefix("data:") else { return .unchanged }
        forward = []
        return .forwardDropped
    }
}
