// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XPC

// D4 (out-of-process Chromium), phase 2: the vocabulary between WSurf and the Chromium service
// (`WSurf.app/Contents/XPCServices/WSurf Chromium.xpc`). Both sides compile this file: WSurf through CefKit, the service as a
// CefKit client. Messages are libxpc dictionaries. Every message has an `op`; messages about one browser carry its `bid`,
// which WSurf assigns. WSurf never waits on the service: it sends, and the service answers with events on the same
// connection, in the order it produced them.
//
// This file holds the phase-2 operations only. Input, IME, accessibility and the context menu belong to phases 3 and 5 and
// are added when those phases land; a service that gets an op it does not know ignores it.

public enum CefRemote {
    /// Bumped when either side changes a message in a way the other must know about. `hello` carries it; a mismatch fails the
    /// hello (``CefRemoteMessage/checkProtocolVersion()``), so two builds that disagree never half-work.
    public static let protocolVersion: Int64 = 1
    /// The service's bundle identifier is the app's plus this suffix, so a staged build's suffix carries over.
    public static let serviceSuffix = ".chromium"
    /// CDP ids at or above this are the service's own commands (the history check); never forwarded to WSurf.
    public static let serviceCommandBase: Int64 = 1_900_000_000

    public enum Key {
        public static let op = "op"
        public static let browser = "bid"
        public static let context = "cid"
        /// `hello`: the sender's ``CefRemote/protocolVersion``. A reply to `hello` carries the service's own.
        public static let protocolVersion = "pv"
        public static let url = "url"
        public static let width = "w"
        public static let height = "h"
        public static let scale = "scale"
        public static let screenX = "sx"
        public static let screenY = "sy"
        public static let screenWidth = "sw"
        public static let screenHeight = "sh"
        public static let originX = "ox"
        public static let originY = "oy"
        public static let hidden = "hidden"
        public static let parked = "parked"
        public static let flag = "flag"
        public static let value = "value"
        public static let text = "text"
        public static let data = "data"
        public static let method = "method"
        /// A request's id (the reply or event that answers it repeats it), or a CDP command's id.
        public static let identifier = "id"
        public static let success = "ok"
        public static let error = "error"
        public static let path = "path"
        public static let cachePath = "cache"
        public static let rootPath = "root"
        public static let logFile = "log"
        public static let logSeverity = "severity"
        public static let switches = "switches"
        public static let linger = "linger"
        public static let frameRate = "fps"
        /// A reply to `hello`: how long CEF took to start, in milliseconds.
        public static let startMs = "startms"
        public static let surface = "surface"
        public static let javaScript = "js"
        public static let pid = "pid"
        public static let loading = "loading"
        public static let canGoBack = "back"
        public static let canGoForward = "forward"
        public static let muted = "muted"
        public static let isMain = "main"
        public static let isRedirect = "redirect"
        public static let userGesture = "gesture"
        public static let status = "status"
        public static let code = "code"
        public static let title = "title"
        public static let progress = "progress"
        /// The native history: entry count, current index, first entry's URL. Sent with the state events.
        public static let historyCount = "hcount"
        public static let historyIndex = "hindex"
        public static let historyFirst = "hfirst"
        /// `historyChanged`: the whole native list, an array of ``CefRemote/HistoryEntry`` dictionaries.
        public static let entries = "entries"
        /// One history entry: its id, committed URL, title, whether it was made by a POST, and whether it is the current one.
        public static let entryID = "eid"
        public static let hasPostData = "post"
        public static let isCurrent = "current"
        /// `collapseHistory`: the entry to keep, and the list the caller expects the service to hold (ids, in order).
        public static let keep = "keep"
        public static let expected = "expected"
        /// SSL status of the visible entry: URL, secure connection, certificate status, content status.
        public static let securityURL = "surl"
        public static let secureConnection = "ssecure"
        public static let certStatus = "scert"
        public static let contentStatus = "scontent"
        public static let count = "count"
        public static let active = "active"
        public static let final = "final"
        public static let forward = "fwd"
        public static let matchCase = "case"
        public static let findNext = "next"
        public static let outcome = "outcome"
        public static let stats = "stats"
    }

