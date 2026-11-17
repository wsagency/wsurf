// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CefKit
import Foundation
import Testing

@testable import WSurf

/// The record a Chromium tab keeps of its Back and Forward list (D3b), and the saved format: only http and https entries that no POST
/// made, addresses and titles only; a hop moves the list only once its own entry appears; a new navigation drops the restored forward
/// entries and a replacement or traversal does not. Old saved states (WebKit's, tagged or not) keep their meaning.
@MainActor
@Suite
struct ChromiumHistoryRecordTests {
    private typealias Entry = ChromiumHistoryRecord.Entry

    private func native(_ id: Int64, _ path: String, current: Bool = false, post: Bool = false) -> CefRemote.HistoryEntry {
        CefRemote.HistoryEntry(id: id, url: "https://a.test/\(path)", title: path.uppercased(), hasPostData: post, isCurrent: current)
    }

    private func entry(_ path: String) -> Entry {
        Entry(url: "https://a.test/\(path)", title: path.uppercased())
    }

    private func seeded(back: [String], forward: [String]) -> ChromiumHistoryRecord {
        var record = ChromiumHistoryRecord()
        record.seed(.init(back: back.map(entry), forward: forward.map(entry)))
        return record
    }

    private func paths(_ list: [ChromiumHistoryRecord.Restored]) -> [String] {
        list.map { URL(string: $0.entry.url)?.lastPathComponent ?? "?" }
    }

    // MARK: Saved format

    @Test func onlyWebAddressesThatNoFormMadeAreSaved() throws {
        var record = ChromiumHistoryRecord()
        let other = [
            "about:blank", "data:text/html,x", "chrome://settings", "chrome-error://chromewebdata/", "devtools://devtools/x",
            "javascript:void(0)", "blob:https://a.test/1", "file:///Users/x/a.html", "wsurf://start",
        ]
        var window = other.enumerated().map { CefRemote.HistoryEntry(id: Int64(100 + $0.offset), url: $0.element, title: "x") }
        window.insert(native(1, "a"), at: 2)
        window.append(native(2, "result", post: true))
        window.append(native(3, "b", current: true))
        window.append(native(4, "c", post: true))
        window.append(native(5, "d"))
        _ = record.update(native: window, navigation: nil)
        let saved = try #require(record.saved(window: window, current: window.count - 3))
        #expect(saved.back == [entry("a")], "a POST entry and every non-web address are dropped")
        #expect(saved.forward == [entry("d")])
    }

    /// A page could otherwise grow the saved state by megabytes per entry; a user name or password would be written in clear, and
    /// without it the entry would load something else, so the entry is dropped rather than changed.
    @Test func longAddressesAndAddressesWithAUserNameOrPasswordAreNotSaved() throws {
        let limit = ChromiumHistoryRecord.maximumURLLength
        let prefix = "https://a.test/?q="
        let fits = Entry(url: prefix + String(repeating: "x", count: limit - prefix.count), title: "fits")
        let long = Entry(url: prefix + String(repeating: "x", count: limit - prefix.count + 1), title: "long")
        let credentials = [Entry(url: "https://user:secret@a.test/x", title: "x"), Entry(url: "https://user@a.test/y", title: "y")]
        let saved = try #require(ChromiumHistoryRecord.saved(back: [long, entry("a")] + credentials, forward: [fits]))
        #expect(saved.back == [entry("a")])
        #expect(saved.forward == [fits], "an address of exactly the limit is kept")
    }

