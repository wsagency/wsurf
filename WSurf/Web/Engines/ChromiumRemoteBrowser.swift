// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CefKit
import Foundation
import QuartzCore

// D4 (out-of-process Chromium), phase 2, PR D4-8: one browser in `WSurf Chromium.xpc`, as the page that holds it sees it.
//
// `ChromiumPage` stays the NSView every caller holds. A page that runs in the service has one of these in `remote`: it is the page's
// handle on the browser (what `ChromiumRemote` calls back), the messages the page sends, and the MIRROR of what the service pushes
// with its events (plan §1.5). Every read the page makes that is synchronous in process (the title, the mute, the native history,
// the SSL status of the visible entry) reads the mirror here, and nothing in WSurf waits on the service.

@MainActor
final class ChromiumRemoteBrowser: ChromiumRemoteBrowserHandle {
    /// The visible entry's SSL status as the service last sent it (`ChromiumPage.hasOnlySecureContent` applies the rule to it).
    struct Security: Equatable {
        var url: URL?
        var secureConnection: Bool
        var certStatus: UInt32
        var contentStatus: UInt32
    }

    /// How long a `collapseHistory` waits for its answer. The service parks it while its list is being read, and a read it cannot
    /// finish ends after 2 s there, so this is above that.
    static let collapseTimeout: TimeInterval = 5

    weak var page: ChromiumPage?
    let connection: ChromiumRemote
    private(set) var id: Int64 = 0
    private(set) var isReady = false
    /// The service said this browser is closed, or it ended: nothing is sent to it any more.
    private(set) var isClosed = false
    private var closeRequested = false

    // MARK: The mirror

    /// The visible entry's title. The service sends it with the address, the end of a load and a title change.
    private(set) var title = ""
    private(set) var security: Security?
    private(set) var isMuted = false
    /// The native list as the service last pushed it; nil until the first one.
    private(set) var history: [CefRemote.HistoryEntry]?

    /// The count, the current index and the first address of the native list, the way `ChromiumPage` reads Chromium's own.
    var nativeHistory: (count: Int, current: Int, first: String)? {
        guard let history, let first = history.first else { return nil }
        return (history.count, history.firstIndex(where: \.isCurrent) ?? -1, first.url)
    }

    // MARK: Display (D4-9, `ChromiumPage+Display`)

    /// The layer the frame sink shows this browser's frames in (registered with the sink while the browser lives).
    private(set) var pageLayer: CALayer?
    /// The view over the page that takes its keyboard, pointer and text input (D4-11): made with this browser, gone with it.
    var contentView: ChromiumRemoteContentView?
    /// What the service was last told: its view size in points, the backing scale, the screen's size, and whether the browser is
    /// hidden or parked. A new browser is shown at the size it was created with.
    var sentSize = CGSize.zero
    var sentScale: CGFloat = 0
    var sentScreen = CGSize.zero
    var sentHidden = false
    var sentParked = false
    /// A visibility update is queued for the end of the run-loop turn (`ChromiumPage.updateRemoteVisibility`).
    var visibilityUpdatePending = false
    /// A `browser.resize` is queued for the end of the run-loop turn (`ChromiumPage.updateRemoteGeometry`).
    var geometryUpdatePending = false
    /// The window's `didChangeScreenNotification` observer (`ChromiumPage.observeScreenChanges`).
    var screenObserver: (any NSObjectProtocol)?
    private(set) var resizesSent = 0
    private(set) var visibilityMessagesSent = 0

    func countResize() {
        resizesSent += 1
    }

    func countVisibility() {
        visibilityMessagesSent += 1
    }

    /// Registers the page's frame layer with the sink (main thread): the frames connection's queue sets its `contents`.
    func attachFrameLayer(_ layer: CALayer) {
        detachFrameLayer()
        pageLayer = layer
        connection.sink.register(browser: id, pageLayer: layer)
    }

    /// Takes the layer and its pop-up layer out of the tree. What the browser's frames still in flight say is dropped.
    func stopObservingScreen() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    /// With `keepingPreview` the page's layer stays in the tree with its last frame and is returned: the page shows it until the
    /// replacement browser's first frame (`ChromiumPage.retainedPreview`). Only the pop-up layer goes then.
    @discardableResult
    func detachFrameLayer(keepingPreview: Bool = false) -> CALayer? {
        stopObservingScreen()
        contentView?.removeFromSuperview()
        contentView = nil
        guard let layer = pageLayer else { return nil }
        pageLayer = nil
        connection.sink.unregister(browser: id, keepingPageLayer: keepingPreview)
        return keepingPreview ? layer : nil
    }

