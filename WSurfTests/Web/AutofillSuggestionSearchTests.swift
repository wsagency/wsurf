// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// The quick search of a long fill dropdown: what a key does, which rows match, and that a typed password is never a query.
/// Synthetic rows only.
struct AutofillSuggestionSearchTests {
    private typealias Search = AutofillSuggestionSearch

    private func row(_ title: String, detail: String = "") -> AutofillSuggestion {
        AutofillSuggestion(id: UUID(), title: title, detail: detail, origin: "https://login.example.test")
    }

    private func rows(_ count: Int) -> [AutofillSuggestion] {
        (0..<count).map { row("user\($0)@example.test", detail: "https://login.example.test") }
    }

    /// Eight rows; "work" is in the detail of rows 2, 5 and 7.
    private func eight() -> [AutofillSuggestion] {
        (0..<8).map { row("user\($0)@example.test", detail: [2, 5, 7].contains($0) ? "Work vault" : "Home vault") }
    }

    private func press(
        _ keys: [Search.KeyInput], on list: [AutofillSuggestion], typeToSearch: Bool, searching: Bool = false
    ) -> (state: Search.State, effects: [Search.Effect]) {
        let index = Search.Index(list, searchable: true)
        var state = Search.State(rowCount: list.count)
        if searching {
            state.beginSearching()
        }
        var effects: [Search.Effect] = []
        for key in keys {
            let (next, effect) = Search.reduce(state, key, index: index, typeToSearch: typeToSearch)
            state = next
            effects.append(effect)
        }
        return (state, effects)
    }

    private func typing(_ text: String) -> [Search.KeyInput] {
        text.map { .character(String($0)) }
    }

    @Test func theSearchRowAppearsOnlyAboveFiveRows() {
        #expect(!Search.Index(rows(5), searchable: true).isSearchable)
        #expect(Search.Index(rows(6), searchable: true).isSearchable)
        #expect(!Search.Index(rows(40), searchable: false).isSearchable, "card and contact lists never search")
        let five = AutofillSuggestionLayout.height(for: 5)
        #expect(five == 283, "a short list keeps its size")
        #expect(AutofillSuggestionLayout.height(for: 6, searchable: true) == five + AutofillSuggestionLayout.searchRowHeight + 1)
        #expect(AutofillSuggestionLayout.height(for: 3000, searchable: true) == AutofillSuggestionLayout.height(for: 6, searchable: true))
    }

    @Test func aQueryMatchesTitleAndDetailIgnoringCaseAndAccents() {
        let list = [
            row("José Álvarez", detail: "École Vault"), row("ada@example.test", detail: "Work vault"),
            row("bob@example.test", detail: "Home vault"), row("cy@example.test"), row("di@example.test"), row("ed@example.test"),
        ]
        let index = Search.Index(list, searchable: true)
        #expect(index.matches("jose") == [0])
        #expect(index.matches("ÁLVAREZ") == [0])
        #expect(index.matches("ecole") == [0], "the detail is searched too")
        #expect(index.matches("WORK") == [1])
        #expect(index.matches("ada work") == [1], "every word must match, in the title or the detail")
        #expect(index.matches("ada home").isEmpty)
        #expect(index.matches("example.test").count == 5)
        #expect(index.matches("   ") == Array(list.indices), "a blank query shows everything")
        #expect(index.matches("zzz").isEmpty)
    }

    @Test func typingInAUsernameFieldSearchesAndNeverReachesThePage() {
        let list = eight()
        let (state, effects) = press(typing("user2"), on: list, typeToSearch: true)
        #expect(effects.allSatisfy { $0 == .consume }, "every typed character is ours")
        #expect(state.isSearching)
        #expect(state.query == "user2")
        #expect(state.matches == [2])
        #expect(state.keyboard == 2, "the first match is highlighted so Return can pick it")
    }

    @Test func typingInAPasswordFieldNeverSearchesUntilTheSearchRowIsClicked() {
        let list = eight()
        let typed = press(typing("hunter2"), on: list, typeToSearch: false)
        #expect(typed.effects.first == .dismissAndPass, "the first character closes the list and goes to the page")
        #expect(!typed.state.isSearching)
        #expect(typed.state.query.isEmpty, "a typed password is never a query")
        #expect(typed.state.matches.count == 8)

        let afterClick = press(typing("work"), on: list, typeToSearch: false, searching: true)
        #expect(afterClick.effects.allSatisfy { $0 == .consume })
        #expect(afterClick.state.query == "work")
        #expect(afterClick.state.matches == [2, 5, 7])
    }