    /// Only CEF's entry visitor knows whether a POST made an entry. A read it does not match cannot show any entry to be a GET.
    @Test func aReadWhoseEntriesCannotBeConfirmedAsGetsCountsEveryEntryAsAPost() {
        let read: [[String: Any]] = [["id": 1, "url": "https://a.test/a", "title": "A"], ["id": 2, "url": "https://a.test/b", "title": "B"]]
        let a = NavigationEntryReader.Entry(url: "https://a.test/a", title: "A", hasPostData: false)
        let b = NavigationEntryReader.Entry(url: "https://a.test/b", title: "B", hasPostData: false)
        let matching = ChromiumHistoryRecord.nativeList(read, current: 1, visited: ([a, b], 1))
        #expect(matching == [CefRemote.HistoryEntry(id: 1, url: a.url, title: "A"), CefRemote.HistoryEntry(id: 2, url: b.url, title: "B", isCurrent: true)])
        let other = NavigationEntryReader.Entry(url: "https://a.test/x", title: "B", hasPostData: false)
        let mismatches: [(entries: [NavigationEntryReader.Entry], current: Int)?] = [nil, ([a, b], 0), ([a], 1), ([a, b, other], 1), ([a, other], 1)]
        for visited in mismatches {
            let list = ChromiumHistoryRecord.nativeList(read, current: 1, visited: visited)
            #expect(list.map(\.id) == [1, 2] && list.allSatisfy(\.hasPostData), "\(String(describing: visited))")
        }
    }

    @Test func aRecordKeepsAtMostFortyNineOtherEntriesDroppingTheOldestBackFirst() throws {
        let back = (0..<60).map { entry("b\($0)") }
        let saved = try #require(ChromiumHistoryRecord.saved(back: back, forward: [entry("f0"), entry("f1")]))
        #expect(saved.back.count + saved.forward.count == 49)
        #expect(saved.forward == [entry("f0"), entry("f1")])
        #expect(saved.back.first == entry("b13") && saved.back.last == entry("b59"))
        let onlyForward = try #require(ChromiumHistoryRecord.saved(back: [], forward: (0..<60).map { entry("f\($0)") }))
        #expect(onlyForward.forward.count == 49 && onlyForward.forward.last == entry("f48"), "the farthest forward entries go")
    }

    @Test func titlesAreCutAndNothingToSaveIsNil() throws {
        let long = String(repeating: "t", count: 1000)
        let saved = try #require(ChromiumHistoryRecord.saved(back: [Entry(url: "https://a.test/", title: long)], forward: []))
        #expect(saved.back.first?.title.count == 256)
        #expect(ChromiumHistoryRecord.saved(back: [Entry(url: "about:blank", title: "")], forward: []) == nil)
        #expect(ChromiumHistoryRecord().saved(window: [native(1, "a", current: true)], current: 0) == nil, "one page alone saves no state")
    }

    @Test func aSeedTakesOnlyWebAddresses() {
        var record = ChromiumHistoryRecord()
        record.seed(.init(back: [Entry(url: "javascript:alert(1)", title: ""), entry("a")], forward: [Entry(url: "file:///etc/hosts", title: "")]))
        #expect(paths(record.back) == ["a"])
        #expect(record.forward.isEmpty)
    }