    // MARK: Seams and counters (tests)

    /// Replaces the send itself: a test that needs no service reads what the page sent.
    var outgoing: ((CefRemoteMessage) -> Bool)?
    /// Replaces the close request: a test keeps the page closing with no answer, as it is when the service is gone.
    var closeSeam: (() -> Void)?
    #if DEBUG
    /// One of ``CefRemote/DebugCreate``, sent with every `browser.create` (the service honours it only in a debug-ops build): a test
    /// reaches the failed-create path of a real page.
    static var debugCreate: String?
    #endif
    /// Collapse requests sent to the service.
    private(set) var collapsesSent = 0

    private let collapses = CefRemoteRequests<CefRemote.CollapseOutcome>(schedule: cefRemoteTimer(on: .main))

    init(page: ChromiumPage, connection: ChromiumRemote = .shared) {
        self.page = page
        self.connection = connection
        id = connection.makeBrowser(self)
    }

    // MARK: Sending

    /// The browser exists in the service as far as WSurf knows: its `browser.create` was answered. A message the page sends before
    /// that (a mute or a zoom asked for while the context was still being made) waits in `held`, in order, and goes out right after
    /// the create: the service has no browser to give it to before.
    private(set) var isCreated = false
    private var held: [CefRemoteMessage] = []

    /// Queues a message for this browser. False when the browser is gone or nothing is, or will be, running.
    @discardableResult
    func send(_ message: CefRemoteMessage) -> Bool {
        guard !isClosed else { return false }
        guard isCreated else {
            // Only the last size matters to a browser that does not exist yet: the queue does not grow with every resize.
            if message.op == CefRemote.Op.resize {
                held.removeAll { $0.op == CefRemote.Op.resize }
            }
            held.append(message)
            return true
        }
        if let outgoing {
            return outgoing(message)
        }
        return connection.send(message)
    }

    /// The service has the browser: what waited goes out now.
    func markCreated() {
        guard !isCreated, !isClosed else { return }
        isCreated = true
        connection.accessibilityBrowserCreated(id)
        let waiting = held
        held.removeAll()
        for message in waiting {
            send(message)
        }
    }

    @discardableResult
    func send(_ op: String, _ fill: (CefRemoteMessage) -> Void = { _ in }) -> Bool {
        let message = CefRemoteMessage(op, browser: id)
        fill(message)
        return send(message)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        send(CefRemote.Op.mute) { $0.set(CefRemote.Key.flag, muted) }
    }

    /// Queues one DevTools message (the bytes `ChromiumDevTools` built); its answer comes back as an event.
    func sendDevTools(_ data: Data) -> Bool {
        send(CefRemote.Op.devTools) { $0.set(CefRemote.Key.data, data: data) }
    }

    // MARK: Creation and close

    /// Makes the browser in the service: the profile's request context first, then the browser. Both go out in this order on the one
    /// control connection, so a DevTools command sent after this returns finds its browser (the service holds what arrives before
    /// CEF has made it). Throws when the service cannot be reached, refuses, or does not answer.
    func create(context: BrowserProfileContext, size: CGSize, scale: CGFloat, hidden: Bool = false) async throws {
        let cache = context.profile.isPrivate ? nil : ChromiumRuntime.shared.cacheDirectory(profileID: context.profile.id)
        let failure = ChromiumError.unavailable(String(localized: "Chromium could not open this tab."))
        guard await connection.ensureContext(id: context.contextID, cacheDirectory: cache) else { throw failure }
        // A close asked for while the context was being made goes first: the browser is never made (and so cannot be left behind).
        guard !closeRequested, !isClosed else { throw ChromiumError.closed }
        let message = CefRemoteMessage(CefRemote.Op.createBrowser, browser: id)
        message.set(CefRemote.Key.context, context.contextID.uuidString)
        message.set(CefRemote.Key.url, "about:blank")
        message.set(CefRemote.Key.width, Double(max(1, size.width)))
        message.set(CefRemote.Key.height, Double(max(1, size.height)))
        message.set(CefRemote.Key.scale, Double(max(1, scale)))
        if hidden {
            message.set(CefRemote.Key.hidden, true)
        }
        #if DEBUG
        if let flag = Self.debugCreate {
            message.set(CefRemote.Key.debugCreate, flag)
        }
        #endif
        guard case let .value(reply) = await connection.request(message), reply.bool(CefRemote.Key.success) else { throw failure }
        markCreated()
    }