    /// What the dropdown does with that effect: the text reaches the focused field through the engine's own text input.
    @MainActor
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func theUnmatchedQueryLandsInTheFocusedField(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><input id=u autocomplete=username>")])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration), context: context)
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            page = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        var failure: (any Error)?
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try #require(window.makeFirstResponder(page))
            _ = try await page.evaluateJavaScript("document.getElementById('u').focus(); true")
            try #require(press(typing("user2x"), on: eight(), typeToSearch: true).effects.last == .dismissAndInsert("user2x"))
            AutofillSuggestions.insert("user2x", in: page)
            #expect(await waitUntil {
                (try? await page.evaluateJavaScript("document.getElementById('u').value")) as? String == "user2x"
            }, "the typed text is the field's on \(engine)")
        } catch {
            failure = error
        }
        await page.close()
        window.contentView = nil
        window.close()
        await context.endPrivateSession()
        if let failure {
            throw failure
        }
    }

    @Test func escapeClearsTheQueryThenCloses() {
        let (cleared, first) = press(typing("work") + [.escape], on: eight(), typeToSearch: true)
        #expect(first.last == .consume)
        #expect(cleared.query.isEmpty && cleared.isSearching && cleared.matches.count == 8 && cleared.keyboard == nil)
        let (_, second) = press(typing("work") + [.escape, .escape], on: eight(), typeToSearch: true)
        #expect(second.last == .dismiss)
        let (_, withoutQuery) = press([.escape], on: eight(), typeToSearch: true, searching: true)
        #expect(withoutQuery == [.dismiss])
    }

    @Test func backspaceOnAnEmptyQueryGoesToThePageAndCloses() {
        let (edited, effects) = press(typing("wor") + [.backspace], on: eight(), typeToSearch: true)
        #expect(effects.last == .consume)
        #expect(edited.query == "wo")
        let (_, clicked) = press([.backspace], on: eight(), typeToSearch: false, searching: true)
        #expect(clicked == [.dismissAndPass], "an empty query has nothing to delete")
        let (_, idle) = press([.backspace], on: eight(), typeToSearch: true)
        #expect(idle == [.dismissAndPass], "before any search, Backspace is the page's")
    }

    @Test func arrowsAndReturnUseOnlyTheMatchingRows() {
        let list = eight()
        let (state, effects) = press(typing("work") + [.down, .down], on: list, typeToSearch: true)
        #expect(effects.suffix(2).allSatisfy { $0 == .consume })
        #expect(state.matches == [2, 5, 7])
        #expect(state.keyboard == 7, "typing highlights row 2; two downs reach 5 then 7")
        let wrapped = press(typing("work") + [.down, .down, .down], on: list, typeToSearch: true)
        #expect(wrapped.state.keyboard == 2)
        let upFromFirst = press(typing("work") + [.up], on: list, typeToSearch: true)
        #expect(upFromFirst.state.keyboard == 7)
        let chosen = press(typing("work") + [.down, .enter], on: list, typeToSearch: true)
        #expect(chosen.effects.last == .choose(list[5].id))
        // A search started from the search row of a password field keeps a query that matches nothing; the arrows have no row to
        // reach, and Return chooses nothing and goes to the page.
        let noMatch = press(typing("nothing") + [.down, .up, .enter], on: list, typeToSearch: false, searching: true)
        #expect(noMatch.state.matches.isEmpty && noMatch.state.keyboard == nil)
        #expect(Array(noMatch.effects.suffix(3)) == [.consume, .consume, .dismissAndPass], "a query without rows never chooses one")
    }

    /// In a username field typing is meant for the field once it names no saved account: the first character that leaves no
    /// match closes the dropdown and everything typed so far goes into the field. Nothing typed is lost.
    @Test func aUsernameQueryThatMatchesNothingBecomesTheFieldsText() {
        let list = eight()
        let (state, effects) = press(typing("user2x"), on: list, typeToSearch: true)
        #expect(Array(effects.prefix(5)) == Array(repeating: .consume, count: 5), "user2 still names a row")
        #expect(effects.last == .dismissAndInsert("user2x"))
        #expect(state.matches.isEmpty && state.keyboard == nil)
        let first = press(typing("z"), on: list, typeToSearch: true)
        #expect(first.effects == [.dismissAndInsert("z")], "a first character that matches nothing is the field's at once")
        let afterBackspace = press(typing("wor") + [.backspace] + typing("q"), on: list, typeToSearch: true)
        #expect(afterBackspace.effects.last == .dismissAndInsert("woq"), "the query as edited, not as typed")
    }

    @Test func returnWithNothingHighlightedStillGoesToThePage() {
        let (_, effects) = press([.enter], on: eight(), typeToSearch: true)
        #expect(effects == [.dismissAndPass])
        let (_, clicked) = press([.enter], on: eight(), typeToSearch: false, searching: true)
        #expect(clicked == [.dismissAndPass], "an empty query is not a search")
    }

    @Test func fiveOrFewerRowsBehaveAsBefore() {
        let list = rows(5)
        let index = Search.Index(list, searchable: true)
        let start = Search.State(rowCount: 5)
        for key in typing("a") + [.backspace, .other] {
            let (state, effect) = Search.reduce(start, key, index: index, typeToSearch: true)
            #expect(effect == .dismissAndPass)
            #expect(state == start, "text keys never touch the list")
        }
        #expect(Search.reduce(start, .escape, index: index, typeToSearch: true).1 == .dismiss)
        #expect(Search.reduce(start, .enter, index: index, typeToSearch: true).1 == .dismissAndPass)
        let down = Search.reduce(start, .down, index: index, typeToSearch: true)
        #expect(down.1 == .consume && down.0.keyboard == 0)
        #expect(Search.reduce(start, .up, index: index, typeToSearch: true).0.keyboard == 4)
        #expect(Search.reduce(down.0, .enter, index: index, typeToSearch: true).1 == .choose(list[0].id))
        let last = (0..<5).reduce(start) { state, _ in Search.reduce(state, .down, index: index, typeToSearch: true).0 }
        #expect(last.keyboard == 4)
        #expect(Search.reduce(last, .down, index: index, typeToSearch: true).0.keyboard == 0, "the sixth down goes round")
        #expect(Search.reduce(Search.State(rowCount: 0), .down, index: Search.Index([], searchable: true), typeToSearch: true).1 == .pass)
    }

    @Test func theQueryIsCapped() {
        // One row matches every prefix of the typed run, so the cap is what stops the query.
        let list = eight() + [row(String(repeating: "a", count: Search.queryLimit + 50))]
        let (state, effects) = press(Array(repeating: .character("a"), count: Search.queryLimit + 50), on: list, typeToSearch: true)
        #expect(state.query.count == Search.queryLimit)
        #expect(effects.allSatisfy { $0 == .consume }, "extra characters are swallowed, not sent to the page")
    }

    @Test(.timeLimit(.minutes(1))) func filteringThreeThousandRowsTakesUnder20Milliseconds() {
        let list = (0..<3000).map { row("user\($0)@example\($0 % 40).test", detail: "https://site\($0 % 90).example.test · Vault \($0 % 3)") }
        let index = Search.Index(list, searchable: true)
        var state = Search.State(rowCount: list.count)
        let clock = ContinuousClock()
        var slowest = Duration.zero
        for character in "site7 vault 2" {
            let elapsed = clock.measure {
                state = Search.reduce(state, .character(String(character)), index: index, typeToSearch: true).0
            }
            slowest = max(slowest, elapsed)
        }
        #expect(slowest < .milliseconds(20))
        #expect(!state.matches.isEmpty)
        #expect(state.matches.allSatisfy { list[$0].detail.lowercased().contains("site7") })
    }

    @Test func keysAreTranslatedFromTheEventNotGuessed() throws {
        func event(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
        }
        #expect(try Search.KeyInput(event("a", keyCode: 0)) == .character("a"))
        #expect(try Search.KeyInput(event("A", keyCode: 0, modifiers: .shift)) == .character("A"))
        #expect(try Search.KeyInput(event(" ", keyCode: 49)) == .character(" "))
        #expect(try Search.KeyInput(event("\u{F701}", keyCode: 125)) == .down)
        #expect(try Search.KeyInput(event("\u{F700}", keyCode: 126)) == .up)
        #expect(try Search.KeyInput(event("\r", keyCode: 36)) == .enter)
        #expect(try Search.KeyInput(event("\u{3}", keyCode: 76)) == .enter)
        #expect(try Search.KeyInput(event("\u{1B}", keyCode: 53)) == .escape)
        #expect(try Search.KeyInput(event("\u{7F}", keyCode: 51)) == .backspace)
        #expect(try Search.KeyInput(event("\t", keyCode: 48)) == .other, "Tab moves focus; it is not text")
        #expect(try Search.KeyInput(event("\u{F708}", keyCode: 96)) == .other, "a function key is not text")
        #expect(try Search.KeyInput(event("\u{F728}", keyCode: 117)) == .other, "forward delete is not Backspace")
        #expect(try Search.KeyInput(event("", keyCode: 14)) == .other, "a dead key composes with the next one")
        #expect(try Search.KeyInput(event("ab", keyCode: 0)) == .other, "composed text is not one typed character")
    }
}
