// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AnyLanguageModel
import AppKit
import Foundation
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct TabOrganizerTests {
    private let tabs: [(id: UUID, title: String)] = (1...6).map { number in
        (UUID(), "Tab \(number)")
    }

    @Test func aPlanKeepsSidebarOrderAndDropsUnknownNumbers() {
        let plan = TabOrganizer.plan(
            from: [("Research", [5, 2, 99, 2, 0])],
            tabs: tabs
        )
        #expect(plan.folders.count == 1)
        #expect(plan.folders.first?.name == "Research")
        #expect(plan.folders.first?.tabIDs == [tabs[1].id, tabs[4].id])
    }

    @Test func aTabClaimedTwiceStaysWithItsFirstGroup() {
        let plan = TabOrganizer.plan(
            from: [("First", [1, 2]), ("Second", [2, 3])],
            tabs: tabs
        )
        #expect(plan.folders.count == 1)
        #expect(plan.folders.first?.name == "First")
    }

    @Test func aGroupLeftWithOneTabDissolves() {
        let plan = TabOrganizer.plan(
            from: [("Lonely", [4]), ("Pair", [1, 6])],
            tabs: tabs
        )
        #expect(plan.folders.map(\.name) == ["Pair"])
    }

    @Test func aShoutedOrJunkNameFallsBackCleanly() {
        let plan = TabOrganizer.plan(
            from: [("TRAVEL PLANNING", [1, 2]), ("\"..\"", [3, 4])],
            tabs: tabs
        )
        #expect(plan.folders.map(\.name) == ["Travel Planning", "New Folder"])
    }

    @Test func groupLinesParseBackIntoNamesAndNumbers() {
        let parsed = TabOrganizer.groups(in: [
            "Trip Planning: 2, 5",
            "Docs: 1,3 ,4",
            "Nameless 1, 2",
            ": 1, 2",
            "Lonely: 3",
            "Re: search: 5, 6",
        ])
        #expect(parsed.map(\.name) == ["Trip Planning", "Docs", "Re: search"])
        #expect(parsed.map(\.numbers) == [[2, 5], [1, 3, 4], [5, 6]])
    }

    @Test func nothingUsableMeansAnEmptyPlan() {
        let plan = TabOrganizer.plan(from: [("Ghosts", [40, 50])], tabs: tabs)
        #expect(plan.folders.isEmpty)
    }

    /// The apply half of organizing, minus the model: the folders a plan
    /// names must actually contain their tabs afterwards.
    @Test func applyingAPlanPutsTheTabsInTheirFolders() {
        let browser = BrowserModel(database: .temporary())
        let open = (1...5).map { number in
            let tab = browser.newTab()
            tab.title = "Tab \(number)"
            return tab
        }

        let plan = TabOrganizer.plan(
            from: [("Pets", [1, 2]), ("Work", [3, 4])],
            tabs: open.map { ($0.id, $0.title) }
        )
        for planned in plan.folders {
            let members = planned.tabIDs.compactMap { id in browser.tabs.first { $0.id == id } }
            browser.createFolder(named: planned.name, containing: members)
        }

        let pets = browser.folders.first { $0.name == "Pets" }
        let work = browser.folders.first { $0.name == "Work" }
        #expect(pets.map { browser.tabs(in: $0).map(\.id) } == [open[0].id, open[1].id])
        #expect(work.map { browser.tabs(in: $0).map(\.id) } == [open[2].id, open[3].id])
        #expect(browser.folder(containing: open[4]) == nil)
    }

    @Test func aDeferredPrivateProposalPresentsOnlyInItsOriginatingWindow() async throws {
        let privateContext = BrowserProfileContext.shared(for: .privateBrowsing())
        let regularContext = BrowserProfileContext(profile: .original())
        let owner = AppCoordinator(browser: BrowserModel(context: privateContext, windowID: UUID()))
        let other = AppCoordinator(browser: BrowserModel(context: regularContext, windowID: UUID()))
        let app = BrowserApplication()
        app.register(owner)
        app.register(other)
        let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let focused = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 700, height: 500),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        focused.isReleasedWhenClosed = false
        owner.extensions.register(browser: owner.browser, window: native)
        other.extensions.register(browser: other.browser, window: focused)
        let tabs = (1...4).map { index in
            let tab = owner.browser.newTab()
            tab.title = "Private research \(index)"
            return tab
        }.reversed()
        let model = DeferredGroupingModel()
        defer {
            model.gate.open()
            if let sheet = native.attachedSheet {
                native.endSheet(sheet, returnCode: .abort)
            }
            if let sheet = focused.attachedSheet {
                focused.endSheet(sheet, returnCode: .abort)
            }
            owner.closeWindow()
            other.closeWindow()
            native.close()
            focused.close()
        }
        try await UtilityModelSource.$make.withValue({ model }) {
            app.focus(owner)
            native.makeKeyAndOrderFront(nil)
            owner.organizeTabs()
            try #require(await waitUntil { model.gate.requestCount == 1 })
            app.focus(other)
            focused.makeKeyAndOrderFront(nil)
            model.gate.open()
            try #require(await waitUntil { native.attachedSheet != nil || focused.attachedSheet != nil })
            #expect(focused.attachedSheet == nil)
            let sheet = try #require(native.attachedSheet)
            native.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            try #require(await waitUntil { owner.browser.folders.count == 1 })
            let folder = try #require(owner.browser.folders.first)
            #expect(owner.browser.tabs(in: folder).map(\.id) == Array(tabs.prefix(2)).map(\.id))
            #expect(other.browser.tabs.isEmpty)
            #expect(other.browser.folders.isEmpty)
        }
    }
}

private final class DeferredGroupingModel: LanguageModel, @unchecked Sendable {
    let gate = ResponseGate()

    func respond<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        await withCheckedContinuation { continuation in
            gate.submit { continuation.resume() }
        }
        guard let content = TabOrganizer.Grouping(groups: ["Private Research: 1, 2"]) as? Content else {
            throw HarnessFixtureFailure()
        }
        return .init(content: content, rawContent: content.generatedContent, transcriptEntries: [])
    }

    func streamResponse<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        guard let content = TabOrganizer.Grouping(groups: ["Private Research: 1, 2"]) as? Content else {
            preconditionFailure("The grouping fixture accepts TabOrganizer.Grouping")
        }
        return .init(content: content, rawContent: content.generatedContent)
    }
}
