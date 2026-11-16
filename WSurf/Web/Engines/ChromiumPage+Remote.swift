// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CCef
import CefKit
import Foundation
import WebKit

// D4 (out-of-process Chromium), phase 2, PR D4-8: a `ChromiumPage` whose browser lives in the Chromium service. The page stays the
// NSView every caller holds. Its `remote` (`ChromiumRemoteBrowser`) is the browser: setters become messages, the synchronous reads
// read what the service pushed, and the service's events become the same calls CEF's callbacks make in process (`willNavigate`,
// `didStartLoad`, `didFinishLoad`, ...). Nothing here waits on the service. Frames (D4-9 hosts them), input and the features of
// phases 3-5 are not here.

extension ChromiumPage {
    /// Whether this page runs in the service. A page that has its remote does. A page that has not asks the process's latch, which
    /// the first Chromium start of the process decided (`ChromiumOOP`): so a process never has pages of both kinds.
    var runsRemotely: Bool {
        remote != nil || ChromiumOOP.resolveMode() == .outOfProcess
    }

    /// `viewDidMoveToWindow` of a page that runs in the service: the browser is asked for, with no wait for it and no need of a
    /// window. True when the page runs there (and nothing in process may follow).
    func materializeRemoteOnAttach() -> Bool {
        guard runsRemotely else { return false }
        if window != nil, remote == nil, !awaitsPopup, !closing, !isClosed {
            do {
                try materializeRemote()
            } catch {
                owner?.onNavigationFailed?(navigation, error)
            }
        }
        // The window brings a scale and a screen, and the page may be shown or hidden now.
        observeScreenChanges()
        updateRemoteGeometry()
        updateRemoteVisibility()
        for waiter in attachmentWaiters {
            waiter.resume()
        }
        attachmentWaiters.removeAll()
        return true
    }

    /// Asks the service for this page's browser. Nothing waits: `preparation` makes it (the context, then the browser, then the
    /// DevTools session), and every command sent before it exists is held in order and goes out right after it is made. A page whose
    /// browser could not be made lets go of it, so that the next load asks again.
    func materializeRemote() throws {
        guard !closing, !isClosed else { throw ChromiumError.closed }
        guard remote == nil else { return }
        // A page that runs in the service never reaches CEF in this process (`ChromiumRuntime.ensureInitialized`): `ChromiumOOPPageTests`
        // counts the calls. (A trap in `ensureInitialized` itself would take its own refusal down: the data commands reach it.)
        guard !awaitsPopup else {
            throw ChromiumError.unavailable("Chromium cannot open a pop-up window in this build yet.")
        }
        let browser = ChromiumRemoteBrowser(page: self, connection: remoteConnection)
        remote = browser
        browserID = Int32(truncatingIfNeeded: browser.id)
        try devTools.attach(remote: browser)
        ChromiumRuntime.shared.register(self)
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        attachRemoteFrameLayer(to: browser)
        let hidden = browser.sentHidden
        // A browser made again for a page that is already in its window (after the service ended) is not told by an attach: parked
        // or hidden, and the screen it is on, reach the service as soon as the browser exists.
        observeScreenChanges()
        updateRemoteVisibility()
        preparation = Task { [weak self, weak browser] in
            guard let self, let browser else { throw ChromiumError.closed }
            do {
                try await browser.create(context: context, size: size, scale: scale, hidden: hidden)
                guard remote === browser, !closing, !isClosed else { throw ChromiumError.closed }
                try await devTools.prepare(marksNewDocuments: false)
                pageZoom = zoom
            } catch {
                abandonRemoteBrowser(browser)
                throw error
            }
        }
    }

    /// The page lets go of a browser that could not be made or prepared; the service is told to close it if it has it.
    private func abandonRemoteBrowser(_ browser: ChromiumRemoteBrowser) {
        guard remote === browser, !closing, !isClosed else { return }
        // The load that waited for this browser reports the failure (its error page, and the end of its loading): it is not cancelled.
        forgetRemoteBrowser(cancelLoad: false)
        browser.requestClose()
    }

    /// Back to a page with no browser: the next load makes a new one. The address, the history WSurf keeps and the page's owner stay,
    /// and so do the scripts and message handlers WSurf installed (they were registered once, at the tab's setup, and live only in
    /// the DevTools object): the new browser gets them from its own preparation, as the first did.
    private func forgetRemoteBrowser(cancelLoad: Bool = true) {
        remote?.detachFrameLayer()
        remote = nil
        if cancelLoad {
            pendingLoad?.cancel()
            // The cancelled load reports nothing, and nothing else ends this loading when the tab does not reload (it died twice).
            owner?.isLoading = false
        }
        preparation?.cancel()
        preparation = nil
        let scripts = devTools.scripts.map { script in
            var script = script
            script.identifier = nil
            return script
        }
        let handlers = devTools.handlers
        devTools.close()
        devTools = ChromiumDevTools(page: self)
        devTools.scripts = scripts
        devTools.handlers = handlers
        // A new browser starts on about:blank again.
        startupEntry = .inHistory
        initialDocument = true
        hasAppliedInitialSettings = false
        awaitingNativeNavigation = false
    }

