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
    public static let protocolVersion: Int64 = 2
    /// The service's bundle identifier is the app's plus this suffix, so a staged build's suffix carries over.
    public static let serviceSuffix = ".chromium"
    /// The `error` of a reply to a hello or to an op that acts on CEF, when the service has begun to leave: nothing is served any more, and
    /// the control connection ends soon. The client asks again once the replacement runs.
    public static let leavingError = "The Chromium service is leaving."
    /// CDP ids at or above this are the service's own commands (the history check); never forwarded to WSurf.
    public static let serviceCommandBase: Int64 = 1_900_000_000

    /// The URL schemes a navigation of any frame may use. WSurf's in-process Chromium client (`ChromiumClient.on_before_browse`)
    /// and the service's `on_before_browse` both apply this one list, so the two engines cannot drift apart.
    public static let allowedNavigationSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "chrome-extension"]

    /// Whether a navigation to `url` may go ahead as far as its scheme is concerned.
    public static func allowsNavigation(to url: URL) -> Bool {
        allowedNavigationSchemes.contains(url.scheme?.lowercased() ?? "")
    }

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
        /// `historyChanged`: the whole native list, an array of ``CefRemote/HistoryEntry`` dictionaries.
        public static let entries = "entries"
        /// One history entry: its id, committed URL, title, whether it was made by a POST, and whether it is the current one. CEF's
        /// navigation entries carry no id (`cef_navigation_entry_t` has url, title, transition, post data, time, status and ssl
        /// only), so the service takes the id from CDP's `Page.getNavigationHistory` (`entries[].id`), read in the same UI-thread
        /// turn as the visitor that confirms the list. An index is not an id: index 0 always exists.
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
        /// `debug.stats` (D4-4a): whether CEF is started in the service, how many request contexts it holds, and how many
        /// cookie-store flushes it has asked of CEF. The browser count is ``count``.
        public static let started = "started"
        public static let contexts = "contexts"
        public static let flushes = "flushes"
        /// `debug.stats`: whether the service runs CEF with the mock keychain (always, until D4-S).
        public static let mockKeychain = "mockKeychain"
        /// The reply to `debug.askHost`: one of ``CefRemote/AskHostAnswer``; ``value`` is how long the ask took, in ms.
        public static let askHostAnswer = "ask"
        /// `debug.stats` (D4-4b): how many browser objects and how many handler sets (a client's holder of CEF handlers) are
        /// alive in the service. Both return to 0 once every browser is closed and CEF has destroyed its clients; the handler
        /// lifetime tests read them.
        public static let browserObjects = "objects"
        public static let handlerSets = "handlers"
        /// `browser.create`, DEBUG only: one of ``CefRemote/DebugCreate``.
        public static let debugCreate = "dbgcreate"
        /// `debug.stats` (D4-4b review F1): how many navigations the service cancelled itself because of their scheme.
        public static let refusedNavigations = "refused"
        /// A `frame` event: when CEF entered its paint callback, in seconds of the mach clock (`mach_absolute_time` in nanoseconds,
        /// divided by 1e9), which the service and WSurf share: the start of the frame's output leg.
        public static let timestamp = "ts"
        /// `debug.stats` with a ``browser``, D4-7: how many surfaces the browser's copy ring (the popup's included) holds right now,
        /// how many frames it sent on the frames connection, how many paint callbacks it had by each path, and how many frames it
        /// dropped (hidden, or no frames connection).
        public static let ringSurfaces = "ring"
        public static let framesSent = "sent"
        public static let acceleratedFrames = "accel"
        public static let cpuFrames = "cpu"
        public static let framesDropped = "dropped"
        /// `debug.stats` with a ``browser``: how many of ``ringSurfaces`` are the popup's; how many frames were written into a
        /// surface that was still in use (no free copy); how many accelerated frames came from a CEF surface with and without a
        /// colour-space tag (the tag is copied to the ring surface).
        public static let popupRingSurfaces = "pring"
        public static let ringOverwrites = "overwrites"
        public static let colourTagged = "cstag"
        /// `debug.stats` with a ``browser``, D4-9: how many different surfaces of the ring were ever written while in use (the
        /// least recently sent one is chosen, so a ring of 3 under load overwrites all 3; the first in allocation order never
        /// touched the third), and how many `browser.visibility` messages the browser received.
        public static let overwrittenSlots = "owslots"
        public static let visibilityMessages = "visn"
        public static let colourUntagged = "csnone"
        /// `nav.before` and `nav.external` (D4-8): the navigation's transition type (CEF's `cef_transition_type_t`, as an integer) and
        /// the address of the page that started it (the request's referrer). `nav.before` also carries ``method`` and
        /// ``hasPostData``: WSurf must never replay a submitted request in another engine.
        public static let transition = "trans"
        public static let sourceURL = "src"
        /// `debug.stats` (D4-8, review F8): how many of the service's own history reads it gave up on because no answer came.
        public static let historyTimeouts = "histtimeouts"
        /// `debug.stats` (D4-8): the `nav.external` events the service's rate limit kept back.
        public static let droppedExternal = "droppedext"
        /// `debug.stats` with a ``browser`` (D4 exit-gate follow-up): how many ring surfaces (IOSurfaces) the browser's presenter has
        /// ever allocated, the popup's included. A live resize allocates a ring for every size it sends.
        public static let slotsMade = "slotsmade"
        /// `debug.stats` with a ``browser`` (D4 frames cache): how many of CEF's surfaces the presenter holds a source texture for right
        /// now (at most four; none while the browser is hidden or parked).
        public static let sourceTextures = "srctex"
        /// `debug.stats` with a ``browser``: how many view frames had to make their source texture (the cache did not hold it).
        public static let sourceTextureMisses = "srcmiss"
        /// `debug.stats` with a ``browser``: how many of ``sourceTextures`` are not of the size and pixel format the cache is for. An
        /// invariant that is always 0: a size or format change empties the cache before its first new entry.
        public static let staleSourceTextures = "srcstale"
    }

    /// What `browser.create` can ask of the service in a build that has the DEBUG ops, to reach creation paths a test could not
    /// reach with a real CEF.
    public enum DebugCreate {
        /// The creation fails as CEF's own refusal would (the same code path), without calling CEF.
        public static let fail = "fail"
        /// CEF is never called and the browser never reaches `on_after_created`: a close before creation, made deterministic.
        public static let hold = "hold"
        /// CEF is asked, and a close is taken at once, before CEF has made the browser: the close then has to wait for
        /// `on_after_created`. A real close can only win that race against the first browser of a fresh disk context.
        public static let closeFirst = "closeFirst"
        /// The browser is made without a shared texture, so CEF paints into memory (`on_paint`): the CPU path of D4-7's frames
        /// (still copied into a ring surface, which needs a Metal device to be made).
        public static let cpuPaint = "cpuPaint"
        /// The browser's frame copy keeps one source texture instead of ``CefRemote/sourceTextureLimit``. Chromium cycles about three
        /// surfaces at one size and a size change empties the cache, so the real cap is not reached by a page; this one is, by any
        /// animated page, and a test can tell a cache that evicts from one that does not.
        public static let smallSourceCache = "smallSourceCache"
    }

    /// How many copies of its frames the service keeps per browser and element (the page, the popup). Three cover the one WSurf
    /// shows, the one the render server may still read, and the one being written. A knob, not a protocol value: the ring is the
    /// service's own, and is freed while the browser is hidden.
    public static let frameRingSize = 3

    /// How many of CEF's surfaces the service keeps a texture for, per browser (the frame copy's cache): Chromium keeps two spare
    /// surfaces besides the ones in flight, and each is about 18 MB at 1300x860 @2x, so the cache must not outgrow them.
    public static let sourceTextureLimit = 4

    /// The reply to a back or forward that native history cannot do at that moment: WSurf makes its own hop (D3b).
    public static let noNativeEntry = "no native entry"

    /// How the service's `askHost` ended (`debug.askHost` reports it). A missing, late or failed answer is `timedOut`: the safe
    /// answer, which cancels.
    public enum AskHostAnswer {
        public static let answered = "answered"
        public static let timedOut = "timedOut"
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
        /// DEBUG: the next ``Key/count`` hellos, whichever service instance gets them, each end the service at once (SIGKILL, before
        /// CEF starts), as a crash would: the crash-loop tests. The count is kept in a marker file under ``Key/rootPath``, which the
        /// hellos must name too, because a relaunched service is a new process. Has a reply.
        public static let debugExitOnHello = "debug.exitOnHello"
        /// DEBUG: the service asks WSurf a question and reports how that went (`answered` or `timedOut`). Has a reply.
        public static let debugAskHost = "debug.askHost"
        /// DEBUG: runs the handler the system's memory-pressure source runs, with ``Key/flag`` as "under pressure". Has a reply
        /// (sent before any exit it causes) that carries ``Key/flushes``.
        public static let debugMemoryPressure = "debug.memoryPressure"
        /// DEBUG: registers a browser that is not one, under ``Key/browser``, so the lifecycle (linger, memory pressure, closing
        /// everything) can be tested before real browsers exist. ``Key/flag`` says whether it answers a close (`browser.close`
        /// or the service's own) by going away; one that does not stays until the service gives up on it.
        public static let debugStubBrowser = "debug.stubBrowser"
        /// DEBUG: answers, begins the service's exit (as the end of the control connection does) and then blocks the main thread
        /// for 15 s, as a hung `cef_shutdown` would. Only the exit's backstop, which runs on another queue, can end the service
        /// sooner. Has a reply (sent before the block).
        public static let debugHangExit = "debug.hangExit"
        /// DEBUG: the next ``Key/count`` history reads of one browser are held back: with no ``Key/value`` they get no answer, as a read
        /// whose renderer went away would (the F8 case: the service must give up on it and go on); with one, they are answered after
        /// that many seconds (a slow read, which a collapse must wait for: F5). Has a reply.
        public static let debugHoldHistory = "debug.holdHistory"
    }

    /// Events from the service to WSurf.
    public enum Event {
        public static let browserCreated = "browser.created"
        /// One frame of a browser, on the frames connection. Keys: ``Key/surface`` (the IOSurface, an XPC object, a copy the service
        /// made: CEF's own surface is never sent), ``Key/flag`` (true for the popup widget's frame) and ``Key/timestamp``.
        public static let frame = "frame"
        /// A popup widget (a `<select>` list) was shown, moved or hidden; on the frames connection, so it is ordered with the
        /// popup's frames. Keys: `flag` (visible) and the popup's rectangle in view points, top-left origin; the rectangle's
        /// keys are `originX`, `originY`, `width` and `height` (doubles).
        public static let popup = "popup"
        public static let browserReady = "browser.ready"
        public static let browserClosed = "browser.closed"
        public static let loadingState = "load.state"
        public static let loadStart = "load.start"
        public static let loadEnd = "load.end"
        public static let loadError = "load.error"
        /// The service asks WSurf whether a main-frame navigation may go ahead (`askHost`, `on_before_browse`). Keys: `bid`, `url`,
        /// `redirect`, `gesture`. The answer's ``Key/value`` is true to let it go ahead; false, no answer, a late or a failed one
        /// cancels it.
        public static let beforeBrowse = "nav.before"
        /// One way (D4-8, review D1): the service cancelled a navigation of a scheme WSurf does not load itself (`mailto:`, `tel:`, an
        /// app's scheme), so that WSurf can still offer the app. Keys: `bid`, `url`, `main`, `gesture`, `src`. Rate limited by the
        /// service (``CefRemoteRateLimit``): a page can trigger it as often as it likes.
        public static let externalScheme = "nav.external"
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
        /// The reset went through, or there was nothing left to drop (so it can be answered without any reset having run). See
        /// ``CefRemote/collapseVerdict(native:keeping:expected:)``.
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
    /// turn and answer ``CollapseOutcome/landed`` when Chromium accepts it. Anything else is the answer to send instead.
    ///
    /// With the startup page and the committed entry as `expected` and `keeping`, this reaches the same end state as
    /// `ChromiumPage.startupResetBlocker` today but is stricter in two cases: a list `[startup, X, Y]` that does not begin
    /// with `expected` is `refused` here (`skipped` there, so a retry or two more, same end state), and `[startup, X]` with
    /// X current is `refused` here (today's check cannot tell X from the committed entry and resets). It also matches
    /// entries by id, not by the first entry's URL.
    ///
    /// - `landed`: none of the expected entries other than the kept one is left, so there is nothing to drop. That includes
    ///   a list that has moved on since (a later navigation, or the startup page already replaced), and a list holding none
    ///   of the expected entries at all. It does not mean this call collapsed anything: a caller must not treat it as proof
    ///   that a reset ran.
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

/// A libxpc dictionary with typed accessors. Reads of a missing or wrong-typed key give the type's empty value, and every
/// number read as a `Double` is finite (NaN and infinities from a peer read as 0). Ranges are the consumer's job: clamp a double
/// to the target type's range, then convert it with `Int32(x.rounded())`; for a peer's integer use `Int32(clamping:)` (an
/// integer API: it does not take a double). Never convert a peer's number with a bare `Int32(_:)`, which traps outside the
/// range. Build a message, then send it; do not mutate it after sending.
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
        // libxpc answers NaN for a missing or non-double value, and a peer can send NaN or an infinity: only finite numbers
        // get through, everything else is the type's empty value.
        Self.finite(xpc_dictionary_get_double(object, key))
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
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
        return (0..<xpc_array_get_count(array)).map { Self.finite(xpc_array_get_double(array, $0)) }
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

    /// Fills a reply to a hello that was refused: not ok, our version, and a sentence the tab's error can show. The sentence
    /// is the service's own: WSurf builds the tab's text from the two versions and never shows a peer's `error` as it is.
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

    /// The outcome a ``CefRemote/Event/historyCollapsed`` carries; nil for a value this build does not know, and for an answer
    /// with no outcome or one that is not an integer (a missing key reads 0, which would otherwise decode as `landed`).
    public var collapseOutcome: CefRemote.CollapseOutcome? {
        guard let value = xpc_dictionary_get_value(object, CefRemote.Key.outcome), xpc_get_type(value) == XPC_TYPE_INT64 else {
            return nil
        }
        return CefRemote.CollapseOutcome(rawValue: int(CefRemote.Key.outcome))
    }
}