    /// Messages from WSurf to the service.
    public enum Op {
        /// First message on the control connection: configuration and protocol version. Has a reply.
        public static let hello = "hello"
        /// The second connection, for input only, says which control connection it belongs to. (The input messages are phase 3.)
        public static let inputHello = "inputHello"
        /// The frames connection's first message: frames go to its sender.
        public static let framesHello = "framesHello"
        public static let createContext = "context.create"
        public static let createBrowser = "browser.create"
        public static let load = "browser.load"
        public static let reload = "browser.reload"
        public static let goBack = "browser.back"
        public static let goForward = "browser.forward"
        public static let stop = "browser.stop"
        public static let resize = "browser.resize"
        public static let visibility = "browser.visibility"
        public static let zoom = "browser.zoom"
        public static let mute = "browser.mute"
        public static let find = "browser.find"
        public static let stopFinding = "browser.stopFinding"
        public static let close = "browser.close"
        /// "Collapse the history to one entry if, at this moment, the native list is exactly the one I expect." Keys: `id`
        /// (the request), `keep`, `expected`. The answer is a ``Event/historyCollapsed`` event.
        public static let collapseHistory = "history.collapse"
        public static let devTools = "devtools.send"
        /// DEBUG: the service ends itself at once, as a crash would. Nothing outside signals it.
        public static let debugAbort = "debug.abort"
        /// DEBUG: the service answers with its live counts. Has a reply.
        public static let debugStats = "debug.stats"
        /// DEBUG: the service exits when it gets the next hello (the crash-loop tests).
        public static let debugExitOnHello = "debug.exitOnHello"
        /// DEBUG: the service asks WSurf a question and reports how that went (`answered` or `timedOut`). Has a reply.
        public static let debugAskHost = "debug.askHost"
    }

    /// Events from the service to WSurf.
    public enum Event {
        public static let browserCreated = "browser.created"
        /// One frame of a browser, its IOSurface as an XPC object, on the frames connection.
        public static let frame = "frame"
        /// A popup widget (a `<select>` list) was shown, moved or hidden; on the frames connection, so it is ordered with the
        /// popup's frames. Keys: `flag` (visible), `x`, `y`, `w`, `h` (view points, top-left origin).
        public static let popup = "popup"
        public static let browserReady = "browser.ready"
        public static let browserClosed = "browser.closed"
        public static let loadingState = "load.state"
        public static let loadStart = "load.start"
        public static let loadEnd = "load.end"
        public static let loadError = "load.error"
        /// The service asks WSurf whether a navigation may go ahead (`askHost`); a missing answer means cancel.
        public static let beforeBrowse = "nav.before"
        public static let address = "display.address"
        public static let title = "display.title"
        public static let progress = "display.progress"
        public static let muteChanged = "display.mute"
        public static let renderTerminated = "render.terminated"
        public static let devToolsMessage = "devtools.msg"
        public static let devToolsResult = "devtools.result"
        public static let devToolsEvent = "devtools.event"
        public static let devToolsDetached = "devtools.detached"
        public static let findResult = "find.result"
        /// The native list after every commit, finish, address change and `pushState`; WSurf keeps the last one as its cache.
        public static let historyChanged = "history.changed"
        /// The answer to ``Op/collapseHistory``: keys `id` and `outcome`.
        public static let historyCollapsed = "history.collapsed"
    }

    /// How a ``Op/collapseHistory`` ended.
    public enum CollapseOutcome: Int64, Sendable {
        /// The reset went through, or there was nothing left to drop. See ``CefRemote/collapseVerdict(native:keeping:expected:)``.
        case landed = 0
        /// The native list was not the expected one, or Chromium did not accept the reset. Nothing changed; a retry may work.
        case refused = 1
        /// The list has grown past what the caller expected. Nothing changed, nothing to retry.
        case skipped = 2
    }

