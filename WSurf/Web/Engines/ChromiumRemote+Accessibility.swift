// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CefKit
import Foundation
import os
@preconcurrency import XPC

// D4-40 (out-of-process Chromium, phase 5): the accessibility transport, WSurf's side. No mirror yet (D4-41): the updates are decoded,
// counted and handed to the browser that owns them.
//
// Chromium's accessibility tree is built only while something wants it (`CefRemoteAccessibilityPolicy`, plan Q12): while VoiceOver
// runs, or from the first accessibility query on a page's view by any client until 60 s after the last one. Its updates are several
// MB of JSON on a page's first one, so they travel on a fourth connection (`axHello`) that delivers on a queue of its own and is
// decoded there: on the control connection they would be decoded on WSurf's main thread, and K1 and K2 would regress. Only the
// parsed update reaches the main thread.

/// One of the service's accessibility updates, parsed off the main thread. The parsed JSON is immutable Foundation values (what
/// `JSONSerialization` makes), which is why it may cross threads.
nonisolated struct ChromiumAccessibilityUpdate: @unchecked Sendable {
    nonisolated enum Kind: Sendable {
        /// CEF's tree update: `{"ax_tree_id", "updates": [{"root_id", "nodes", "node_id_to_clear", "has_tree_data", "tree_data"}]}`.
        case tree
        /// CEF's location changes: `[{"ax_tree_id", "id", "new_location"}]`.
        case location
    }

    let browser: Int64
    let kind: Kind
    let json: Any
    let byteCount: Int
    /// Tree updates: the tree it belongs to, the nodes it carries, and the root it names (when it names one).
    let treeID: String
    let nodeCount: Int
    let rootID: Int?

    /// Nil for a message that is not an update or does not parse (counted by the decoder).
    init?(_ message: CefRemoteMessage) {
        let kind: Kind
        switch message.op {
        case CefRemote.Event.accessibilityTree:
            kind = .tree
        case CefRemote.Event.accessibilityLocation:
            kind = .location
        default:
            return nil
        }
        let data = message.data(CefRemote.Key.data)
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
        self.browser = message.browser
        self.kind = kind
        self.json = json
        self.byteCount = data.count
        self.treeID = treeID
        self.nodeCount = nodeCount
        self.rootID = rootID
    }
}

/// Decodes the accessibility connection's messages on its own serial queue. Nothing here touches the main thread.
nonisolated final class ChromiumAccessibilityDecoder: Sendable {
    nonisolated struct Statistics: Equatable, Sendable {
        var decoded = 0
        var undecodable = 0
        var bytes = 0
        /// The longest single decode, in milliseconds.
        var longestMs = 0.0
        #if DEBUG
        /// Where the decodes ran (DEBUG: the proof that none ran on the main thread).
        var decodedOnMain = 0
        var decodedOffMain = 0
        #endif
    }

    let queue = DispatchQueue(label: "io.wsagency.wsurf.chromium-accessibility", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: Statistics())

    var statistics: Statistics {
        state.withLock { $0 }
    }

    /// Runs on `queue`: parses the message and hands the update to `deliver`, which crosses to the main thread.
    func decode(_ incoming: ChromiumRemote.Incoming, deliver: @Sendable (ChromiumAccessibilityUpdate) -> Void) {
        guard case let .message(message) = incoming else { return }
        let started = ContinuousClock.now
        let update = ChromiumAccessibilityUpdate(message)
        let took = started.duration(to: .now)
        let milliseconds = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
        state.withLock { state in
            guard let update else {
                state.undecodable += 1
                return
            }
            state.decoded += 1
            state.bytes += update.byteCount
            state.longestMs = max(state.longestMs, milliseconds)
            #if DEBUG
            if Thread.isMainThread {
                state.decodedOnMain += 1
            } else {
                state.decodedOffMain += 1
            }
            #endif
        }
        if let update {
            deliver(update)
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
        }
    }

    func setWantsTree(_ wants: Bool) {
        wantsTree = wants
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

/// What a browser keeps of the transport: counts, the latest tree update, and where D4-41's mirror takes the updates.
@MainActor
final class ChromiumBrowserAccessibility {
    private(set) var treeUpdates = 0
    private(set) var locationUpdates = 0
    /// The nodes the tree updates carried, and the biggest of them in bytes (the first one of a page is the biggest).
    private(set) var nodesReceived = 0
    private(set) var largestTreeBytes = 0
    private(set) var latestTree: ChromiumAccessibilityUpdate?
    /// What the service was last told (`ax.enable`).
    var sentOn = false
    private(set) var enableMessagesSent = 0
    /// The mirror of D4-41. Not set yet.
    var onUpdate: ((ChromiumAccessibilityUpdate) -> Void)?

    func receive(_ update: ChromiumAccessibilityUpdate) {
        switch update.kind {
        case .tree:
            treeUpdates += 1
            nodesReceived += update.nodeCount
            largestTreeBytes = max(largestTreeBytes, update.byteCount)
            latestTree = update
        case .location:
            locationUpdates += 1
        }
        onUpdate?(update)
    }

    func countEnableMessage() {
        enableMessagesSent += 1
    }
}

extension ChromiumRemote {
    // MARK: The connection

    /// Opens the accessibility connection and says hello on it, once the control hello was answered `ok`. The tree is turned on
    /// only after the service has accepted this hello (`accessibilityHelloAnswered`).
    private func openAccessibility() {
        guard accessibility.connection == nil else { return }
        let epoch = accessibility.opened()
        let connection = Self.makeAccessibilityConnection(serviceName: serviceName, decoder: accessibility.decoder) { [weak self] update in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.receiveAccessibility(update, epoch: epoch) } }
        }
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
        serviceName: String, decoder: ChromiumAccessibilityDecoder, deliver: @escaping @Sendable (ChromiumAccessibilityUpdate) -> Void
    ) -> xpc_connection_t {
        let connection = xpc_connection_create(serviceName, decoder.queue)
        xpc_connection_set_event_handler(connection) { event in
            decoder.decode(Incoming(event), deliver: deliver)
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
        accessibility.browsers.removeAll()
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
    func accessibilityBrowserCreated(_ id: Int64) {
        accessibility.browsers[id] = ChromiumBrowserAccessibility()
        watchVoiceOver()
        syncAccessibility()
    }

    func accessibilityBrowserClosed(_ id: Int64) {
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
        accessibility.policy.noteQuery(at: clock())
        reevaluateAccessibility()
    }

    private func watchVoiceOver() {
        guard accessibility.voiceOverObservation == nil else { return }
        accessibility.policy.setVoiceOver(NSWorkspace.shared.isVoiceOverEnabled)
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
        let on = accessibility.isOn
        for (id, state) in accessibility.browsers where state.sentOn != on {
            state.sentOn = on
            state.countEnableMessage()
            let message = CefRemoteMessage(CefRemote.Op.accessibility, browser: id)
            message.set(CefRemote.Key.flag, on)
            send(message)
        }
    }
}