    /// The service ended with this page's browser in it (a crash, a kill, its own exit): the browser, and the native history with
    /// it, are gone. A page that was being closed is closed (the dropped connection means every browser closed); any other is left
    /// as after a renderer crash, which the tab handles by loading it again (`recoverAfterLoss`).
    func remoteServiceEnded(_ browser: ChromiumRemoteBrowser) {
        guard remote === browser else { return }
        if closing {
            didClose()
            return
        }
        forgetRemoteBrowser()
        recoverAfterLoss()
    }

    /// `browser.closed`: asked for by this page (its close), or not. A browser that was never made (the service refused the create, or
    /// CEF could not make it) leaves it to the create, which fails and reports why through the load that waits for it. One that was
    /// made and closed under the page is left as after a renderer crash, like a service that ended.
    func remoteBrowserClosed(_ browser: ChromiumRemoteBrowser) {
        guard remote === browser else { return }
        if closing {
            browserDidClose()
            return
        }
        guard browser.isCreated else { return }
        forgetRemoteBrowser()
        recoverAfterLoss()
    }

    // MARK: Recovery (D4-10)

    /// What a page that lost its browser waits for before it loads again.
    enum RemoteRecovery {
        case none
        /// Hidden pages come back when they are shown, not before: a service that died with twenty tabs in it does not start twenty.
        case waitingForActivation
        /// The service keeps dying (or refused the hello): nothing launches it again until the person reloads (`userReload`).
        case waitingForPerson
    }

    /// The page told its tab that its content is gone (`didTerminate`), and the tab reloads the address it committed: at once for a
    /// page that is shown (the load waits in order for the relaunched service's hello, which the connection asked for as the service
    /// ended), and not yet for a hidden one: that reload is held (`holdsForRecovery`). In a crash loop it runs and fails, which is the
    /// crash state the tab shows until the person reloads.
    private func recoverAfterLoss() {
        switch remoteConnection.state {
        case .crashLooping, .failed:
            recovery = .waitingForPerson
        default:
            recovery = remoteVisibility().hidden ? .waitingForActivation : .none
        }
        heldReload = nil
        isRecovering = true
        didTerminate()
        isRecovering = false
    }

    /// Whether this load is the tab's automatic reload and has to wait (`recovery`). Any other load of the page ends the wait: a
    /// person's reload also gives a crash loop up (`ChromiumRemote.userReload`).
    func holdsForRecovery(_ request: URLRequest) -> Bool {
        guard recovery != .none else { return false }
        if isRecovering {
            // A crash loop lets the tab's own reload run: it fails (the connection refuses the browser) and the tab shows that.
            guard recovery == .waitingForActivation else { return false }
            requestedURL = request.url
            heldReload = request
            return true
        }
        if recovery == .waitingForPerson {
            remoteConnection.userReload()
        }
        recovery = .none
        heldReload = nil
        return false
    }

