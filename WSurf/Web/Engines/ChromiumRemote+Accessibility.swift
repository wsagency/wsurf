// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CefKit
import Foundation
import os
@preconcurrency import XPC

// D4-40 (out-of-process Chromium, phase 5): the accessibility transport, WSurf's side. D4-41 puts the mirror on it: the updates are
// decoded, applied to the browser's mirror and counted on the decode queue, and only what describes an update (never the parsed tree)
// reaches the main thread.
//
// Chromium's accessibility tree is built only while something wants it (`CefRemoteAccessibilityPolicy`, plan Q12): while VoiceOver
// runs, or from the first accessibility query on a page's view by any client until 60 s after the last one. Its updates are several
// MB of JSON on a page's first one, so they travel on a fourth connection (`axHello`) that delivers on a queue of its own and is
// decoded there: on the control connection they would be decoded on WSurf's main thread, and K1 and K2 would regress. The parsed
// graph is applied to the mirror (`ChromiumAccessibilityMirror`) and freed on that queue as well.

/// What one of the service's accessibility updates says about itself: its browser, its kind, its size, the tree it belongs to. The
/// parsed JSON is not part of it (it is applied to the browser's mirror on the decode queue and dropped there), so a value that
/// crosses to the main thread frees nothing big.
nonisolated struct ChromiumAccessibilityUpdate: Sendable {
    nonisolated enum Kind: Sendable {
        /// CEF's tree update: `{"ax_tree_id", "updates": [{"root_id", "nodes", "node_id_to_clear", "has_tree_data", "tree_data"}]}`.
        case tree
        /// CEF's location changes: `[{"ax_tree_id", "id", "new_location"}]`.
        case location
    }

    let browser: Int64
    let kind: Kind
    let byteCount: Int
    /// Tree updates: the tree it belongs to, the nodes it carries, and the root it names (when it names one).
    let treeID: String
    let nodeCount: Int
    let rootID: Int?

    /// Nil for a message that is not an update or does not parse (counted by the decoder). `json` is the parsed update, for the
    /// decoder to apply and drop.
    static func parse(_ message: CefRemoteMessage, data: Data) -> (update: ChromiumAccessibilityUpdate, json: Any)? {
        let kind: Kind
        switch message.op {
        case CefRemote.Event.accessibilityTree:
            kind = .tree
        case CefRemote.Event.accessibilityLocation:
            kind = .location
        default:
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var treeID = ""
        var nodeCount = 0
        var rootID: Int?
        if kind == .tree {
            guard let object = json as? [String: Any], let id = object["ax_tree_id"] as? String,
                  let updates = object["updates"] as? [[String: Any]]
            else { return nil }
            treeID = id
            for update in updates {
                nodeCount += (update["nodes"] as? [Any])?.count ?? 0
                rootID = (update["root_id"] as? Int) ?? rootID
            }
        } else if !(json is [Any]) {
            return nil
        }
        let update = ChromiumAccessibilityUpdate(
            browser: message.browser, kind: kind, byteCount: data.count, treeID: treeID, nodeCount: nodeCount, rootID: rootID)
        return (update, json)
    }
}

/// Decodes the accessibility connection's messages on its own serial queue and applies them to the mirror of the browser they belong
/// to. Nothing here touches the main thread.
nonisolated final class ChromiumAccessibilityDecoder: Sendable {
    nonisolated struct Statistics: Equatable, Sendable {
        var decoded = 0
        var undecodable = 0
        /// Updates over `maxUpdateBytes`: dropped unread, because an incremental stream cannot go on after one is missing.
        var oversized = 0
        var bytes = 0
        /// The longest single decode and apply, in milliseconds.
        var longestMs = 0.0
        #if DEBUG
        /// Where the decodes ran (DEBUG: the proof that none ran on the main thread).
        var decodedOnMain = 0
        var decodedOffMain = 0
        #endif
    }

    /// The biggest update taken: a page of a hundred thousand nodes is about 40 MB. A page may not drive WSurf's own memory.
    static let maxUpdateBytes = 48 * 1024 * 1024

    let queue = DispatchQueue(label: "io.wsagency.wsurf.chromium-accessibility", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: Statistics())
    private let mirrors = OSAllocatedUnfairLock(initialState: [Int64: ChromiumAccessibilityMirror]())

    var statistics: Statistics {
        state.withLock { $0 }
    }

    /// The mirror that takes a browser's updates (made with the browser, on the main thread).
    func register(browser: Int64, mirror: ChromiumAccessibilityMirror) {
        mirrors.withLock { $0[browser] = mirror }
    }

    func unregister(browser: Int64) {
        mirrors.withLock { $0[browser] = nil }
    }

    func unregisterAll() {
        mirrors.withLock { $0.removeAll() }
    }

    /// Runs on `queue`: parses the message, applies it to the browser's mirror, and hands what describes it to `deliver`, which
    /// crosses to the main thread. A message over the cap is not parsed; `oversize` hears of it instead.
    func decode(
        _ incoming: ChromiumRemote.Incoming, deliver: @Sendable (ChromiumAccessibilityUpdate) -> Void, oversize: @Sendable (Int64) -> Void = { _ in }
    ) {
        guard case let .message(message) = incoming else { return }
        let started = ContinuousClock.now
        let data = message.data(CefRemote.Key.data)
        if data.count > Self.maxUpdateBytes {
            state.withLock { $0.oversized += 1 }
            oversize(message.browser)
            return
        }
        let parsed = ChromiumAccessibilityUpdate.parse(message, data: data)
        if let parsed {
            mirrors.withLock { $0[parsed.update.browser] }?.apply(parsed.update.kind, json: parsed.json)
        }
        let took = started.duration(to: .now)
        let milliseconds = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
        state.withLock { state in
            guard let parsed else {
                state.undecodable += 1
                return
            }
            state.decoded += 1
            state.bytes += parsed.update.byteCount
            state.longestMs = max(state.longestMs, milliseconds)
            #if DEBUG
            if Thread.isMainThread {
                state.decodedOnMain += 1
            } else {
                state.decodedOffMain += 1
            }
            #endif
        }
        if let parsed {
            deliver(parsed.update)
        }
    }
}

/// What `ChromiumRemote` keeps for the accessibility transport.
@MainActor
final class ChromiumRemoteAccessibility {
    let decoder = ChromiumAccessibilityDecoder()
    var connection: xpc_connection_t?
    /// The service accepted the accessibility hello: only then is the tree turned on (its first update is the whole tree, and the
    /// service refuses to turn it on while no connection can take it).
    private(set) var isAttached = false
    /// Bumped when the connection is opened or dropped: an update a dropped connection delivered late is ignored.
    private(set) var epoch = 0
    /// What the policy wants now, whether or not the service can serve it yet.
    private(set) var wantsTree = false
    var policy = CefRemoteAccessibilityPolicy()
    var voiceOverObservation: NSKeyValueObservation?
    /// Whether VoiceOver runs now (a test replaces it: the real one reads the person's accessibility state).
    var voiceOverSource: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    /// When the last query was noted (clock time): a client asks hundreds of times a second.
    var lastQueryNoted: TimeInterval?
    var cancelGraceTimer: (@Sendable () -> Void)?
    /// The browsers the service has (created, not closed), by id.
    var browsers: [Int64: ChromiumBrowserAccessibility] = [:]
    /// Updates handed to the main thread, and the ones dropped there because their connection or browser was gone.
    private(set) var delivered = 0
    private(set) var droppedUpdates = 0

    func opened() -> Int {
        epoch += 1
        return epoch
    }

    func attached() {
        isAttached = true
    }

    /// The connection is gone, and with it what the service had turned on: nothing is on, and every browser starts from no tree.
    func detached() {
        epoch += 1
        isAttached = false
        connection = nil
        for state in browsers.values {
            state.sentOn = false
            state.emptyMirror(on: decoder.queue)
        }
    }

    func setWantsTree(_ wants: Bool) {
        wantsTree = wants
        if !wants {
            // What a browser was cut off for (an update over the cap) is forgiven when the tree goes off: the next time starts afresh.
            for state in browsers.values {
                state.isSuspended = false
            }
        }
    }

    func countDelivered() {
        delivered += 1
    }

    func countDropped() {
        droppedUpdates += 1
    }

    /// Whether the tree should be on in the service right now.
    var isOn: Bool {
        wantsTree && isAttached
    }
}

/// What a browser keeps of the transport: counts, and the mirror its updates are applied to (D4-41). The mirror is written on the decode
/// queue and read by the content view; this object only counts what the main thread was told.
@MainActor
final class ChromiumBrowserAccessibility {
    let mirror = ChromiumAccessibilityMirror()
    private(set) var treeUpdates = 0
    private(set) var locationUpdates = 0
    /// The nodes the tree updates carried, and the biggest of them in bytes (the first one of a page is the biggest).
    private(set) var nodesReceived = 0
    private(set) var largestTreeBytes = 0
    /// What the service was last told (`ax.enable`).
    var sentOn = false
    /// The page is in front of a person (not hidden, not parked): a tab nobody sees builds no tree.
    var isShown = true
    /// An update over the cap was dropped: this browser's tree stays off until nothing wants the tree any more.
    var isSuspended = false
    private(set) var enableMessagesSent = 0
    /// The tree changed (the content view tells VoiceOver), coalesced to the end of the run-loop turn: a loading page sends dozens.
    var onTreeChanged: (() -> Void)?
    private var notificationPending = false

    func receive(_ update: ChromiumAccessibilityUpdate) {
        switch update.kind {
        case .tree:
            treeUpdates += 1
            nodesReceived += update.nodeCount
            largestTreeBytes = max(largestTreeBytes, update.byteCount)
            guard !notificationPending else { return }
            notificationPending = true
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.notificationPending = false
                    self?.onTreeChanged?()
                }
            }
        case .location:
            locationUpdates += 1
        }
    }

    func countEnableMessage() {
        enableMessagesSent += 1
    }

    /// No tree any more (it was turned off, its connection ended, or the browser closed). Done on the decode queue, behind the updates
    /// it already holds, so that none of them lands in the emptied mirror.
    func emptyMirror(on queue: DispatchQueue) {
        let mirror = mirror
        queue.async { mirror.reset() }
    }

    /// The tree is being turned on: queued before the `ax.enable` goes out, so before any update it brings.
    func acceptMirror(on queue: DispatchQueue) {
        let mirror = mirror
        queue.async { mirror.accept() }
    }
}