    /// Asks the service to close the browser. The page learns that it is closed from the `browser.closed` event, which
    /// `ChromiumRemote` also gives it when the service could not say it (a timeout, or the connection ending).
    func requestClose() {
        guard !closeRequested else { return }
        closeRequested = true
        if let closeSeam {
            closeSeam()
            return
        }
        connection.beginClose(id) {}
    }

    // MARK: History

    /// "Collapse to `keeping` if the native list is exactly `expected`": `landed`, `refused` or `skipped` (`CefRemote.CollapseOutcome`).
    /// The service checks and resets in one turn of its UI thread. Anything that keeps the answer from coming (the browser or the
    /// service ends, the timeout) is `refused`, which a caller may try again.
    func collapseHistory(keeping: Int64, ifEntriesAre expected: [Int64]) async -> CefRemote.CollapseOutcome {
        guard !isClosed else { return .refused }
        collapsesSent += 1
        return await withCheckedContinuation { (continuation: CheckedContinuation<CefRemote.CollapseOutcome, Never>) in
            let request = collapses.begin(timeout: Self.collapseTimeout) { reply in
                if case let .value(outcome) = reply {
                    continuation.resume(returning: outcome)
                } else {
                    continuation.resume(returning: .refused)
                }
            }
            if !send(CefRemoteMessage.collapseHistory(browser: id, request: request, keeping: keeping, ifEntriesAre: expected)) {
                collapses.reply(request, .refused)
            }
        }
    }

    /// A collapse landed: the native list is the kept entry alone (the service's next `historyChanged` says the same).
    func collapseMirror(keeping id: Int64) {
        guard let history else { return }
        self.history = history.filter { $0.id == id }
    }

    // MARK: ChromiumRemoteBrowserHandle

    func remoteEvent(_ message: CefRemoteMessage) {
        mirror(message)
        switch message.op {
        case CefRemote.Event.historyCollapsed:
            if let outcome = message.collapseOutcome {
                collapses.reply(message.int(CefRemote.Key.identifier), outcome)
            }
        case CefRemote.Event.browserClosed:
            isClosed = true
            connection.accessibilityBrowserClosed(id)
            detachFrameLayer()
            collapses.interruptAll()
            page?.remoteBrowserClosed(self)
        default:
            // A late event of a browser the page let go of (its preparation failed, or the service closed it under the page) is not
            // the page's: ids restart in the page's next DevTools, so a late reply could match a command of the new browser.
            guard let page, page.remote === self else { return }
            page.receiveRemote(message)
        }
    }

    func remoteServiceEnded() {
        let wasClosed = isClosed
        isClosed = true
        // A shown page waits for its replacement with the last frame in its layer; the page decides, and takes the layer.
        let preview = detachFrameLayer(keepingPreview: !wasClosed && page?.keepsPreviewWhenServiceEnds(self) == true)
        collapses.interruptAll()
        guard !wasClosed, let page else { return }
        page.remoteServiceEnded(self, preview: preview)
    }

    func remoteAllowsNavigation(to url: String) -> Bool {
        let question = CefRemoteMessage(CefRemote.Event.beforeBrowse, browser: id)
        question.set(CefRemote.Key.url, url)
        return remoteAllowsNavigation(question: question)
    }

    func remoteAllowsNavigation(question: CefRemoteMessage) -> Bool {
        guard !isClosed, let page, page.remote === self else { return false }
        return page.remoteNavigationDecision(question)
    }

    /// Keeps what the service pushed with an event: the visible entry's title and SSL status, the mute, the native list.
    private func mirror(_ message: CefRemoteMessage) {
        switch message.op {
        case CefRemote.Event.browserReady:
            isReady = true
        case CefRemote.Event.address, CefRemote.Event.loadEnd, CefRemote.Event.title:
            if message.has(CefRemote.Key.title) {
                title = message.string(CefRemote.Key.title)
            }
            if message.has(CefRemote.Key.securityURL) {
                security = Security(
                    url: URL(string: message.string(CefRemote.Key.securityURL)),
                    secureConnection: message.bool(CefRemote.Key.secureConnection),
                    certStatus: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.certStatus)),
                    contentStatus: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.contentStatus)))
            }
        case CefRemote.Event.muteChanged:
            isMuted = message.bool(CefRemote.Key.muted)
        case CefRemote.Event.historyChanged:
            history = message.historyEntries
        default:
            break
        }
    }
}
