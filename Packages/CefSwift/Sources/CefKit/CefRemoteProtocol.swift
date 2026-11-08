import CCef
import Foundation
import XPC

// D4 spike (branch spike/chromium-oop, never merged): the vocabulary between WSurf and the out-of-process Chromium service
// (`WSurf.app/Contents/XPCServices/WSurf Chromium.xpc`). Both sides compile this file: WSurf through CefKit, the service as
// a CefKit client. Messages are libxpc dictionaries. Every message has an `op`; messages about one browser carry its `bid`,
// which WSurf assigns. WSurf never waits on the service: it sends, and the service answers with events on the same
// connection, in the order it produced them.

public enum CefRemote {
    /// Bumped when either side changes a message in a way the other must know about.
    public static let protocolVersion: Int64 = 1
    /// The service's bundle identifier is the app's plus this suffix, so a staged build's suffix carries over.
    public static let serviceSuffix = ".chromium"
    /// CDP ids at or above this are the service's own commands (the startup history check); never forwarded to WSurf.
    public static let serviceCommandBase: Int64 = 1_900_000_000

    public enum Key {
        public static let op = "op"
        public static let browser = "bid"
        public static let context = "cid"
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
        public static let identifier = "id"
        public static let success = "ok"
        public static let error = "error"
        public static let path = "path"
        public static let cachePath = "cache"
        public static let rootPath = "root"
        public static let logFile = "log"
        public static let logSeverity = "severity"
        public static let switches = "switches"
        public static let layerServer = "layerServer"
        public static let layerClient = "layer"
        public static let linger = "linger"
        public static let frameRate = "fps"
        public static let beginFrames = "beginFrames"
        public static let javaScript = "js"
        public static let pid = "pid"
        public static let loading = "loading"
        public static let canGoBack = "back"
        public static let canGoForward = "forward"
        public static let isMain = "main"
        public static let isRedirect = "redirect"
        public static let userGesture = "gesture"
        public static let status = "status"
        public static let code = "code"
        public static let title = "title"
        public static let progress = "progress"
        /// The native history: entry count, current index, first entry's URL.
        public static let historyCount = "hcount"
        public static let historyIndex = "hindex"
        public static let historyFirst = "hfirst"
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
        public static let cursor = "cursor"
        public static let items = "items"
        public static let x = "x"
        public static let y = "y"
        public static let deltaX = "dx"
        public static let deltaY = "dy"
        public static let modifiers = "mods"
        public static let button = "button"
        public static let clickCount = "clicks"
        public static let kind = "kind"
        public static let timestamp = "t"
        public static let keyType = "ktype"
        public static let windowsKeyCode = "wkc"
        public static let nativeKeyCode = "nkc"
        public static let systemKey = "sys"
        public static let character = "ch"
        public static let unmodifiedCharacter = "uch"
        public static let editable = "editable"
        public static let rangeFrom = "from"
        public static let rangeTo = "to"
        public static let replaceFrom = "rfrom"
        public static let replaceTo = "rto"
        public static let rects = "rects"
        public static let outcome = "outcome"
        public static let stats = "stats"
        public static let label = "label"
        public static let enabled = "enabled"
        public static let separator = "sep"
        public static let command = "command"
    }

    /// Messages from WSurf to the service.
    public enum Op {
        /// First message on the control connection: configuration, and the remote-layer server's port. Has a reply.
        public static let hello = "hello"
        /// The second connection, for input only, says which control connection it belongs to.
        public static let inputHello = "inputHello"
        public static let createContext = "context.create"
        public static let createBrowser = "browser.create"
        public static let load = "browser.load"
        public static let reload = "browser.reload"
        public static let goBack = "browser.back"
        public static let goForward = "browser.forward"
        public static let stop = "browser.stop"
        public static let resize = "browser.resize"
        public static let visibility = "browser.visibility"
        public static let focus = "browser.focus"
        public static let zoom = "browser.zoom"
        public static let mute = "browser.mute"
        public static let find = "browser.find"
        public static let stopFinding = "browser.stopFinding"
        public static let close = "browser.close"
        /// "Drop the startup entry if, at this moment, the native history is exactly about:blank and the committed entry."
        public static let collapseStartup = "history.collapseStartup"
        public static let devTools = "devtools.send"
        public static let contextMenuCommand = "contextmenu.command"
        public static let mouse = "input.mouse"
        public static let key = "input.key"
        public static let imeSetComposition = "ime.set"
        public static let imeCommit = "ime.commit"
        public static let imeFinish = "ime.finish"
        public static let imeCancel = "ime.cancel"
        public static let edit = "edit"
        /// Turns CEF's accessibility tree on or off for a browser (windowless: tree-only mode, updates as events).
        public static let accessibility = "ax.enable"
        /// DEBUG: the service ends itself at once, as a crash would (the day 8-9 kill test). Nothing outside signals it.
        public static let debugAbort = "debug.abort"
        /// DEBUG: the service answers with its timing statistics. Has a reply.
        public static let debugStats = "debug.stats"
    }

    /// Events from the service to WSurf.
    public enum Event {
        public static let browserCreated = "browser.created"
        public static let browserReady = "browser.ready"
        public static let browserClosed = "browser.closed"
        public static let loadingState = "load.state"
        public static let loadStart = "load.start"
        public static let loadEnd = "load.end"
        public static let loadError = "load.error"
        public static let beforeBrowse = "nav.before"
        public static let address = "display.address"
        public static let title = "display.title"
        public static let progress = "display.progress"
        public static let statusMessage = "display.status"
        public static let fullscreen = "display.fullscreen"
        public static let cursor = "display.cursor"
        public static let tooltip = "display.tooltip"
        public static let renderTerminated = "render.terminated"
        public static let devToolsMessage = "devtools.msg"
        public static let devToolsResult = "devtools.result"
        public static let devToolsEvent = "devtools.event"
        public static let devToolsDetached = "devtools.detached"
        public static let findResult = "find.result"
        public static let collapsed = "history.collapsed"
        public static let imeRange = "ime.range"
        public static let textSelection = "text.selection"
        public static let contextMenu = "contextmenu.show"
        public static let unhandledKey = "key.unhandled"
        public static let takeFocus = "focus.take"
        public static let gotFocus = "focus.got"
        public static let popupBlocked = "popup.blocked"
        /// CEF's accessibility tree update (`on_accessibility_tree_change`), as JSON bytes.
        public static let accessibilityTree = "ax.tree"
        /// CEF's accessibility location update (`on_accessibility_location_change`), as JSON bytes.
        public static let accessibilityLocation = "ax.location"
    }

    public enum CollapseOutcome {
        public static let landed: Int64 = 0
        public static let refused: Int64 = 1
        public static let skipped: Int64 = 2
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
        xpc_dictionary_get_double(object, key)
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

extension CefCursorType {
    /// D4 spike: the cursor a remote browser asked for, from the raw `cef_cursor_type_t` value the service sends.
    public static func fromRemote(_ value: Int64) -> CefCursorType {
        CefCursorType(cefValue: cef_cursor_type_t(rawValue: UInt32(truncatingIfNeeded: value)))
    }
}