    /// The saved state is the JSON the tab already stores: an old WebKit state (tagged or untagged) still restores natively, a
    /// Chromium state never does (it is seeded, then the address loads), and a build that predates it reads `webKit` as nil.
    @Test func savedStatesOldAndNewDecodeAsBefore() throws {
        let tagged = Data(#"{"engine":"webkit","webKit":"AAEC"}"#.utf8)
        let untagged = Data([0, 1, 2, 3])
        let chromium = Data(#"{"engine":"chromium","chromium":{"back":[{"url":"https://a.test/a","title":"A"}],"forward":[{"url":"https://a.test/c","title":"C"}]}}"#.utf8)

        #expect(BrowserPage.canRestore(tagged, using: .webKit))
        #expect(BrowserPage.canRestore(untagged, using: .webKit))
        #expect(!BrowserPage.canRestore(tagged, using: .chromium))
        #expect(!BrowserPage.canRestore(chromium, using: .webKit))
        #expect(!BrowserPage.canRestore(chromium, using: .chromium), "a Chromium state is never set as native state")

        #expect(BrowserPage.chromiumHistory(in: chromium) == .init(back: [entry("a")], forward: [entry("c")]))
        #expect(BrowserPage.chromiumHistory(in: tagged) == nil)
        #expect(BrowserPage.chromiumHistory(in: untagged) == nil)

        struct BeforeD3b: Decodable {
            let engine: BrowserEngine
            let webKit: Data?
        }
        let older = try JSONDecoder().decode(BeforeD3b.self, from: chromium)
        #expect(older.engine == .chromium && older.webKit == nil, "an older build falls back to the address")
        #expect(try JSONDecoder().decode(BeforeD3b.self, from: tagged).webKit == Data([0, 1, 2]))
    }

    // MARK: Updates

    @Test func aNewNavigationDropsTheRestoredForwardEntries() {
        var record = seeded(back: ["a"], forward: ["c"])
        #expect(record.update(native: [native(1, "b", current: true)], navigation: nil) == .unchanged)
        #expect(record.update(native: [native(1, "b"), native(2, "d", current: true)], navigation: nil) == .forwardDropped)
        #expect(record.forward.isEmpty)
        #expect(paths(record.back) == ["a"])
    }

    @Test func aReplacementATraversalOrAnErrorDocumentKeepsThem() {
        var record = seeded(back: ["a"], forward: ["c"])
        _ = record.update(native: [native(1, "b", current: true)], navigation: nil)
        #expect(record.update(native: [native(2, "b2", current: true)], navigation: nil) == .unchanged, "location.replace")
        #expect(record.update(native: [CefRemote.HistoryEntry(id: 2, url: "https://a.test/b3", title: "", isCurrent: true)], navigation: nil) == .unchanged,
                "replaceState keeps the id")
        _ = record.update(native: [native(2, "b3"), native(3, "x", current: true)], navigation: nil)
        #expect(record.forward.isEmpty, "a push after that is a new navigation")

        var traversal = seeded(back: [], forward: ["z"])
        _ = traversal.update(native: [native(1, "a"), native(2, "b", current: true)], navigation: nil)
        #expect(traversal.update(native: [native(1, "a", current: true), native(2, "b")], navigation: nil) == .unchanged)
        #expect(traversal.update(native: [native(1, "a"), native(2, "b", current: true)], navigation: nil) == .unchanged)
        let errorDocument = CefRemote.HistoryEntry(id: 3, url: "data:text/html;base64,eA==", title: "", isCurrent: true)
        #expect(traversal.update(native: [native(1, "a"), native(2, "b"), errorDocument], navigation: nil) == .unchanged,
                "WSurf's own error document")
        #expect(paths(traversal.forward) == ["z"])
    }

    @Test func theStartupPageIsNotAPreviousEntry() {
        var record = seeded(back: ["a"], forward: ["c"])
        _ = record.update(native: [CefRemote.HistoryEntry(id: 1, url: "about:blank", title: "", isCurrent: true)], navigation: nil)
        _ = record.update(native: [CefRemote.HistoryEntry(id: 1, url: "about:blank", title: ""), native(2, "b", current: true)], navigation: nil)
        #expect(paths(record.forward) == ["c"])
    }

    // MARK: Hops

