// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Closing a tab through the assistant: when it asks, what it never closes, and what a "yes" or a Stop does.
@MainActor
@Suite(.boundedWebViews)
struct AgentTabClosingTests {
    /// Every question the sheet would have shown, and the answer to give.
    private final class Sheet {
        var asked: [AgentTabClosing.Question] = []
        var answer = AgentTabClosing.Answer.close
        var whenAsked: (@MainActor () -> Void)?
    }

    private struct Rig {
        let browser: BrowserModel
        let store: SitePermissions
        let toolkit: AgentToolkit
        let taskTab: BrowserTab
        let other: BrowserTab
        let task: AgentTaskContext
    }

    private func rig(default policy: AssistantAccessPolicy = .ask, closing: AssistantTabClosing = .ask) -> Rig {
        let store = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("TabClosing-\(UUID().uuidString).json"))
        store.setAssistantDefault(policy)
        store.setAssistantTabClosing(closing)
        let browser = BrowserModel(database: .temporary(), sitePermissions: store)
        let other = browser.newTab()
        other.customTitle = "Research notes"
        let taskTab = browser.newTab()
        taskTab.customTitle = "Task page"
        let toolkit = AgentToolkit(browser: browser, media: MediaCenter(), log: ConversationLog(database: .temporary()))
        let task = AgentTaskContext(id: UUID(), tabID: taskTab.id, mentionedTabIDs: [other.id])
        toolkit.beginTask(task)
        return Rig(browser: browser, store: store, toolkit: toolkit, taskTab: taskTab, other: other, task: task)
    }

    private func closing(_ sheet: Sheet, _ body: () async -> String) async -> String {
        await AgentTabClosing.$decisionForTesting.withValue(.init { question in
            sheet.asked.append(question)
            sheet.whenAsked?()
            return sheet.answer
        }) {
            await body()
        }
    }

    // MARK: When it asks

    @Test func closingAsksByDefault() async {
        let r = rig()
        let sheet = Sheet()

        let output = await closing(sheet) { await r.toolkit.closeTab(matching: "Research") }

        #expect(sheet.asked == [.init(title: "Research notes", isPrivate: false, client: nil)])
        #expect(output == "Closed “Research notes”.")
        #expect(!r.browser.tabs.contains { $0 === r.other })
    }

    @Test func closingTheActiveTabAsksToo() async {
        let r = rig()
        let sheet = Sheet()
        r.browser.activate(r.taskTab)

        let output = await closing(sheet) { await r.toolkit.closeTab(matching: nil) }

        #expect(sheet.asked.map(\.title) == ["Task page"])
        #expect(output == "Closed the active tab.")
        #expect(!r.browser.tabs.contains { $0 === r.taskTab })
    }

    @Test func decliningKeepsTheTabAndSaysSo() async {
        let r = rig()
        let sheet = Sheet()
        sheet.answer = .keepOpen

        let output = await closing(sheet) { await r.toolkit.closeTab(matching: "Research") }

        #expect(output.contains("The user chose to keep “Research notes” open"))
        #expect(r.browser.tabs.contains { $0 === r.other })
        #expect(r.toolkit.lastToolFailed)
    }

    @Test(arguments: [AssistantAccessPolicy.ask, .readOnly])
    func allowClosingAppliesOnlyWithTheAllowControlDefault(policy: AssistantAccessPolicy) async {
        let r = rig(default: policy, closing: .allow)
        let sheet = Sheet()

        _ = await closing(sheet) { await r.toolkit.closeTab(matching: "Research") }

        #expect(sheet.asked.count == 1)
    }

    @Test func allowClosingSkipsTheQuestionUnderAllowControl() async {
        let r = rig(default: .control, closing: .allow)
        let sheet = Sheet()

        let output = await closing(sheet) { await r.toolkit.closeTab(matching: "Research") }

        #expect(sheet.asked.isEmpty)
        #expect(output == "Closed “Research notes”.")
        #expect(!r.browser.tabs.contains { $0 === r.other })
    }

    @Test func askToCloseStillAsksUnderAllowControl() async {
        let r = rig(default: .control, closing: .ask)
        let sheet = Sheet()

        _ = await closing(sheet) { await r.toolkit.closeTab(matching: "Research") }

        #expect(sheet.asked.count == 1)
    }

    // MARK: What never asks, and what never closes

    @Test func tabsTheAssistantOpenedCloseWithoutAsking() async {
        let r = rig()
        let sheet = Sheet()
        _ = await r.toolkit.newTab(url: nil)
        let opened = r.browser.activeTab
        opened?.customTitle = "Scratch"

        let output = await closing(sheet) { await r.toolkit.closeTab(matching: "Scratch") }

        #expect(sheet.asked.isEmpty)
        #expect(output == "Closed “Scratch”.")
        #expect(!r.browser.tabs.contains { $0 === opened })
    }

    @Test func aTabFromAnEarlierTaskAsksAgain() async {
        let r = rig()
        let sheet = Sheet()
        _ = await r.toolkit.newTab(url: nil)
        let opened = r.browser.activeTab
        opened?.customTitle = "Scratch"
        r.toolkit.beginTask(AgentTaskContext(id: UUID(), tabID: r.taskTab.id, mentionedTabIDs: [opened?.id].compactMap { $0 }))

        _ = await closing(sheet) { await r.toolkit.closeTab(matching: "Scratch") }

        #expect(sheet.asked.map(\.title) == ["Scratch"])
    }

    @Test func pinnedTabsAreNeverClosedOrAskedAbout() async {
        let r = rig(default: .control, closing: .allow)
        let sheet = Sheet()
        r.other.pinID = UUID()
        r.browser.activate(r.other)

        for reference in ["Research", nil] as [String?] {
            let output = await closing(sheet) { await r.toolkit.closeTab(matching: reference) }
            #expect(output.contains("Pinned tabs must be closed by the user"))
        }
        #expect(sheet.asked.isEmpty)
        #expect(r.browser.tabs.contains { $0 === r.other })
    }

    @Test func aTabPinnedWhileTheSheetIsOpenStaysOpen() async {
        let r = rig()
        let sheet = Sheet()
        sheet.whenAsked = { r.other.pinID = UUID() }

        let output = await closing(sheet) { await r.toolkit.closeTab(matching: "Research") }

        #expect(output.contains("Pinned tabs must be closed by the user"))
        #expect(r.browser.tabs.contains { $0 === r.other })
    }

    // MARK: Don't ask again

    @Test func dontAskAgainLastsOnlyForTheTask() async {
        let r = rig()
        let third = r.browser.newTab()
        third.customTitle = "Third page"
        let fourth = r.browser.newTab()
        fourth.customTitle = "Fourth page"
        r.toolkit.beginTask(AgentTaskContext(
            id: UUID(), tabID: r.taskTab.id, mentionedTabIDs: [r.other.id, third.id, fourth.id]))
        let sheet = Sheet()
        sheet.answer = .closeAndStopAsking

        _ = await closing(sheet) { await r.toolkit.closeTab(matching: "Research") }
        _ = await closing(sheet) { await r.toolkit.closeTab(matching: "Third") }
        #expect(sheet.asked.count == 1)
        #expect(!r.browser.tabs.contains { $0 === third })

        r.toolkit.beginTask(AgentTaskContext(id: UUID(), tabID: r.taskTab.id, mentionedTabIDs: [fourth.id]))
        sheet.answer = .close
        _ = await closing(sheet) { await r.toolkit.closeTab(matching: "Fourth") }
        #expect(sheet.asked.count == 2)
    }

    // MARK: Stop

    @Test func stoppingWhileTheSheetIsOpenKeepsTheTab() async {
        let r = rig()
        let sheet = Sheet()
        let box = TaskBox()
        sheet.whenAsked = { box.task?.cancel() }
        box.task = Task { @MainActor in
            await self.closing(sheet) { await r.toolkit.closeTab(matching: "Research") }
        }

        let output = await box.task?.value

        #expect(output == "Canceled.")
        #expect(r.browser.tabs.contains { $0 === r.other })
    }

    @Test func aTaskThatEndedBeforeTheQuestionNeverAsks() async {
        let r = rig()
        let sheet = Sheet()
        let box = TaskBox()
        box.task = Task { @MainActor in
            await self.closing(sheet) { await r.toolkit.closeTab(matching: "Research") }
        }
        box.task?.cancel()

        let output = await box.task?.value

        #expect(output == "Canceled.")
        #expect(sheet.asked.isEmpty)
        #expect(r.browser.tabs.contains { $0 === r.other })
    }

    @Test func withoutAWindowToAskInTheTabStaysOpen() async {
        let r = rig()

        let output = await r.toolkit.closeTab(matching: "Research")

        #expect(output.contains("The user chose to keep"))
        #expect(r.browser.tabs.contains { $0 === r.other })
    }

    // MARK: The sheet

    @Test func theSheetNamesTheTabAndWhoAsks() {
        let assistant = AgentTabClosing.Question(title: "Research notes", isPrivate: false, client: nil)
        let app = AgentTabClosing.Question(title: "Research notes", isPrivate: false, client: "Claude Code")
        let privateTab = AgentTabClosing.Question(title: "Research notes", isPrivate: true, client: nil)

        #expect(AgentTabClosing.heading(for: assistant) == "Close “Research notes”?")
        #expect(AgentTabClosing.body(for: assistant)
            == "The assistant wants to close this tab. You can reopen it with Reopen Last Closed Tab.")
        #expect(AgentTabClosing.body(for: app).hasPrefix("“Claude Code” wants to close this tab."))
        #expect(AgentTabClosing.body(for: privateTab) == "The assistant wants to close this tab.")
    }

    @Test func aPagesTitleIsOneShortLineOnTheSheet() {
        let long = String(repeating: "word ", count: 60)
        let shown = AgentTabClosing.shown("Line one\nLine\ttwo\u{0}  " + long)

        #expect(!shown.contains("\n") && !shown.contains("\t") && !shown.contains("\u{0}"))
        #expect(shown.hasPrefix("Line one Line two word"))
        #expect(shown.hasSuffix("…"))
        #expect(shown.count == 81)
        let untitled = AgentTabClosing.Question(title: "  \n ", isPrivate: false, client: nil)
        #expect(AgentTabClosing.heading(for: untitled) == "Close this tab?")
    }
}

/// Lets a sheet stub reach the task that is waiting on it.
@MainActor
private final class TaskBox {
    var task: Task<String, Never>?
}
