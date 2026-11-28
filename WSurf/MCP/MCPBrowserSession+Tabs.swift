// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import MCP

/// In-memory provenance for a tab opened by external automation, independent of its current access grants.
nonisolated struct MCPAgentTabOrigin: Equatable, Sendable {
    let windowID: UUID
    let sessionID: UUID
    let pairedClientID: UUID?
    let clientName: String
}

extension BrowserModel {
    func agentTabOrigin(for tab: BrowserTab) -> MCPAgentTabOrigin? {
        guard !tab.isClosed, !tab.isPrivate, tab.staysInItsWindow, tab.spaceTabID == nil,
              tab.microTabID == nil, !tab.isPinnedForProfile, !tab.isFavorite,
              agentCompanion?.owner != .human,
              let source = tab.mcpAgentTabOrigin, source.windowID == windowID,
              sharedSpaceService?.sharesRow(tab.id, in: self) != true,
              reconciledTree().parent(of: .tab(tab.id)) == nil
        else { return nil }
        return source
    }

    func closeAgentTabs(openedBy sessionID: UUID) {
        for tab in tabs where agentTabOrigin(for: tab)?.sessionID == sessionID {
            close(tab, recordForReopening: false)
        }
    }

    func agentTabs(openedBy sessionID: UUID) -> [BrowserTab] {
        tabs.filter { agentTabOrigin(for: $0)?.sessionID == sessionID }
    }
}

/// Tab-level actions on a tab the connection already shares.
@MainActor
extension MCPBrowserSession {
    func attributeAgentTab(_ tab: BrowserTab) {
        guard tab.staysInItsWindow else { return }
        tab.mcpAgentTabOrigin = MCPAgentTabOrigin(
            windowID: browser.windowID, sessionID: id, pairedClientID: pairedClient?.id, clientName: pairedClient?.name ?? displayName)
    }

    func switchTab(_ tab: BrowserTab) -> CallTool.Result {
        browser.activate(tab)
        return success("Tab activated. Use readPage for fresh controls.")
    }

