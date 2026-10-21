// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

/// A task also shows in every tab the in-app assistant opens for it. A connected app's tabs carry the AI mark instead, from the
/// grant the app holds on each tab it opens (`MCPVisibilityTests`).
@MainActor
@Suite(.boundedWebViews)
struct AgentOpenedTabsTests {
    @Test func aTaskShowsInTheTabsItOpens() {
        let log = ConversationLog(database: .temporary())
        let origin = UUID()
        let opened = UUID()
        let task = log.beginTask("Plan a trip", tabID: origin)
        log.noteOpenedTab(opened, taskID: task)
        log.noteOpenedTab(opened, taskID: task)
        log.noteOpenedTab(origin, taskID: task)

        #expect(log.traces(forTab: origin).map(\.id) == [task])
        #expect(log.traces(forTab: opened).map(\.id) == [task])
        #expect(log.traces.first?.openedTabIDs == [opened])
        #expect(log.traces(forTab: UUID()).isEmpty)
        #expect(log.latestTrace(forTab: opened) == nil)
    }

    @Test func openedTabsSurviveARelaunch() {
        let database = AppDatabase.temporary()
        let log = ConversationLog(database: database)
        let origin = UUID()
        let opened = UUID()
        let task = log.beginTask("Plan a trip", tabID: origin)
        log.noteOpenedTab(opened, taskID: task)
        log.completeTask(task, response: "Done.")
        log.saveBlocking()

        let reloaded = ConversationLog(database: database)
        #expect(reloaded.traces(forTab: opened).map(\.id) == [task])
    }

    @Test func movingAnOpenedTabMovesItsView() {
        let log = ConversationLog(database: .temporary())
        let origin = UUID()
        let opened = UUID()
        let moved = UUID()
        let task = log.beginTask("Plan a trip", tabID: origin)
        log.noteOpenedTab(opened, taskID: task)
        log.reassign(from: opened, to: moved)

        #expect(log.traces(forTab: moved).map(\.id) == [task])
        #expect(log.traces(forTab: opened).isEmpty)
        #expect(log.traces(forTab: origin).map(\.id) == [task])
    }

    @Test func theAssistantShowsItsWorkInATabItOpens() async throws {
        let browser = BrowserModel(database: .temporary())
        let origin = browser.newTab()
        let log = ConversationLog(database: .temporary())
        let toolkit = AgentToolkit(browser: browser, media: MediaCenter(), log: log)
        let taskID = log.beginTask("Open a page", tabID: origin.id)
        let task = AgentTaskContext(id: taskID, tabID: origin.id)
        toolkit.beginTask(task)

        _ = await toolkit.newTab(url: nil)
        let opened = try #require(browser.activeTab)
        #expect(opened !== origin)
        #expect(log.traces(forTab: browser.anchorID(of: opened.id)).map(\.id) == [taskID])
        #expect(opened.isAgentWorking)
        #expect(opened.processState.externalControllers.isEmpty, "the AI mark stays for connected apps")

        toolkit.finishTask(task)
        #expect(!opened.isAgentWorking)
    }

    /// A task the next one cancelled may never reach finishTask, so starting the next task ends the work shown in its tabs.
    @Test func theNextTaskEndsTheWorkShownInTheTabsTheLastOneOpened() async throws {
        let browser = BrowserModel(database: .temporary())
        let origin = browser.newTab()
        let log = ConversationLog(database: .temporary())
        let toolkit = AgentToolkit(browser: browser, media: MediaCenter(), log: log)
        toolkit.beginTask(AgentTaskContext(id: log.beginTask("Open a page", tabID: origin.id), tabID: origin.id))
        _ = await toolkit.newTab(url: nil)
        let opened = try #require(browser.activeTab)
        #expect(opened.isAgentWorking)

        toolkit.beginTask(AgentTaskContext(id: log.beginTask("Next", tabID: origin.id), tabID: origin.id))

        #expect(!opened.isAgentWorking)
    }
}
