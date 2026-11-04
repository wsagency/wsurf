// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// The rows under the address field are computed once per change and read from the model the rest of the time. These cases hold
/// that to its two halves: after a change to anything the rows read, the stored rows are the ones the state asks for now, and a
/// change they do not read, or a second read, does not search again. `Omnibox.agentOnlyForTesting` stays pinned so no keystroke can
/// leave the machine as a completion request.
@MainActor
struct AskSurfaceSectionsTests {
    private func makeModel(placement: AskSurface.Placement = .toolbar) -> AskSurfaceModel {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        return AskSurfaceModel(placement: placement, browser: coordinator.browser, coordinator: coordinator)
    }

    /// What each row says, in order, for comparing two lists of rows.
    private func rows(_ sections: [OmniboxSection]) -> [String] {
        sections.flatMap { section in
            section.items.map { "\(section.id)|\($0.id)|\($0.title)|\($0.detail)" }
        }
    }

    /// The stored rows must equal the rows computed now, and `expected` must be among them: a case that only compares the two would
    /// pass if both were always empty.
    private func expectCurrent(
        _ model: AskSurfaceModel, containing expected: String? = nil, _ step: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let stored = rows(model.sections)
        #expect(stored == rows(model.resultSections()), Comment(rawValue: step), sourceLocation: sourceLocation)
        if let expected {
            #expect(
                stored.contains { $0.contains(expected) },
                Comment(rawValue: "\(step): \(stored)"),
                sourceLocation: sourceLocation
            )
        }
    }

    @Test func aSecondReadAndAnUnrelatedChangeDoNotComputeTheRowsAgain() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let model = makeModel()
            defer { model.browser.cancelPendingSave() }
            model.browser.newTab().title = "Radio"
            model.fieldFocusDidChange(true)
            model.interaction.text = "radio"

            expectCurrent(model, containing: "omnibox-tab-", "first read")
            let computed = model.sectionComputations
            _ = model.sections
            _ = model.sections
            #expect(model.sectionComputations == computed, "reading twice")

            // What the surface shows besides the rows: a notice, and the assistant's reply.
            model.coordinator.show(notice: "Copied")
            _ = model.sections
            #expect(model.sectionComputations == computed, "a notice")
        }
    }

    @Test func anUnfocusedFieldComputesNothingWhateverIsTypedOrOpened() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let model = makeModel()
            defer { model.browser.cancelPendingSave() }
            #expect(model.sections.isEmpty)
            let computed = model.sectionComputations

            model.interaction.text = "radio"
            model.browser.newTab().title = "Radio"
            model.browser.newTab().title = "Radio news"

            #expect(model.sections.isEmpty)
            #expect(model.sectionComputations == computed)
        }
    }

    @Test func eachChangeToTheTextOrFocusIsComputedOnce() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let model = makeModel()
            defer { model.browser.cancelPendingSave() }
            model.browser.newTab().title = "Radio"
            model.fieldFocusDidChange(true)
            var computed = model.sectionComputations

            for text in ["r", "ra", "rad", "radi", "radio"] {
                model.interaction.text = text
                for _ in 0..<3 {
                    _ = model.sections
                }
                computed += 1
                #expect(model.sectionComputations == computed, "after typing \(text)")
            }
            expectCurrent(model, containing: "omnibox-tab-", "typed")

            model.fieldFocusDidChange(false)
            #expect(model.sections.isEmpty)
            model.fieldFocusDidChange(true)
            expectCurrent(model, "focused again")
        }
    }

    @Test func theRowsFollowTheTabsAndTheirTitles() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let model = makeModel()
            defer { model.browser.cancelPendingSave() }
            let radio = model.browser.newTab()
            radio.title = "Radio"
            model.fieldFocusDidChange(true)
            model.interaction.text = "tuner"
            expectCurrent(model, "no tab matches yet")
            #expect(!rows(model.sections).contains { $0.contains("omnibox-tab-") })

            radio.title = "Tuner radio"
            expectCurrent(model, containing: "Tuner radio", "a title changed")

            radio.title = "Tuner radio live"
            expectCurrent(model, containing: "Tuner radio live", "the title changed again")

            radio.urlString = "https://tuner.example/live"
            expectCurrent(model, containing: "tuner.example", "an address changed")

            let news = model.browser.newTab()
            news.title = "Tuner news"
            news.urlString = "https://news.example/"
            model.interaction.text = "news"
            expectCurrent(model, containing: "Tuner news", "a tab opened")

            model.browser.close(news)
            expectCurrent(model, "a tab closed")
            #expect(!rows(model.sections).contains { $0.contains("Tuner news") })
        }
    }

    @Test func theRowsFollowTheActiveTabAndItsAddress() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let model = makeModel(placement: .toolbar)
            defer { model.browser.cancelPendingSave() }
            let first = model.browser.newTab()
            first.urlString = "https://first.example/page"
            let second = model.browser.newTab()
            second.urlString = "https://second.example/page"
            model.browser.activate(first)
            model.fieldFocusDidChange(true)
            // The toolbar shows the page's own address at rest: it lists nothing for it.
            model.interaction.text = "https://first.example/page"
            expectCurrent(model, "the address of the active tab")
            #expect(model.sections.isEmpty)

            model.browser.activate(second)
            expectCurrent(model, "another tab is active")
            #expect(!model.sections.isEmpty)

            second.urlString = "https://first.example/page"
            expectCurrent(model, "the active tab moved to the typed address")
            #expect(model.sections.isEmpty)
        }
    }

    @Test func theRowsFollowMentionsAndTheSiteSearchAndAPreviewedRow() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let model = makeModel(placement: .startPage)
            defer { model.browser.cancelPendingSave() }
            let active = model.browser.newTab()
            active.title = "Lofi radio"
            active.urlString = "https://radio.example/lofi"
            let other = model.browser.newTab(url: URL(string: "https://shop.example/air-max"))
            other.title = "Nike Air Max"
            model.browser.activate(active)
            model.fieldFocusDidChange(true)
            model.interaction.text = "which is cheaper @ni"
            expectCurrent(model, containing: "mention-\(other.id)", "a mention is offered")

            model.mention(other)
            expectCurrent(model, "the tab is mentioned")
            #expect(!rows(model.sections).contains { $0.contains("mention-\(other.id)") })

            model.removeMention(other.id)
            model.interaction.text = "youtube"
            #expect(model.activateSiteSearch())
            model.interaction.text = "lofi"
            expectCurrent(model, containing: "site-search", "a site search")

            #expect(model.removeSearchSite())
            expectCurrent(model, containing: "ask-agent", "the site search ended")

            model.selectSuggestion(at: 1, in: model.sections)
            #expect(model.interaction.text == "https://radio.example/lofi")
            #expect(model.resultQuery == "lofi")
            expectCurrent(model, containing: "omnibox-tab-", "a row is previewed")
            model.interaction.text += " more"
            expectCurrent(model, containing: "more", "typing after the preview")
            #expect(!rows(model.sections).contains { $0.contains("omnibox-tab-") })
        }
    }

    @Test func theRowsFollowSuggestionsAndTheSettings() {
        Omnibox.$agentOnlyForTesting.withValue(false) {
            let model = makeModel(placement: .startPage)
            defer { model.browser.cancelPendingSave() }
            let settings = model.coordinator.context.settings
            let engine = settings.searchEngineID
            let showsSuggestions = settings.showsSearchSuggestions
            defer {
                settings.searchEngineID = engine
                settings.showsSearchSuggestions = showsSuggestions
            }
            // Off, so that typing does not ask the engine; the suggestions are put in by hand.
            settings.showsSearchSuggestions = false
            settings.searchEngineID = SearchEngine.duckDuckGo.id
            model.fieldFocusDidChange(true)
            model.interaction.text = "tuner"
            expectCurrent(model, containing: "DuckDuckGo", "the engine in the rows")

            model.suggestions.store(["tuner radio"], for: "tuner", engine: .duckDuckGo)
            expectCurrent(model, containing: "tuner radio", "suggestions arrived")

            let other = SearchEngine.catalog.first { $0.id != SearchEngine.duckDuckGo.id }
            #expect(other != nil)
            settings.searchEngineID = other?.id ?? SearchEngine.duckDuckGo.id
            expectCurrent(model, containing: other?.name ?? "", "another search engine")
            #expect(!rows(model.sections).contains { $0.contains("DuckDuckGo") })
        }
    }

    @Test func theRowsFollowTheHistoryOfAShortQuery() {
        Omnibox.$agentOnlyForTesting.withValue(true) {
            let model = makeModel(placement: .startPage)
            defer { model.browser.cancelPendingSave() }
            let history = model.browser.history
            history.record(url: "https://zeta.example/one", title: "Zeta one")
            model.fieldFocusDidChange(true)
            model.interaction.text = "ze"
            expectCurrent(model, containing: "Zeta one", "a page in the history")

            history.record(url: "https://zebra.example/two", title: "Zebra two")
            expectCurrent(model, containing: "Zebra two", "a page visited while the field is open")
        }
    }
}
