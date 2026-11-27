// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import WebKit

extension BrowserTab {
    func stopLoading() {
        leavingSignIn = nil
        pendingNavigationTask?.cancel()
        page.stopLoading()
        stoppedNavigation = true
        awaitsVisit = false
        isLoading = false
    }

    func noteNavigationStarted() {
        stoppedNavigation = false
        awaitsVisit = true
    }

    func noteNavigationEnded() {
        awaitsVisit = false
    }

    /// `byPerson`: the person's Reload (menu, ⌘R, toolbar, palette). Only that gives a Chromium service that keeps dying another try; an
    /// automatic reload never does (`ChromiumPage.holdsForRecovery`).
    func reload(byPerson: Bool = false) {
        let wasStopped = stoppedNavigation
        if wasStopped && page.isLoading && extensionBaseURL == nil
            && URL(string: urlString) != nil {
            restartPage(byPerson: byPerson)
            return
        }
        stoppedNavigation = false
        if let url = URL(string: urlString),
           page.backForwardList.currentItem == nil || (wasStopped && url != committedURL) {
            load(url, transition: .reload, byPerson: byPerson)
            return
        }
        if page.reload(byPerson: byPerson) == nil, extensionBaseURL == nil {
            restartPage(byPerson: byPerson)
        }
    }

    /// Recreate an unresponsive page in its selected engine and existing profile. `byPerson`: Page ▸ Restart Page, or the person's Reload
    /// that fell back to it (see `load(byPerson:)`).
    func restartPage(byPerson: Bool = false) {
        guard !isClosed, extensionBaseURL == nil, let url = URL(string: urlString) else { return }
        pendingNavigationTask?.cancel()
        pendingNavigationTask = Task { [weak self] in
            guard let self else { return nil }
            onContentProcessTerminated?()
            guard await replaceEngine(with: engine, force: true), !Task.isCancelled else { return nil }
            return loadDirect(url, byPerson: byPerson)
        }
    }

    /// A new tab is still on its way to the start page; two navigations race.
    private func stopUncommittedStartPage() {
        guard committedURL == nil, SystemPages.isStart(page.url) else { return }
        page.stopLoading()
    }

    /// `byPerson` is the explicit statement that a person asked for this load: an address typed or picked (bookmark, history,
    /// favourite, start page), a Reload, a tab the person opened. It is false unless the caller says so: `startedByUser` and
    /// `transition` are not that (agent and MCP loads use their defaults), and an automatic load (the tab's own reload, an error
    /// page, a start page, prewarm) never says it. Only a page in the Chromium service reads it, to end a crash loop
    /// (`ChromiumPage.holdsForRecovery`); a WebKit or in-process page ignores it.
    @discardableResult
    func load(
        _ url: URL, transition: HistoryStore.Transition = .typed, startedByUser: Bool = true, byPerson: Bool = false,
        authorized: (@MainActor () -> Bool)? = nil
    ) -> PageNavigation? {
        guard !isClosed, authorized?() ?? true else { return nil }
        let sourceSignIn = signInEngine
        let deferNavigationState = authorized != nil
        if !deferNavigationState {
            noteNavigation(to: url, startedByUser: startedByUser)
        }
        pendingNavigationTask?.cancel()
        let desired = preferredEngine(for: url, keepingSignIn: !deferNavigationState || !startedByUser)
        if !deferNavigationState {
            prepareNavigation(to: url, engine: desired, transition: transition)
        }
        let handoff = deferNavigationState && startedByUser ? nil : chromiumSignInHandoff(to: url, engine: desired)
        if liveView.map({ $0.engine != desired }) == true || retirement != nil || engineSwitchTask != nil || handoff != nil {
            lastRequestedNavigation = nil
            // A Chromium hop back through restored entries leaves a page that is ahead of the new one: Back must not return there.
            let left = liveView.flatMap { $0.engine != desired && $0.chromium?.hopsBackward != true ? committedURL : nil }
                .map { (url: $0, state: page.savedInteractionState(keepingWebKitSignIn: sourceSignIn == .webKit)) }
            pendingNavigationTask = Task { [weak self] in
                guard let self, !Task.isCancelled, authorized?() ?? true else { return nil }
                // Read before the Chromium page is retired: it may be the profile's only live one. The cookies are in the store
                // before WebKit sends its first request to the provider.
                if let handoff {
                    _ = await SignInCookieHandoff.copy(
                        origins: handoff.origins, context: context, preferring: handoff.page, into: dataStore.httpCookieStore
                    )
                }
                // A new address ends this page's work anyway, so unlike a same-page engine switch it is not confirmed.
                let ready = if let authorized {
                    await switchEngineWhileAuthorized(to: desired, destination: url, authorized: authorized)
                } else {
                    await replaceEngine(with: desired)
                }
                guard ready, !Task.isCancelled, authorized?() ?? true else { return nil }
                if deferNavigationState {
                    noteNavigation(to: url, startedByUser: startedByUser)
                    prepareNavigation(to: url, engine: desired, transition: transition)
                }
                if let left {
                    pageBeforeEngineSwitch = left
                }
                let result = loadDirect(url, byPerson: byPerson, authorized: authorized)
                lastRequestedNavigation = result
                return result
            }
            return nil
        }
        pendingNavigationTask = nil
        if deferNavigationState {
            noteNavigation(to: url, startedByUser: startedByUser)
            prepareNavigation(to: url, engine: desired, transition: transition)
        }
        let result = loadDirect(url, byPerson: byPerson, authorized: authorized)
        lastRequestedNavigation = result
        return result
    }