extension ChromiumRemote {
    // MARK: The connection

    /// Opens the accessibility connection and says hello on it, once the control hello was answered `ok`. The tree is turned on
    /// only after the service has accepted this hello (`accessibilityHelloAnswered`).
    private func openAccessibility() {
        guard accessibility.connection == nil else { return }
        let epoch = accessibility.opened()
        let connection = Self.makeAccessibilityConnection(
            serviceName: serviceName, decoder: accessibility.decoder,
            deliver: { [weak self] update in
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.receiveAccessibility(update, epoch: epoch) } }
            },
            oversize: { [weak self] browser in
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.suspendAccessibility(browser: browser, epoch: epoch) } }
            })
        accessibility.connection = connection
        // The handler is Sendable and the connection is not: its identity crosses, not the object.
        let identity = ObjectIdentifier(connection)
        xpc_connection_send_message_with_reply(connection, CefRemoteMessage(CefRemote.Op.axHello).object, DispatchQueue.main) { [weak self] answer in
            // An error object (the connection ended) is the control connection's business (`serviceEnded`), as for the hello.
            guard let reply = CefRemoteMessage(wrapping: answer) else { return }
            let accepted = reply.bool(CefRemote.Key.success)
            MainActor.assumeIsolated { self?.accessibilityHelloAnswered(accepted: accepted, connection: identity, epoch: epoch) }
        }
    }

    /// Built outside the main actor on purpose, as the frames connection is: its handler runs on the decode queue.
    nonisolated private static func makeAccessibilityConnection(
        serviceName: String, decoder: ChromiumAccessibilityDecoder, deliver: @escaping @Sendable (ChromiumAccessibilityUpdate) -> Void,
        oversize: @escaping @Sendable (Int64) -> Void
    ) -> xpc_connection_t {
        let connection = xpc_connection_create(serviceName, decoder.queue)
        xpc_connection_set_event_handler(connection) { event in
            decoder.decode(Incoming(event), deliver: deliver, oversize: oversize)
        }
        xpc_connection_activate(connection)
        return connection
    }

    func accessibilityHelloAnswered(accepted: Bool, connection identity: ObjectIdentifier, epoch: Int) {
        guard epoch == accessibility.epoch, let connection = accessibility.connection, ObjectIdentifier(connection) == identity else { return }
        guard accepted else {
            // Not attached whatever the client believes (the side hellos' rule): dropped, and made again after the next hello.
            ChromiumOOP.log.error("\(CefRemote.Op.axHello, privacy: .public) refused by the service: the connection is dropped")
            sideRefusals += 1
            xpc_connection_cancel(connection)
            accessibility.detached()
            return
        }
        accessibility.attached()
        syncAccessibility()
    }

    /// The connection ends with the instance it belonged to (`takeEverythingDown`, which drops the browsers too: nothing is sent).
    func closeAccessibility() {
        if let connection = accessibility.connection {
            xpc_connection_cancel(connection)
        }
        accessibility.detached()
        for state in accessibility.browsers.values {
            state.emptyMirror(on: accessibility.decoder.queue)
        }
        accessibility.browsers.removeAll()
        accessibility.decoder.unregisterAll()
    }

    /// An update over the cap was dropped on the decode queue, and every later incremental update would be applied to a tree that is
    /// missing it: this browser's tree is turned off and emptied (`ChromiumBrowserAccessibility.isSuspended`).
    func suspendAccessibility(browser id: Int64, epoch: Int) {
        guard epoch == accessibility.epoch, let state = accessibility.browsers[id] else { return }
        ChromiumOOP.log.error("browser \(id, privacy: .public): an accessibility update is over the size cap, its tree is turned off")
        state.isSuspended = true
        syncAccessibility()
        state.emptyMirror(on: accessibility.decoder.queue)
    }

    /// An update, on the main thread, from the decode queue: to the browser it belongs to. One from a connection that was dropped
    /// since, or for a browser that is gone, is counted and ignored.
    func receiveAccessibility(_ update: ChromiumAccessibilityUpdate, epoch: Int) {
        guard epoch == accessibility.epoch, let state = accessibility.browsers[update.browser] else {
            accessibility.countDropped()
            return
        }
        accessibility.countDelivered()
        state.receive(update)
    }

    /// The browser exists in the service (`ChromiumRemoteBrowser.markCreated`): it gets the tree at once if one is wanted. The first
    /// one starts the VoiceOver observation.
    func accessibilityBrowserCreated(_ id: Int64, shown: Bool = true) {
        let state = ChromiumBrowserAccessibility()
        state.isShown = shown
        accessibility.browsers[id] = state
        accessibility.decoder.register(browser: id, mirror: state.mirror)
        watchVoiceOver()
        syncAccessibility()
    }

    /// The page was hidden, parked or shown (`ChromiumPage.sendRemoteVisibility`): only a shown page keeps its tree.
    func accessibilityVisibilityChanged(_ id: Int64, shown: Bool) {
        guard let state = accessibility.browsers[id], state.isShown != shown else { return }
        state.isShown = shown
        syncAccessibility()
    }

    func accessibilityBrowserClosed(_ id: Int64) {
        accessibility.decoder.unregister(browser: id)
        accessibility.browsers[id]?.emptyMirror(on: accessibility.decoder.queue)
        accessibility.browsers[id] = nil
    }

    /// What the transport keeps of one browser (nil before it exists in the service, and after it closed).
    func browserAccessibility(_ id: Int64) -> ChromiumBrowserAccessibility? {
        accessibility.browsers[id]
    }

    // MARK: When the tree is on (Q12)

    var hasAccessibilityConnection: Bool {
        accessibility.connection != nil
    }

    /// Whether the tree is on in the service now (wanted, and the connection that takes it is attached).
    var accessibilityIsOn: Bool {
        accessibility.isOn
    }

    /// VoiceOver started or stopped (`NSWorkspace.isVoiceOverEnabled`, observed).
    func voiceOverChanged(_ isOn: Bool) {
        accessibility.policy.setVoiceOver(isOn)
        reevaluateAccessibility()
    }

    /// An accessibility query reached a page's view (any client, not only VoiceOver): the tree is built from now until 60 s after the
    /// last one, unless VoiceOver runs. The content view (D4-41) calls this from its accessibility methods.
    func noteAccessibilityQuery() {
        let now = clock()
        // Clients ask hundreds of times a second: a note soon after the last one, while the tree is on, moves the end of the grace
        // by a tenth of it at most, and is not worth a timer.
        if accessibility.wantsTree, let last = accessibility.lastQueryNoted, now - last < accessibility.policy.graceSeconds / 10 {
            return
        }
        accessibility.lastQueryNoted = now
        accessibility.policy.noteQuery(at: now)
        reevaluateAccessibility()
    }

    private func watchVoiceOver() {
        guard accessibility.voiceOverObservation == nil else { return }
        accessibility.policy.setVoiceOver(accessibility.voiceOverSource())
        // The change may come on any thread: the handler only hops to the main actor.
        accessibility.voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { @Sendable [weak self] _, change in
            let isOn = change.newValue ?? false
            Task { @MainActor [weak self] in self?.voiceOverChanged(isOn) }
        }
        reevaluateAccessibility()
    }

    /// Asks the policy again, and tells every browser when the answer changed; a query's grace is looked at again when it ends.
    func reevaluateAccessibility() {
        accessibility.cancelGraceTimer?()
        accessibility.cancelGraceTimer = nil
        let now = clock()
        if !accessibility.policy.voiceOverIsOn, let left = accessibility.policy.secondsUntilQueryGraceEnds(at: now) {
            accessibility.cancelGraceTimer = cefRemoteTimer(on: .main)(left + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.reevaluateAccessibility() }
            }
        }
        let wants = accessibility.policy.wantsTree(at: now)
        guard wants != accessibility.wantsTree else { return }
        accessibility.setWantsTree(wants)
        syncAccessibility()
    }

    /// Every browser's `ax.enable` follows what is on now: on only while it is wanted and the connection that takes it is attached.
    /// Nothing is sent to a service that is not running (an instance that ended took its trees with it).
    func syncAccessibility() {
        guard isRunning else { return }
        if accessibility.wantsTree, accessibility.connection == nil {
            // Opened only once something wants the tree; the hello's answer syncs again.
            openAccessibility()
            return
        }
        for (id, state) in accessibility.browsers {
            let on = accessibility.isOn && state.isShown && !state.isSuspended
            guard state.sentOn != on else { continue }
            state.sentOn = on
            if on {
                state.acceptMirror(on: accessibility.decoder.queue)
            } else {
                state.emptyMirror(on: accessibility.decoder.queue)
            }
            state.countEnableMessage()
            let message = CefRemoteMessage(CefRemote.Op.accessibility, browser: id)
            message.set(CefRemote.Key.flag, on)
            send(message)
        }
    }
}
