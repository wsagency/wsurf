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
        // A service that is given up is asked for by a person's load, not by a page being attached (a new tab, a move to a window). A
        // hidden or parked page that waits for its activation (`recovery`) is loaded when it is shown, not made a browser by a move
        // between windows or onto the shelf.
        if window != nil, remote == nil, !awaitsPopup, !closing, !isClosed, !remoteConnection.isGivenUp, recovery != .waitingForActivation {
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
        // A browser made again for a page that is already in its window (after the service ended, or a create that failed) is not told
        // by an attach: the screen goes now (held, in order, until the browser is made), and so do parked and hidden. Without it the
        // service's screen is the view's rect until the next resize.
        observeScreenChanges()
        updateRemoteGeometry()
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
    ///
    /// `preview`: the browser's frame layer with its last frame, when the page asked to keep it (`keepsPreviewWhenServiceEnds`). A page
    /// waits for its replacement with that frame on screen (a shown one with its tab loading); the layer is the replacement browser's own as
    /// soon as it is made (`attachRemoteFrameLayer`), so its first frame is the first thing that changes it.
    func remoteServiceEnded(_ browser: ChromiumRemoteBrowser, preview: CALayer? = nil) {
        guard remote === browser else { return }
        if closing {
            didClose()
            return
        }
        if let preview {
            // A browser that died before its first frame leaves the older frame in place (`retainedPreview`).
            dropRetainedPreview()
            retainedPreview = preview
        }
        let before = pendingLoad
        forgetRemoteBrowser()
        recoverAfterLoss()
        // The tab did not load the page again (it died twice within 5 s: "leaving the tab alone"), and the page is not waiting to be
        // shown either: nothing is coming to replace the frame.
        if pendingLoad == before, recovery != .waitingForActivation {
            dropRetainedPreview()
        }
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
        /// The service keeps dying (or refused the hello): nothing launches it again until a person acts (`userReload`).
        case waitingForPerson
    }

    /// The page told its tab that its content is gone (`didTerminate`), and the tab reloads the address it committed: at once for a
    /// page that is shown (the load waits in order for the relaunched service's hello, which the connection asked for as the service
    /// ended), and not yet for a hidden or parked one (the person does not see it: twenty recently visited tabs do not start twenty
    /// pages): that reload is held (`holdsForRecovery`). In a crash loop the reload is held as well, for
    /// shown and hidden pages alike: the tab is blank and not loading (an error document needs a service) until a person acts.
    private func recoverAfterLoss() {
        if remoteConnection.isGivenUp {
            recovery = .waitingForPerson
            dropRetainedPreview()
        } else {
            let visibility = remoteVisibility()
            recovery = visibility.hidden || visibility.parked ? .waitingForActivation : .none
        }
        heldReload = nil
        isRecovering = true
        didTerminate()
        isRecovering = false
    }

    /// Whether this load has to wait (`recovery`, or a service that is given up). `byPerson` is the tab's explicit statement that a
    /// person asked for it (a Reload, an address typed or picked: `BrowserTab.load(byPerson:)`); nothing else says so, and the
    /// default of every load is that no person did (an agent's, the tab's own reload, an error document, a fallback, the start page).
    ///
    /// - A person's load ends a crash loop or a refusal (`ChromiumRemote.userReload`), whatever page it is for, and goes on.
    /// - While the service is given up, any other load is held: it never asks for the service, so nothing automatic ends the loop,
    ///   and nothing fails into the tab's error page (which would load a document, and show an alert for a page with no window).
    /// - A tab's reload of a hidden page waits until the page is shown.
    func holdsForRecovery(_ request: URLRequest, byPerson: Bool = false) -> Bool {
        if byPerson {
            if remoteConnection.isGivenUp {
                remoteConnection.userReload()
            }
            recovery = .none
            heldReload = nil
            return false
        }
        if remoteConnection.isGivenUp {
            // The address stays the one a person's reload loads, and the crash state shows no frame of the page that is not coming.
            dropRetainedPreview()
            requestedURL = request.url
            heldReload = nil
            return true
        }
        guard recovery != .none else { return false }
        if isRecovering {
            guard recovery == .waitingForActivation else { return false }
            requestedURL = request.url
            heldReload = request
            return true
        }
        recovery = .none
        heldReload = nil
        return false
    }

    /// The page was shown (a window, an unhide, a return from the shelf: `updateRemoteVisibility`): a hidden or parked page that waited
    /// loads what it held. The check is made at the end of the turn, like the visibility message, because a tab switch hides and shows
    /// within one.
    func resumeRecoveryWhenShown() {
        guard recovery == .waitingForActivation, !recoveryCheckPending, !isClosed else { return }
        recoveryCheckPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.resumeRecovery() }
        }
    }

    private func resumeRecovery() {
        recoveryCheckPending = false
        let visibility = remoteVisibility()
        guard recovery == .waitingForActivation, !isClosed, !closing, !visibility.hidden, !visibility.parked else { return }
        let request = heldReload
        recovery = .none
        heldReload = nil
        if let request {
            load(request)
        } else {
            // The tab held no reload (it died twice within 5 s, or has no address): nothing is coming to replace the kept frame.
            dropRetainedPreview()
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
        case CefRemote.Event.cursor, CefRemote.Event.tooltip, CefRemote.Event.statusMessage, CefRemote.Event.unhandledKey,
             CefRemote.Event.takeFocus:
            remote?.receiveInput(message)
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
