// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-11: the DevTools section of `RemoteBrowser`, moved out of `RemoteBrowser.swift` unchanged (only the access of the members it shares
// with that file was loosened from `private`), to keep both files under the lint length limit.

import CCef
import CefKit
import Foundation

extension RemoteBrowser {
    // MARK: DevTools

    func attachDevTools(_ host: UnsafeMutablePointer<cef_browser_host_t>) {
        let observer = Native.allocate(cef_dev_tools_message_observer_t.self, owner: box)
        observer.pointee.on_dev_tools_message = { observerSelf, browser, message, size in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let message, size > 0, let owner = RemoteBrowser.owner(observerSelf) else { return 0 }
            return MainActor.assumeIsolated { owner.devToolsMessage(message, size: size) }
        }
        observer.pointee.on_dev_tools_method_result = { observerSelf, browser, messageID, success, result, size in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(observerSelf) else { return }
            MainActor.assumeIsolated { owner.devToolsResult(id: Int64(messageID), success: success != 0, result: result, size: size) }
        }
        observer.pointee.on_dev_tools_event = { observerSelf, browser, method, params, size in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(observerSelf) else { return }
            let name = Native.string(method)
            MainActor.assumeIsolated { owner.devToolsEvent(method: name, params: params, size: size) }
        }
        observer.pointee.on_dev_tools_agent_attached = { _, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
        }
        observer.pointee.on_dev_tools_agent_detached = { observerSelf, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(observerSelf) else { return }
            MainActor.assumeIsolated { owner.devToolsAgentDetached() }
        }
        observerPointer = observer
        // The call takes a reference to the observer.
        Native.retain(UnsafeMutableRawPointer(observer))
        registration = host.pointee.add_dev_tools_message_observer?(host, observer)
        if registration == nil {
            note("browser \(id): DevTools observer NOT attached")
        }
    }

    nonisolated static func owner<T>(_ observerSelf: UnsafeMutablePointer<T>?) -> RemoteBrowser? {
        Native.owner(BrowserBox.self, observerSelf.map(UnsafeMutableRawPointer.init))?.browser
    }

    /// Messages of a cross-site frame's session go to WSurf whole: CEF's parsed callbacks would drop their `sessionId`. The
    /// page's own messages are left to CEF, which then calls the result or event callback.
    private func devToolsMessage(_ message: UnsafeRawPointer, size: Int) -> Int32 {
        guard RemoteBrowser.isSessionMessage(message, size: size) else { return 0 }
        let forwarded = event(CefRemote.Event.devToolsMessage)
        forwarded.set(CefRemote.Key.data, bytes: message, count: size)
        send(forwarded)
        return 1
    }