    /// Keeps a shared tab that is not on screen attached to this connection's window, parked out of sight, so its page loads
    /// (Chromium needs a window), renders and is not throttled while the person keeps their own tab. Never changes the
    /// selection, the key window or the first responder.
    func keepInWindow(_ tab: BrowserTab) {
        tab.realizeDeferredSession()
        let page = tab.page
        page.ignoresWindowOcclusion = true
        guard page.window == nil, !onScreen(tab), let window = consentWindow?.nativeWindow else { return }
        // A page that was never shown has the engine's default size; it gets the size of the page the window shows instead.
        let shown = browser.activeTab?.liveView?.bounds.size
        WebViewParking.park(page, in: window, size: shown.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil })
    }

    /// The person took `tab` over: this connection loses its grant, development lease, observation and dialog claim there,
    /// and a standing grant does not share the tab again for as long as the connection lasts. Its other tabs are untouched,
    /// and the tab is no longer one it opened, so it never closes it without asking.
    func handBack(_ tab: BrowserTab) {
        digestCache[tab.id] = nil
        tab.dialogs.handBack(connection: id)
        tab.removeDocumentCommitObserver(id: id)
        if let held = developmentTabs.removeValue(forKey: tab.id) {
            held.tab.releaseDevelopment(held.owner, reason: .grantDowngrade)
        }
        grants[tab.id] = nil
        observations[tab.id] = nil
        secretFields[tab.id] = nil
        inspectionApprovedDocuments[tab.id] = nil
        openedTabs.remove(tab.id)
        tab.mcpAgentTabOrigin = nil
        if let pair = comparison, [pair.webKit, pair.chromium].contains(tab.id) {
            comparison = nil
        }
        takenBack.insert(tab.id)
    }

    /// Records on each tab whether this connection holds a grant for it: the tab's AI mark, its protection from unloading and
    /// whether its page counts as seen while its window is covered follow the grants exactly, whichever path changed them. A
    /// tab nobody controls any more is hidden and pauses again while covered.
    func markControlledTabs(previous: [UUID: Grant]) {
        let changed = Set(previous.keys).symmetricDifference(grants.keys)
        guard !changed.isEmpty else { return }
        for tab in browser.tabs where changed.contains(tab.id) {
            tab.processState.setExternalController(id, holds: grants[tab.id] != nil)
            tab.liveView?.ignoresWindowOcclusion = !tab.processState.externalControllers.isEmpty
            // Once no connection drives the tab (taken over, revoked, disconnected), its page stops pretending to be focused.
            if tab.processState.externalControllers.isEmpty {
                tab.liveView?.chromium?.endAgentFocusEmulation()
            }
        }
    }

    /// Closes a shared tab. Pinned tabs never close. An ordinary tab closes only after the person says yes in WSurf, unless
    /// this connection opened it or holds Developer access on it (see `closesWithoutAsking`).
    func closeTab(_ tab: BrowserTab) async -> CallTool.Result {
        guard !tab.isPinnedForProfile else { return failure("Pinned tabs must be closed by the user.", code: .accessDenied) }
        if !closesWithoutAsking(tab) {
            let answer = await AgentTabClosing.ask(title: tab.title, isPrivate: tab.isPrivate)
            // Stop or a disconnect ends the question: the tab stays, whatever the sheet said.
            guard isConnected, available(), !Task.isCancelled else { return failure("The tab was not closed.", code: .accessDenied) }
            switch answer {
            case .keepOpen:
                return failure("The user chose to keep this tab open. Do not ask again unless they ask for it to be closed.", code: .accessDenied)
            case .closeAndStopAsking:
                closingWasConfirmed = true
            case .close:
                break
            }
            // The question took time: the access and the tab can have changed while it was open.
            guard mayProceed(tab, capability: .control), sharedTab(tab.id) === tab, !tab.isPinnedForProfile else {
                return failure("Page access changed before the tab was closed.", code: .accessDenied)
            }
        }
        tab.removeDocumentCommitObserver(id: id)
        browser.close(tab)
        grants[tab.id] = nil
        observations[tab.id] = nil
        secretFields[tab.id] = nil
        inspectionApprovedDocuments[tab.id] = nil
        openedTabs.remove(tab.id)
        return success("Tab closed.")
    }

    /// Switches a shared tab between Chromium and WebKit (Safari engine), keeping background tabs parked and reachable.
    /// Runs all access, reachability, open-dialog, origin, and user-tab protection checks BEFORE mutating tab state.
    func setTabEngine(_ engine: BrowserEngine, tab: BrowserTab, inPlace: Bool = false) async -> CallTool.Result {
        guard mayProceed(tab, capability: .control) else {
            return failure("This action is blocked by the connection’s access or the website’s Assistant Access setting.", code: .accessDenied)
        }
        guard isReachable(tab) else {
            return failure(Self.unreachableRefusal, code: .unsupported)
        }
        if let open = dialogRefusal(for: tab) {
            return open
        }
        guard let url = webURL(of: tab) else {
            return failure("The webpage is unavailable.", code: .pageUnavailable)
        }
        let origin = SitePermissions.origin(for: url)
        if engine == .chromium, SitePermissions.webKitOnlyOrigins.contains(origin) {
            return failure("This website requires WebKit and cannot switch to Chromium.", code: .webKitRequired)
        }
        let isAgentOwned = openedTabs.contains(tab.id) || grants[tab.id]?.source == .agentWindow
        if !inPlace, !isAgentOwned {
            return failure(
                "Switching engines reloads the page and clears Back/Forward history on this user-owned tab. "
                    + "Pass inPlace: true to reload it in place, or open a new tab with newTab(url, engine: \"\(engine.rawValue)\").")
        }
        if tab.engine == engine, tab.isMaterialised, tab.liveView?.engine == engine {
            keepInWindow(tab)
            let value: Value = .object([
                "status": "ok",
                "tabID": .string(tab.id.uuidString),
                "engine": .string(engine.rawValue),
                "switched": .bool(false),
                "message": .string("Tab is already running in \(String(localized: engine.label))."),
            ])
            return CallTool.Result(
                content: [.text(text: encoded(value), annotations: nil, _meta: nil)],
                structuredContent: Optional.some(value),
                isError: false)
        }
        let persistsAnswers = tab.assistantAccess.persistsAnswers
        let windowGeneration = agentWindowScope?.generation()
        let switched = await tab.switchEngine(to: engine) { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return self.mayProceed(tab, capability: .control) && self.agentWindowScope?.generation() == windowGeneration
        }
        guard switched else {
            return failure("Could not switch the tab engine.")
        }
        tab.engineOverride = engine
        // `installEngine` clears per-page state and builds a fresh page not yet attached to a window. Re-park it
        // immediately so Chromium begins loading `url`, and re-sync assistantAccess for `url` before checking access.
        tab.assistantAccess.persistsAnswers = persistsAnswers
        tab.assistantAccess.pageChanged(url: url)
        keepInWindow(tab)
        guard mayProceed(tab, capability: .control) else {
            return failure("Could not switch the tab engine or access changed.")
        }
        tab.removeDocumentCommitObserver(id: id)
        observations[tab.id] = nil
        secretFields[tab.id] = nil
        inspectionApprovedDocuments[tab.id] = nil
        let value: Value = .object([
            "status": "ok",
            "tabID": .string(tab.id.uuidString),
            "engine": .string(engine.rawValue),
            "switched": .bool(true),
            "message": .string("Switched tab to \(String(localized: engine.label)). Use readPage after it loads."),
        ])
        return CallTool.Result(
            content: [.text(text: encoded(value), annotations: nil, _meta: nil)],
            structuredContent: Optional.some(value),
            isError: false)
    }

    /// Whether this connection may close `tab` without the person being asked. Never from the profile's own Assistant
    /// settings, which a process with a shell can edit: only what this connection did itself, or the Keychain-backed trust
    /// store, which holds Developer access (a paired app, a developer site and the Developer profile).
    /// A tab this connection opened stops being its own once the person moves it into a folder or another Space: it is then a
    /// shared row that every window of the profile shows, and closing it would close it there too.
    func closesWithoutAsking(_ tab: BrowserTab) -> Bool {
        agentWindowScope != nil || (openedTabs.contains(tab.id) && tab.spaceTabID == nil) || closingWasConfirmed
            || permits(tab, capability: .developer)
    }

    /// The refusal for a `goBack` that would leave the granted website, or nil when the previous page may be loaded.
    func goBackRefusal(_ tab: BrowserTab, grant: Grant) -> CallTool.Result? {
        guard let destination = tab.page.backForwardList.backList.last?.url else {
            return failure("There is no page to go back to.")
        }
        guard SitePermissions.origin(for: destination) == grant.origin else {
            return failure("The previous page belongs to another website. Ask the user to open and share it.", code: .accessDenied)
        }
        return nil
    }
}