    /// One entry of the native history, as ``Event/historyChanged`` carries it.
    public struct HistoryEntry: Equatable, Sendable {
        public var id: Int64
        public var url: String
        public var title: String
        public var hasPostData: Bool
        public var isCurrent: Bool

        public init(id: Int64, url: String, title: String, hasPostData: Bool = false, isCurrent: Bool = false) {
            self.id = id
            self.url = url
            self.title = title
            self.hasPostData = hasPostData
            self.isCurrent = isCurrent
        }
    }

    /// What the service does with a ``Op/collapseHistory`` when it has read its native list on its UI thread. `nil` means the
    /// list is exactly the expected one and the entry to keep is current: send `Page.resetNavigationHistory` in this same
    /// turn and answer ``CollapseOutcome/landed`` when Chromium accepts it. Anything else is the answer to send instead. The
    /// outcomes are the ones `ChromiumPage.startupResetBlocker` gives today, with the startup page and the committed entry
    /// as `expected` and `keeping`.
    ///
    /// - `landed`: none of the expected entries other than the kept one is left, so there is nothing to drop. That includes
    ///   a list that has moved on since (a later navigation, or the startup page already replaced).
    /// - `skipped`: the list begins with the expected one and goes on, so a reset would drop entries the caller never saw.
    /// - `refused`: anything else (an empty list, a list that is not the expected one, or a kept entry that is not current).
    ///   The caller may retry: the list can be mid-update.
    public static func collapseVerdict(native: [HistoryEntry], keeping: Int64, expected: [Int64]) -> CollapseOutcome? {
        let ids = native.map(\.id)
        guard !ids.isEmpty, expected.contains(keeping) else { return .refused }
        if !expected.contains(where: { $0 != keeping && ids.contains($0) }) {
            return .landed
        }
        if ids.count > expected.count, ids.starts(with: expected) {
            return .skipped
        }
        let keepingIsCurrent = native.first(where: \.isCurrent)?.id == keeping
        return ids == expected && keepingIsCurrent ? nil : .refused
    }

    /// The verdict on a `hello`'s protocol version.
    public enum VersionCheck: Equatable, Sendable {
        case compatible
        /// `theirs` is 0 when the hello carried no version at all.
        case mismatch(theirs: Int64)
    }
}

/// A libxpc dictionary with typed accessors. Reads of a missing key give the type's empty value.
public struct CefRemoteMessage: @unchecked Sendable {
    public let object: xpc_object_t

    public init(_ op: String, browser: Int64? = nil) {
        object = xpc_dictionary_create(nil, nil, 0)
        set(CefRemote.Key.op, op)
        if let browser {
            set(CefRemote.Key.browser, browser)
        }
    }

    /// A reply to `request`, which must have been sent with a reply handler.
    public init?(replyTo request: CefRemoteMessage) {
        guard let reply = xpc_dictionary_create_reply(request.object) else { return nil }
        object = reply
    }

    public init?(wrapping object: xpc_object_t) {
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else { return nil }
        self.object = object
    }

    public var op: String { string(CefRemote.Key.op) }
    public var browser: Int64 { int(CefRemote.Key.browser) }

    public func set(_ key: String, _ value: String) {
        xpc_dictionary_set_string(object, key, value)
    }

    public func set(_ key: String, _ value: Int64) {
        xpc_dictionary_set_int64(object, key, value)
    }

    public func set(_ key: String, _ value: Int) {
        xpc_dictionary_set_int64(object, key, Int64(value))
    }

    public func set(_ key: String, _ value: Double) {
        xpc_dictionary_set_double(object, key, value)
    }

    public func set(_ key: String, _ value: Bool) {
        xpc_dictionary_set_bool(object, key, value)
    }

    public func set(_ key: String, bytes: UnsafeRawPointer?, count: Int) {
        if let bytes, count > 0 {
            xpc_dictionary_set_data(object, key, bytes, count)
        } else {
            var zero: UInt8 = 0
            withUnsafeBytes(of: &zero) { xpc_dictionary_set_data(object, key, $0.baseAddress!, 0) }
        }
    }

