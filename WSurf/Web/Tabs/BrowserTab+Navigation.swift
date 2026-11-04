// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import WebKit

extension BrowserTab {
    func stopLoading() {
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

    func reload() {
        let wasStopped = stoppedNavigation
        if wasStopped && page.isLoading && extensionBaseURL == nil
            && URL(string: urlString) != nil {
            restartPage()
            return
        }
        stoppedNavigation = false
        if let url = URL(string: urlString),
           page.backForwardList.currentItem == nil || (wasStopped && url != committedURL) {
            load(url, transition: .reload)
            return
        }
        if page.reload() == nil, extensionBaseURL == nil {
            restartPage()
        }
    }

    /// Recreate an unresponsive page in its selected engine and existing profile.
    func restartPage() {
        guard !isClosed, extensionBaseURL == nil, let url = URL(string: urlString) else { return }
        pendingNavigationTask?.cancel()
        pendingNavigationTask = Task { [weak self] in
            guard let self else { return nil }
            onContentProcessTerminated?()
            guard await replaceEngine(with: engine, force: true), !Task.isCancelled else { return nil }
            return loadDirect(url)
        }
    }

    /// A new tab is still on its way to the start page; two navigations race.
    private func stopUncommittedStartPage() {
        guard committedURL == nil, SystemPages.isStart(page.url) else { return }
        page.stopLoading()
    }

    @discardableResult
    func load(_ url: URL, transition: HistoryStore.Transition = .typed, startedByUser: Bool = true) -> PageNavigation? {
        guard !isClosed else { return nil }
        noteNavigation(to: url, startedByUser: startedByUser)
        pendingNavigationTask?.cancel()
        pendingTransition = transition
        let desired = preferredEngine(for: url)
        urlString = url.absoluteString
        if liveView.map({ $0.engine != desired }) == true || retirement != nil || engineSwitchTask != nil {
            lastRequestedNavigation = nil
            let left = liveView.flatMap { $0.engine != desired ? committedURL : nil }
                .map { (url: $0, state: page.interactionState as? Data) }
            pendingNavigationTask = Task { [weak self] in
                guard let self else { return nil }
                // A new address ends this page's work anyway, so unlike a same-page engine switch it is not confirmed.
                guard !Task.isCancelled, await replaceEngine(with: desired), !Task.isCancelled else { return nil }
                if let left {
                    pageBeforeEngineSwitch = left
                }
                let result = loadDirect(url)
                lastRequestedNavigation = result
                return result
            }
            return nil
        }
        let result = loadDirect(url)
        lastRequestedNavigation = result
        return result
    }

    /// Back from the first page of the engine a load moved this tab to: the page that load left, in its own engine again.
    func goBackAcrossEngines() {
        guard let left = pageBeforeEngineSwitch else { return }
        pendingNavigationTask?.cancel()
        lastRequestedNavigation = nil
        pendingNavigationTask = Task { [weak self] in
            guard let self else { return nil }
            let desired = preferredEngine(for: left.url)
            if liveView.map({ $0.engine != desired }) == true, await !confirmsEngineSwitch() {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            pageBeforeEngineSwitch = nil
            urlString = left.url.absoluteString
            pendingTransition = .backForward
            guard await replaceEngine(with: desired), !Task.isCancelled else { return nil }
            if let state = left.state, BrowserPage.canRestore(state, using: desired) {
                page.interactionState = state
                return nil
            }
            let result = loadDirect(left.url)
            lastRequestedNavigation = result
            return result
        }
    }

    /// Moving to the other engine closes this page, with whatever it holds: the person confirms it first while it holds anything.
    private func confirmsEngineSwitch() async -> Bool {
        guard hasEditedForm || isAgentWorking || isPlayingAudio || isSharingScreen
            || !permissions.live.isEmpty || hasActiveDownload?() == true else { return true }
        return await ConfirmAlert.destructive(
            "Switch rendering engine?",
            detail: "This reloads the website and may end active work, media, or downloads.",
            verb: "Switch Engine"
        )
    }

    func loadDirect(_ url: URL) -> PageNavigation? {
        discardDeferredSession()
        autofillSave.clear()
        stopUncommittedStartPage()
        permitSystemPage(url)
        if url.isFileURL {
            // Typed, dragged, opened from Finder or from Downloads: a downloaded file reads only itself, the person's own file its folder.
            return page.loadFileURL(url, allowingReadAccessTo: FileAccessScope.readAccess(for: url))
        }
        return page.load(URLRequest(url: url))
    }

    func waitForPendingNavigation() async -> PageNavigation? {
        guard let task = pendingNavigationTask else { return lastRequestedNavigation }
        return await task.value
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
