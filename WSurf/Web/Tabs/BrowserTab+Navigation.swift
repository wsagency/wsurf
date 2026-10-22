// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import WebKit

extension BrowserTab {
    func stopLoading() {
        pendingNavigationTask?.cancel()
        page.stopLoading()
        stoppedNavigation = true
        isLoading = false
    }

    func noteNavigationStarted() {
        stoppedNavigation = false
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
        let previous = urlString
        urlString = url.absoluteString
        if liveView.map({ $0.engine != desired }) == true || retirement != nil || engineSwitchTask != nil {
            lastRequestedNavigation = nil
            pendingNavigationTask = Task { [weak self] in
                guard let self else { return nil }
                if liveView.map({ $0.engine != desired }) == true
                    && (hasEditedForm || isAgentWorking || isPlayingAudio || isSharingScreen
                        || !permissions.live.isEmpty || hasActiveDownload?() == true) {
                    guard await ConfirmAlert.destructive(
                        "Switch rendering engine?",
                        detail: "This reloads the website and may end active work, media, or downloads.",
                        verb: "Switch Engine"
                    ) else {
                        if !Task.isCancelled {
                            urlString = previous
                        }
                        return nil
                    }
                }
                guard !Task.isCancelled, await replaceEngine(with: desired), !Task.isCancelled else { return nil }
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

    func loadDirect(_ url: URL) -> PageNavigation? {
        discardDeferredSession()
        autofillSave.clear()
        stopUncommittedStartPage()
        permitSystemPage(url)
        if url.isFileURL {
            return page.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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