    /// The page was shown (a window, an unhide: `updateRemoteVisibility`): a hidden page that waited loads what it held. The check
    /// is made at the end of the turn, like the visibility message, because a tab switch hides and shows within one.
    func resumeRecoveryWhenShown() {
        guard recovery == .waitingForActivation, !recoveryCheckPending, !isClosed else { return }
        recoveryCheckPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.resumeRecovery() }
        }
    }

    private func resumeRecovery() {
        recoveryCheckPending = false
        guard recovery == .waitingForActivation, !isClosed, !closing, !remoteVisibility().hidden else { return }
        let request = heldReload
        recovery = .none
        heldReload = nil
        if let request {
            load(request)
        }
    }

    // MARK: Events

    /// An event of this page's browser (the mirror has taken what it carries): the same calls CEF's callbacks make in process.
    func receiveRemote(_ message: CefRemoteMessage) {
        switch message.op {
        case CefRemote.Event.loadingState:
            didChangeLoading(
                message.bool(CefRemote.Key.loading), canGoBack: message.bool(CefRemote.Key.canGoBack),
                canGoForward: message.bool(CefRemote.Key.canGoForward))
        case CefRemote.Event.loadStart:
            didStartLoad()
        case CefRemote.Event.loadEnd:
            didFinishLoad(status: Int(clamping: message.int(CefRemote.Key.status)))
        case CefRemote.Event.loadError:
            didFailLoad(
                code: Int(clamping: message.int(CefRemote.Key.code)), text: message.string(CefRemote.Key.text),
                url: message.string(CefRemote.Key.url))
        case CefRemote.Event.address:
            didChangeURL(URL(string: message.string(CefRemote.Key.url)))
        case CefRemote.Event.title:
            didChangeTitle()
        case CefRemote.Event.progress:
            didChangeProgress(message.double(CefRemote.Key.progress))
        case CefRemote.Event.renderTerminated:
            didTerminate()
        case CefRemote.Event.devToolsMessage, CefRemote.Event.devToolsResult, CefRemote.Event.devToolsEvent,
             CefRemote.Event.devToolsDetached:
            devTools.receiveRemote(message)
        case CefRemote.Event.findResult:
            find.receive(
                identifier: Int(clamping: message.int(CefRemote.Key.identifier)), count: Int(clamping: message.int(CefRemote.Key.count)),
                active: Int(clamping: message.int(CefRemote.Key.active)), isFinal: message.bool(CefRemote.Key.final))
        case CefRemote.Event.historyChanged:
            remoteHistoryChanged()
        case CefRemote.Event.externalScheme:
            remoteExternalScheme(message)
        default:
            // `browser.ready` and the mute are in the mirror and need no call.
            break
        }
    }

    /// The service pushed a new native list: WSurf's own list, and Back and Forward, follow it. This is also what makes Back possible
    /// after a move that reported nothing else (a same-document entry), as `didChangeURL` does in process.
    private func remoteHistoryChanged() {
        guard !closing, !isClosed else { return }
        if !initialDocument, let native = nativeHistory() {
            owner?.canGoBack = nativeCanGoBack()
            owner?.canGoForward = native.current >= 0 && native.current < native.count - 1
        }
        refreshHistory()
    }

    // MARK: The service asks, and tells

    /// `on_before_browse` of the main frame, which the service holds for the answer (a second at most): the same decision as in
    /// process, from what the service knows of the navigation (`ChromiumClient.on_before_browse`).
    func remoteNavigationDecision(_ question: CefRemoteMessage) -> Bool {
        guard !closing, !isClosed, let url = URL(string: question.string(CefRemote.Key.url)) else { return false }
        // A `file:` page is held to its own file or folder in process (`ChromiumFileScope`), by a handler on every request. The
        // service has none yet (phase 4): no `file:` page loads there, rather than one that can read its neighbours.
        guard !url.isFileURL else { return false }
        var request = URLRequest(url: url)
        let method = question.string(CefRemote.Key.method)
        if !method.isEmpty {
            request.httpMethod = method
        }
        if question.bool(CefRemote.Key.hasPostData) || request.httpMethod?.uppercased() != "GET" {
            // Only presence matters to the engine gate: a submitted request is never replayed in another engine. A method other than
            // GET counts as one even when CEF reports no body element (measured: a form's POST reaches `on_before_browse` with none).
            request.httpBody = Data()
        }
        let source = URL(string: question.string(CefRemote.Key.sourceURL))
        let type = ChromiumClient.navigationType(cef_transition_type_t(rawValue: UInt32(truncatingIfNeeded: question.int(CefRemote.Key.transition))))
        let isRedirect = question.bool(CefRemote.Key.isRedirect)
        let sourceFrame = ExternalApp.staysInWebView(url) ? nil : sourceFrame(for: source)
        guard navigationDecision?(request, true, question.bool(CefRemote.Key.userGesture), isRedirect, type, source, sourceFrame) != false
        else { return false }
        guard CefRemote.allowsNavigation(to: url) else { return false }
        willNavigate(request, isRedirect: isRedirect)
        return true
    }

    /// The service cancelled a navigation to a scheme WSurf does not load itself, and says so (rate limited there). The cancel is
    /// done: this only lets WSurf offer the app that handles it (`mailto:`, `tel:`), through the tab's own gate, whose answer
    /// changes nothing. An address that is loaded in the web view anyway is none of this.
    func remoteExternalScheme(_ message: CefRemoteMessage) {
        guard !closing, !isClosed, let url = URL(string: message.string(CefRemote.Key.url)),
              !CefRemote.allowsNavigation(to: url), !ExternalApp.staysInWebView(url) else { return }
        let source = URL(string: message.string(CefRemote.Key.sourceURL))
        _ = navigationDecision?(URLRequest(url: url), message.bool(CefRemote.Key.isMain), message.bool(CefRemote.Key.userGesture), false, .other, source, nil)
    }
}
