// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import WebKit

extension BrowserTab {
    @discardableResult
    func retire(_ outgoing: BrowserPage) -> Task<Void, Never> {
        releaseCurrentDevelopment(reason: .engineReplaced)
        onPageRetired?(outgoing)
        retirementGeneration &+= 1
        let generation = retirementGeneration
        retiredView = outgoing
        if liveView === outgoing {
            liveView = nil
        }
        outgoing.stopLoading()
        outgoing.onNavigationStarted = nil
        outgoing.onNavigationCommitted = nil
        outgoing.onNavigationFinished = nil
        outgoing.onMainFrameResponse = nil
        outgoing.onNavigationFailed = nil
        outgoing.onContentProcessTerminated = nil
        outgoing.onHistoryChanged = nil
        outgoing.onLinkHovered = nil
        if let native = outgoing.webKit {
            native.navigationDelegate = nil
            native.uiDelegate = nil
            if let tabView = native as? TabWebView {
                tabView.onZoomChanged = nil
                tabView.onContextDownload = nil
                tabView.onOpenLinkInNewWindow = nil
                tabView.profileContext = nil
                tabView.onPeekLink = nil
                tabView.onSummarizeLink = nil
            }
        }
        outgoing.removeFromSuperview()
        progressObservation = nil
        loadingObservation = nil
        cameraObservation = nil
        microphoneObservation = nil
        displayCaptureObservation = nil
        pageBackgroundObservation = nil
        addressObservation = nil
        titleObservation = nil
        backObservation = nil
        forwardObservation = nil
        fullscreenObservation = nil
        secureContentObservation = nil
        permissions.onRevoke = nil
        permissions.onPolicyChanged = nil
        navigationDelegate = nil
        let task = Task { [weak self] in
            await outgoing.close()
            guard let self, retirementGeneration == generation else { return }
            retirement = nil
            if engineSwitchTask == nil {
                retiredView = nil
                pageGeneration &+= 1
            }
        }
        retirement = task
        return task
    }

    func waitForRetirement() async {
        if let retirement {
            await retirement.value
        }
    }

    func switchEngine(to engine: BrowserEngine) async -> Bool {
        while let pending = engineSwitchTask {
            _ = await pending.value
        }
        guard !isClosed, extensionBaseURL == nil else { return false }
        guard liveView?.engine != engine else { return true }
        let url = URL(string: urlString) ?? liveView?.url
        guard await replaceEngine(with: engine), !Task.isCancelled else { return false }
        if let url, urlString == url.absoluteString {
            lastRequestedNavigation = loadDirect(url)
        }
        return true
    }

    func replaceEngine(with engine: BrowserEngine, force: Bool = false) async -> Bool {
        while let pending = engineSwitchTask {
            _ = await pending.value
        }
        guard !isClosed, !Task.isCancelled else { return false }
        if !force, let liveView, liveView.engine == engine {
            return true
        }
        let task = Task { [weak self] in
            guard let self else { return false }
            defer { engineSwitchTask = nil }
            return await installEngine(engine)
        }
        engineSwitchTask = task
        return await task.value
    }

    private func installEngine(_ engine: BrowserEngine) async -> Bool {
        if let outgoing = liveView {
            await retire(outgoing).value
        } else if let retirement {
            await retirement.value
        }
        guard !isClosed else { return false }
        retiredView = nil
        liveView = nil
        self.engine = engine
        stoppedNavigation = false
        provisionalNavigation = nil
        committedNavigation = nil
        isRestoring = false
        isLoading = false
        progress = 0
        hasPresentedContent = false
        isShowingError = false
        isPlayingAudio = false
        hasVideo = false
        isPictureOut = false
        committedURL = nil
        zoomHost = ""
        clearPageActivity()
        invalidateSessionState()
        processState.finishReload()
        releasePageColorHold()
        permissions.pageChanged(url: nil)
        assistantAccess.pageChanged(url: nil)
        adopt(makePage(engine: engine))
        pageGeneration &+= 1
        return true
    }
}