    public func set(_ key: String, data: Data) {
        data.withUnsafeBytes { set(key, bytes: $0.baseAddress, count: $0.count) }
    }

    public func set(_ key: String, doubles: [Double]) {
        let array = xpc_array_create(nil, 0)
        for value in doubles {
            xpc_array_append_value(array, xpc_double_create(value))
        }
        xpc_dictionary_set_value(object, key, array)
    }

    public func set(_ key: String, int64s: [Int64]) {
        let array = xpc_array_create(nil, 0)
        for value in int64s {
            xpc_array_append_value(array, xpc_int64_create(value))
        }
        xpc_dictionary_set_value(object, key, array)
    }

    public func set(_ key: String, strings: [String: String?]) {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        for (name, value) in strings {
            xpc_dictionary_set_string(dictionary, name, value ?? "")
        }
        xpc_dictionary_set_value(object, key, dictionary)
    }

    public func set(_ key: String, messages: [CefRemoteMessage]) {
        let array = xpc_array_create(nil, 0)
        for message in messages {
            xpc_array_append_value(array, message.object)
        }
        xpc_dictionary_set_value(object, key, array)
    }

    public func string(_ key: String) -> String {
        xpc_dictionary_get_string(object, key).map { String(cString: $0) } ?? ""
    }

    public func has(_ key: String) -> Bool {
        xpc_dictionary_get_value(object, key) != nil
    }

    public func int(_ key: String) -> Int64 {
        xpc_dictionary_get_int64(object, key)
    }

    public func double(_ key: String) -> Double {
        // libxpc answers NaN for a missing key; the rule here is the type's empty value.
        has(key) ? xpc_dictionary_get_double(object, key) : 0
    }

    public func bool(_ key: String) -> Bool {
        xpc_dictionary_get_bool(object, key)
    }

    /// The bytes of a data value, valid while this message is alive. Empty when absent.
    public func withBytes<T>(_ key: String, _ body: (UnsafeRawPointer?, Int) throws -> T) rethrows -> T {
        var length = 0
        let pointer = xpc_dictionary_get_data(object, key, &length)
        return try body(pointer, pointer == nil ? 0 : length)
    }

    public func data(_ key: String) -> Data {
        withBytes(key) { pointer, count in
            guard let pointer, count > 0 else { return Data() }
            return Data(bytes: pointer, count: count)
        }
    }

    public func doubles(_ key: String) -> [Double] {
        guard let array = xpc_dictionary_get_value(object, key), xpc_get_type(array) == XPC_TYPE_ARRAY else { return [] }
        return (0..<xpc_array_get_count(array)).map { xpc_array_get_double(array, $0) }
    }

    public func int64s(_ key: String) -> [Int64] {
        guard let array = xpc_dictionary_get_value(object, key), xpc_get_type(array) == XPC_TYPE_ARRAY else { return [] }
        return (0..<xpc_array_get_count(array)).map { xpc_array_get_int64(array, $0) }
    }

    public func strings(_ key: String) -> [String: String] {
        guard let dictionary = xpc_dictionary_get_value(object, key), xpc_get_type(dictionary) == XPC_TYPE_DICTIONARY else {
            return [:]
        }
        var result: [String: String] = [:]
        xpc_dictionary_apply(dictionary) { name, value in
            if xpc_get_type(value) == XPC_TYPE_STRING, let characters = xpc_string_get_string_ptr(value) {
                result[String(cString: name)] = String(cString: characters)
            }
            return true
        }
        return result
    }

    public func messages(_ key: String) -> [CefRemoteMessage] {
        guard let array = xpc_dictionary_get_value(object, key), xpc_get_type(array) == XPC_TYPE_ARRAY else { return [] }
        return (0..<xpc_array_get_count(array)).compactMap { CefRemoteMessage(wrapping: xpc_array_get_value(array, $0)) }
    }
}

// MARK: Hello and the version check