    @Test func aBackHopReformsTheListAroundItsTargetOnceItsEntryAppears() throws {
        var record = seeded(back: ["a", "b"], forward: ["d"])
        _ = record.update(native: [native(1, "c", current: true)], navigation: nil)
        let hop = PageNavigation()
        let target = try #require(record.back.last)
        record.startHop(to: target.id, window: [native(-1, "c", current: true)], current: 0, navigation: hop)
        #expect(record.hopsBackward(navigation: hop))
        #expect(record.update(native: [native(1, "c", current: true)], navigation: hop) == .unchanged, "nothing moves before the hop's entry")
        #expect(paths(record.back) == ["a", "b"])

        record.noteCommit(URL(string: "https://a.test/b"), navigation: hop)
        #expect(record.update(native: [native(1, "c"), native(2, "b", current: true)], navigation: hop)
                == .collapse(keeping: "https://a.test/b", count: 2))
        #expect(paths(record.back) == ["a"])
        #expect(paths(record.forward) == ["c", "d"])
        #expect(record.floorIndex(in: record.native) == 1, "the page left behind is hidden until the collapse lands")
        #expect(!record.hopsBackward(navigation: hop))
    }

    @Test func aForwardHopAndAMenuPickReformTheListToo() throws {
        var record = seeded(back: ["a"], forward: ["c", "d"])
        _ = record.update(native: [native(1, "b", current: true)], navigation: nil)
        let forward = PageNavigation()
        record.startHop(to: try #require(record.forward.first).id, window: [native(-1, "b", current: true)], current: 0, navigation: forward)
        #expect(!record.hopsBackward(navigation: forward))
        record.noteCommit(URL(string: "https://a.test/c"), navigation: forward)
        _ = record.update(native: [native(1, "b"), native(2, "c", current: true)], navigation: forward)
        #expect(paths(record.back) == ["a", "b"])
        #expect(paths(record.forward) == ["d"])

        let pick = PageNavigation()
        record.startHop(to: try #require(record.back.first).id, window: [native(-1, "c", current: true)], current: 0, navigation: pick)
        record.noteCommit(URL(string: "https://a.test/a"), navigation: pick)
        _ = record.update(native: [native(2, "c"), native(3, "a", current: true)], navigation: pick)
        #expect(paths(record.back).isEmpty)
        #expect(paths(record.forward) == ["b", "c", "d"])
    }

    @Test func aPostEntryInTheWindowIsDroppedWhenAHopMovesIt() throws {
        var record = seeded(back: ["a"], forward: [])
        let window = [native(-1, "form"), native(-1, "result", post: true), native(-1, "d", current: true)]
        _ = record.update(native: window.enumerated().map { CefRemote.HistoryEntry(id: Int64($0.offset + 1), url: $0.element.url,
                                                                                    title: "", hasPostData: $0.element.hasPostData,
                                                                                    isCurrent: $0.element.isCurrent) },
                          navigation: nil)
        let hop = PageNavigation()
        record.startHop(to: try #require(record.back.first).id, window: window, current: 2, navigation: hop)
        record.noteCommit(URL(string: "https://a.test/a"), navigation: hop)
        _ = record.update(native: [native(1, "form"), native(2, "result", post: true), native(3, "d"), native(9, "a", current: true)], navigation: hop)
        #expect(paths(record.forward) == ["form", "d"], "the POST entry is never kept")
    }

    @Test func aHopThatNeverCommitsMovesNothing() throws {
        var record = seeded(back: ["a"], forward: ["c"])
        _ = record.update(native: [native(1, "b", current: true)], navigation: nil)
        let hop = PageNavigation()
        record.startHop(to: try #require(record.back.first).id, window: [native(-1, "b", current: true)], current: 0, navigation: hop)
        // Cancelled (engine switch, external app, blocked): the page's next navigation is someone else's.
        let other = PageNavigation()
        _ = record.update(native: [native(1, "b"), native(2, "x", current: true)], navigation: other)
        #expect(paths(record.back) == ["a"])
        #expect(record.forward.isEmpty, "that navigation is a new one")
        record.noteCommit(URL(string: "https://a.test/a"), navigation: hop)
        #expect(record.update(native: [native(2, "x"), native(3, "a", current: true)], navigation: other) == .unchanged)
        #expect(paths(record.back) == ["a"])
    }

    /// The hop's load fails and WSurf's error document replaces it, with a navigation of its own. The hop lands on that document's
    /// entry, never on an error entry Chromium committed for the failed address: the failed entry keeps its place.
    @Test func aFailedBackHopKeepsItsPlaceThroughTheErrorDocument() throws {
        var record = seeded(back: ["a", "b"], forward: [])
        _ = record.update(native: [native(1, "c", current: true)], navigation: nil)
        let hop = PageNavigation()
        record.startHop(to: try #require(record.back.last).id, window: [native(-1, "c", current: true)], current: 0, navigation: hop)
        let errorDocument = PageNavigation()
        record.failedHop(hop, errorDocument: errorDocument)
        #expect(record.saved(window: [native(1, "c", current: true)], current: 0) == .init(back: [entry("a")], forward: [entry("c")]),
                "saved while the error document loads: the list around the failed entry")
        #expect(record.update(native: [native(1, "c"), native(2, "b", current: true)], navigation: errorDocument) == .unchanged,
                "Chromium's error entry is not the hop's")
        #expect(paths(record.back) == ["a", "b"] && record.forward.isEmpty)

        let document = CefRemote.HistoryEntry(id: 3, url: "data:text/html;base64,eA==", title: "", isCurrent: true)
        #expect(record.update(native: [native(1, "c"), native(2, "b"), document], navigation: errorDocument)
                == .collapse(keeping: document.url, count: 3))
        #expect(paths(record.back) == ["a"])
        #expect(paths(record.forward) == ["c"], "Back never reaches the page the hop left")
        #expect(record.floorIndex(in: record.native) == 2)

        // The error document stands for b: the next hop away keeps b in its place, retried by GET when visited.
        let away = PageNavigation()
        let shown = CefRemote.HistoryEntry(id: -1, url: document.url, title: "", isCurrent: true)
        #expect(record.saved(window: [shown, native(-1, "x")], current: 0) == .init(back: [entry("a")], forward: [entry("x"), entry("c")]))
        record.startHop(to: try #require(record.back.last).id, window: [shown], current: 0, navigation: away)
        record.noteCommit(URL(string: "https://a.test/a"), navigation: away)
        _ = record.update(native: [CefRemote.HistoryEntry(id: 3, url: document.url, title: ""), native(4, "a", current: true)], navigation: away)
        #expect(record.back.isEmpty)
        #expect(paths(record.forward) == ["b", "c"])
    }

    @Test func aFailedForwardHopKeepsTheForwardEntries() throws {
        var record = seeded(back: [], forward: ["b", "c"])
        _ = record.update(native: [native(1, "a", current: true)], navigation: nil)
        let hop = PageNavigation()
        record.startHop(to: try #require(record.forward.first).id, window: [native(-1, "a", current: true)], current: 0, navigation: hop)
        record.failedHop(PageNavigation(), errorDocument: PageNavigation())
        let errorDocument = PageNavigation()
        record.failedHop(hop, errorDocument: errorDocument)
        let document = CefRemote.HistoryEntry(id: 2, url: "data:text/html;base64,eA==", title: "", isCurrent: true)
        #expect(record.update(native: [native(1, "a"), document], navigation: errorDocument) == .collapse(keeping: document.url, count: 2))
        #expect(paths(record.back) == ["a"])
        #expect(paths(record.forward) == ["c"])
    }

    @Test func aHopInsideTheDocumentIsFoundByItsAddress() throws {
        var record = seeded(back: ["b#top"], forward: [])
        _ = record.update(native: [native(1, "b", current: true)], navigation: nil)
        let hop = PageNavigation()
        record.startHop(to: try #require(record.back.first).id, window: [native(-1, "b", current: true)], current: 0, navigation: hop)
        #expect(record.update(native: [native(1, "b"), CefRemote.HistoryEntry(id: 2, url: "https://a.test/b#top", title: "", isCurrent: true)],
                              navigation: hop) == .collapse(keeping: "https://a.test/b#top", count: 2))
        #expect(record.back.isEmpty && paths(record.forward) == ["b"])
    }

    @Test func aRedirectedHopIsFoundByTheAddressItCommitted() throws {
        var record = seeded(back: ["old"], forward: [])
        _ = record.update(native: [native(1, "b", current: true)], navigation: nil)
        let hop = PageNavigation()
        record.startHop(to: try #require(record.back.first).id, window: [native(-1, "b", current: true)], current: 0, navigation: hop)
        record.noteCommit(URL(string: "https://a.test/new"), navigation: hop)
        #expect(record.saved(window: [native(1, "b", current: true)], current: 0) == .init(back: [], forward: [entry("b")]),
                "a hop that committed saves the list it re-forms")
        _ = record.update(native: [native(1, "b"), native(2, "new", current: true)], navigation: hop)
        #expect(record.back.isEmpty && paths(record.forward) == ["b"])
    }
}