    /// Whether `message` is a cross-site frame session's, by its top-level `sessionId`. The text alone proves nothing: a page
    /// controls its title and the values its scripts return, and a message that merely contains the word would be taken from CEF
    /// (whose result callback then never runs, so the service's own history read would never end). So the search is only a
    /// pre-filter; the message is parsed, and is claimed only when its top-level `sessionId` is a string. One that does not parse
    /// is claimed only when it ends as Chromium ends a session's message (the ID last), as `ChromiumDevTools` does in process.
    /// A message answering a command of the service's own is never claimed.
    private nonisolated static func isSessionMessage(_ message: UnsafeRawPointer, size: Int) -> Bool {
        let needle = "\"sessionId\""
        let found = needle.utf8CString.withUnsafeBufferPointer { pattern in
            memmem(message, size, pattern.baseAddress, pattern.count - 1) != nil
        }
        guard found else { return false }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: message), count: size, deallocator: .none)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let tail = String(decoding: data.suffix(160), as: UTF8.self)
            return tail.range(of: #","sessionId":"[^"\\]*"\}\s*$"#, options: .regularExpression) != nil
        }
        guard object["sessionId"] is String else { return false }
        if let messageID = object["id"] as? Int, Int64(messageID) >= CefRemote.serviceCommandBase {
            return false
        }
        return true
    }

    private func devToolsResult(id messageID: Int64, success: Bool, result: UnsafeRawPointer?, size: Int) {
        if messageID >= CefRemote.serviceCommandBase {
            serviceResult(id: messageID, success: success, result: result, size: size)
            return
        }
        let forwarded = event(CefRemote.Event.devToolsResult)
        forwarded.set(CefRemote.Key.identifier, messageID)
        forwarded.set(CefRemote.Key.success, success)
        forwarded.set(CefRemote.Key.data, bytes: result, count: size)
        send(forwarded)
    }

    private func devToolsEvent(method: String, params: UnsafeRawPointer?, size: Int) {
        let forwarded = event(CefRemote.Event.devToolsEvent)
        forwarded.set(CefRemote.Key.method, method)
        forwarded.set(CefRemote.Key.data, bytes: params, count: size)
        send(forwarded)
        // A same-document move (`pushState`, or Back between two entries of one address) is what no address or loading callback
        // may report (review F9); the page's own DevTools session (`Page.enable`) does.
        if method == "Page.navigatedWithinDocument" {
            refreshHistory()
        }
    }

    func sendDevTools(_ data: Data, host: UnsafeMutablePointer<cef_browser_host_t>) {
        let messageID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? Int
        // The ids from `serviceCommandBase` up are the service's own (its history read and collapse): a command of the host's
        // with one would be taken for those, and its result would never reach WSurf. Refused at once, and not sent.
        if let messageID, Int64(messageID) >= CefRemote.serviceCommandBase {
            failDevTools(id: messageID, "The command id is reserved for the service.")
            return
        }
        let accepted = data.withUnsafeBytes { bytes in
            host.pointee.send_dev_tools_message?(host, bytes.baseAddress, bytes.count) ?? 0
        }
        guard accepted == 0, let messageID else { return }
        // Rejected: answer the command so WSurf's wait ends now, not at its timeout.
        failDevTools(id: messageID, "Chromium DevTools rejected the command.")
    }

    private func failDevTools(id messageID: Int, _ message: String) {
        let failed = event(CefRemote.Event.devToolsResult)
        failed.set(CefRemote.Key.identifier, Int64(messageID))
        failed.set(CefRemote.Key.success, false)
        failed.set(CefRemote.Key.data, data: Data(#"{"message":"\#(message)"}"#.utf8))
        send(failed)
    }

    /// One of the service's own CDP commands (ids from `CefRemote.serviceCommandBase`, never forwarded to WSurf). `track` gets the
    /// id BEFORE the command is sent, because Chromium may deliver the result inside the send call; it is taken back with
    /// `untrack` when Chromium does not accept the command. False when it did not.
    func sendServiceCommand(
        _ method: String, host: UnsafeMutablePointer<cef_browser_host_t>, track: (Int64) -> Void, untrack: (Int64) -> Void
    ) -> Bool {
        let commandID = nextServiceCommand
        nextServiceCommand += 1
        track(commandID)
        let json = Array(#"{"id":\#(commandID),"method":"\#(method)","params":{}}"#.utf8)
        let accepted = json.withUnsafeBytes { bytes in
            host.pointee.send_dev_tools_message?(host, bytes.baseAddress, bytes.count) ?? 0
        }
        if accepted == 0 {
            untrack(commandID)
        }
        return accepted != 0
    }

    private func serviceResult(id commandID: Int64, success: Bool, result: UnsafeRawPointer?, size: Int) {
        if commandID == historyCommand {
            let data = result.map { Data(bytes: $0, count: size) } ?? Data()
            #if WSURF_SERVICE_DEBUG_OPS
            if delayNextResult > 0 {
                // A slow read (`debug.holdHistory` with a delay): the command stays in flight, and its result comes late.
                let delay = delayNextResult
                delayNextResult = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated { self?.lateHistoryResult(commandID, success: success, data: data) }
                }
                return
            }
            #endif
            historyCommand = nil
            historyResult(success: success, data: data)
        } else if let request = collapses.removeValue(forKey: commandID) {
            send(CefRemoteMessage.historyCollapsed(browser: id, request: request, outcome: success ? .landed : .refused))
            refreshHistory()
        }
    }
}