extension CefRemoteMessage {
    /// The first message on the control connection. `linger` is how many seconds the service stays up with no browser.
    public static func hello(protocolVersion: Int64 = CefRemote.protocolVersion, linger: Double? = nil) -> CefRemoteMessage {
        let message = CefRemoteMessage(CefRemote.Op.hello)
        message.set(CefRemote.Key.protocolVersion, protocolVersion)
        if let linger {
            message.set(CefRemote.Key.linger, linger)
        }
        return message
    }

    /// Whether this hello speaks the protocol this build speaks. A hello with no version counts as a mismatch.
    public func checkProtocolVersion() -> CefRemote.VersionCheck {
        let theirs = int(CefRemote.Key.protocolVersion)
        return theirs == CefRemote.protocolVersion ? .compatible : .mismatch(theirs: theirs)
    }

    /// Fills a reply to a hello that was refused: not ok, our version, and a sentence the tab's error can show.
    public func setRefusal(_ check: CefRemote.VersionCheck) {
        set(CefRemote.Key.success, false)
        set(CefRemote.Key.protocolVersion, CefRemote.protocolVersion)
        if case let .mismatch(theirs) = check {
            set(CefRemote.Key.error, "Chromium service speaks protocol \(CefRemote.protocolVersion), WSurf speaks \(theirs).")
        }
    }
}

// MARK: History

extension CefRemoteMessage {
    /// The native list, after a change. `browser` is the browser it belongs to.
    public static func historyChanged(browser: Int64, entries: [CefRemote.HistoryEntry]) -> CefRemoteMessage {
        let message = CefRemoteMessage(CefRemote.Event.historyChanged, browser: browser)
        message.set(CefRemote.Key.entries, messages: entries.map { entry in
            let item = CefRemoteMessage("history.entry")
            item.set(CefRemote.Key.entryID, entry.id)
            item.set(CefRemote.Key.url, entry.url)
            item.set(CefRemote.Key.title, entry.title)
            item.set(CefRemote.Key.hasPostData, entry.hasPostData)
            item.set(CefRemote.Key.isCurrent, entry.isCurrent)
            return item
        })
        return message
    }

    /// The entries of a ``CefRemote/Event/historyChanged`` message, in order.
    public var historyEntries: [CefRemote.HistoryEntry] {
        messages(CefRemote.Key.entries).map { item in
            CefRemote.HistoryEntry(
                id: item.int(CefRemote.Key.entryID),
                url: item.string(CefRemote.Key.url),
                title: item.string(CefRemote.Key.title),
                hasPostData: item.bool(CefRemote.Key.hasPostData),
                isCurrent: item.bool(CefRemote.Key.isCurrent)
            )
        }
    }

    /// `collapseHistory(keeping:ifEntriesAre:)`: `request` is the id the answer repeats.
    public static func collapseHistory(browser: Int64, request: Int64, keeping: Int64, ifEntriesAre expected: [Int64]) -> CefRemoteMessage {
        let message = CefRemoteMessage(CefRemote.Op.collapseHistory, browser: browser)
        message.set(CefRemote.Key.identifier, request)
        message.set(CefRemote.Key.keep, keeping)
        message.set(CefRemote.Key.expected, int64s: expected)
        return message
    }

    /// The entry a ``CefRemote/Op/collapseHistory`` asks to keep.
    public var collapseKeep: Int64 { int(CefRemote.Key.keep) }
    /// The ids a ``CefRemote/Op/collapseHistory`` expects the native list to hold, in order.
    public var collapseExpected: [Int64] { int64s(CefRemote.Key.expected) }

    /// The answer to a collapse request.
    public static func historyCollapsed(browser: Int64, request: Int64, outcome: CefRemote.CollapseOutcome) -> CefRemoteMessage {
        let message = CefRemoteMessage(CefRemote.Event.historyCollapsed, browser: browser)
        message.set(CefRemote.Key.identifier, request)
        message.set(CefRemote.Key.outcome, outcome.rawValue)
        return message
    }

    /// The outcome a ``CefRemote/Event/historyCollapsed`` carries; nil for a value this build does not know.
    public var collapseOutcome: CefRemote.CollapseOutcome? {
        CefRemote.CollapseOutcome(rawValue: int(CefRemote.Key.outcome))
    }
}