    private func prepareNavigation(to url: URL, engine: BrowserEngine, transition: HistoryStore.Transition) {
        pendingTransition = transition
        signInChain.note(SitePermissions.webOrigin(for: url), engine: engine, now: signInClock())
        urlString = url.absoluteString
    }

    /// Back from the first page of the engine a load moved this tab to: the page that load left, in its own engine again.
    func goBackAcrossEngines() {
        guard let left = pageBeforeEngineSwitch else { return }
        pendingNavigationTask?.cancel()
        lastRequestedNavigation = nil
        pendingNavigationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return nil }
            noteNavigation(to: left.url, startedByUser: true)
            if let state = left.state, BrowserPage.webKitHistory(in: state)?.keepsSignIn == true {
                resumeFavoriteSignIn(for: left.url)
            }
            let desired = preferredEngine(for: left.url)
            pageBeforeEngineSwitch = nil
            urlString = left.url.absoluteString
            pendingTransition = .backForward
            guard await replaceEngine(with: desired), !Task.isCancelled else { return nil }
            pendingNavigationTask = nil
            let result = restoreDeferredState(left.state, url: left.url, byPerson: false)
            lastRequestedNavigation = result
            return await pendingNavigationTask?.value ?? result
        }
    }

    func loadDirect(_ url: URL, byPerson: Bool = false, authorized: (@MainActor () -> Bool)? = nil) -> PageNavigation? {
        guard authorized?() ?? true else { return nil }
        discardDeferredSession()
        autofillSave.clear()
        stopUncommittedStartPage()
        permitSystemPage(url)
        if url.isFileURL {
            // Typed, dragged, opened from Finder or from Downloads: a downloaded file reads only itself, the person's own file its folder.
            return page.loadFileURL(url, allowingReadAccessTo: FileAccessScope.readAccess(for: url))
        }
        return page.load(URLRequest(url: url), byPerson: byPerson, authorized: authorized)
    }

    func waitForPendingNavigation(cancelWithCaller: Bool = false) async -> PageNavigation? {
        guard let task = pendingNavigationTask else { return lastRequestedNavigation }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            if cancelWithCaller {
                task.cancel()
            }
        }
    }

    func loadHTML(_ html: String, baseURL: URL?) {
        guard !isClosed else { return }
        pendingNavigationTask?.cancel()
        autofillSave.clear()
        discardDeferredSession()
        if retirement != nil || engineSwitchTask != nil {
            pendingNavigationTask = Task { [weak self] in
                guard let self else { return nil }
                if let pending = engineSwitchTask {
                    _ = await pending.value
                }
                await waitForRetirement()
                guard !isClosed, !Task.isCancelled else { return nil }
                stopUncommittedStartPage()
                let result = page.loadHTMLString(html, baseURL: baseURL)
                lastRequestedNavigation = result
                return result
            }
            return
        }
        stopUncommittedStartPage()
        lastRequestedNavigation = page.loadHTMLString(html, baseURL: baseURL)
    }
}
