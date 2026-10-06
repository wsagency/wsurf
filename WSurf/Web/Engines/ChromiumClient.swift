// SPDX-FileCopyrightText: 2026 wsagency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import CefKit
import Foundation
import Security
import WebKit

private nonisolated final class ChromiumTrackerPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var blocksTrackers: Bool
    private var exemptHosts: Set<String>
    private var topLevelURL: URL?

    init(blocksTrackers: Bool, exemptHosts: Set<String>, topLevelURL: URL? = nil) {
        self.blocksTrackers = blocksTrackers
        self.exemptHosts = exemptHosts
        self.topLevelURL = topLevelURL
    }

    func update(blocksTrackers: Bool, exemptHosts: Set<String>, topLevelURL: URL?) {
        lock.lock()
        self.blocksTrackers = blocksTrackers
        self.exemptHosts = exemptHosts
        self.topLevelURL = topLevelURL
        lock.unlock()
    }
    func updateTopLevelURL(_ url: URL?) {
        lock.lock()
        topLevelURL = url
        lock.unlock()
    }

    func shouldBlock(_ resourceURL: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocksTrackers && TrackerList.matches(
            resourceURL: resourceURL,
            topLevelURL: topLevelURL,
            exemptHosts: exemptHosts
        )
    }
}

/// Native CEF callback graph for one embedded ChromiumPage.
///
/// CEF gives callback arguments an owned reference. Every callback below drops
/// those references at the end of the callback. Callback objects retained for
/// an asynchronous decision live in `pendingCallbacks` until resolved or the
/// browser is closed.
@MainActor
final class ChromiumClient {
    weak var page: ChromiumPage?

    nonisolated(unsafe) private(set) var clientPointer: UnsafeMutablePointer<cef_client_t>?
    nonisolated(unsafe) private var lifeSpanPointer: UnsafeMutablePointer<cef_life_span_handler_t>?
    nonisolated(unsafe) private var loadPointer: UnsafeMutablePointer<cef_load_handler_t>?
    nonisolated(unsafe) private var displayPointer: UnsafeMutablePointer<cef_display_handler_t>?
    nonisolated(unsafe) private var downloadPointer: UnsafeMutablePointer<cef_download_handler_t>?
    nonisolated(unsafe) private var dialogPointer: UnsafeMutablePointer<cef_dialog_handler_t>?
    nonisolated(unsafe) private var contextMenuPointer: UnsafeMutablePointer<cef_context_menu_handler_t>?
    nonisolated(unsafe) private var jsDialogPointer: UnsafeMutablePointer<cef_jsdialog_handler_t>?
    nonisolated(unsafe) private var permissionPointer: UnsafeMutablePointer<cef_permission_handler_t>?
    nonisolated(unsafe) private var requestPointer: UnsafeMutablePointer<cef_request_handler_t>?
    nonisolated(unsafe) private var resourcePointer: UnsafeMutablePointer<cef_resource_request_handler_t>?
    nonisolated private let resourceStateLock = NSLock()
    nonisolated(unsafe) private var resourceHandlerClosed = false

    nonisolated private let trackerPolicy: ChromiumTrackerPolicy
    private var pendingCallbacks: [UInt: UInt] = [:]
    private var certificateCallbacks: Set<UInt> = []
    private var downloadCallbacks: [UInt32: UInt] = [:]
    private(set) var isClosed = false

    init(page: ChromiumPage) {
        self.page = page
        trackerPolicy = ChromiumTrackerPolicy(
            blocksTrackers: BrowserSettings.shared.blocksTrackers,
            exemptHosts: ContentBlocker.shared.exemptHosts,
            topLevelURL: page.owner?.url
        )
    }

    func updateSettings(_ settings: BrowserSettings) {
        trackerPolicy.update(
            blocksTrackers: settings.blocksTrackers,
            exemptHosts: ContentBlocker.shared.exemptHosts,
            topLevelURL: page?.owner?.url
        )
    }

    private nonisolated static func owner(_ raw: UnsafeMutableRawPointer?) -> ChromiumClient? {
        ChromiumInterop.owner(ChromiumClient.self, of: raw)
    }

    private nonisolated static func release(_ raw: UnsafeMutableRawPointer?) {
        ChromiumInterop.release(raw)
    }

    private static func browser(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<cef_browser_t>? {
        raw?.assumingMemoryBound(to: cef_browser_t.self)
    }

    private nonisolated static func releaseBrowser(_ browser: UnsafeMutablePointer<cef_browser_t>?) {
        release(browser.map(UnsafeMutableRawPointer.init))
    }

    private nonisolated static func releaseFrame(_ frame: UnsafeMutablePointer<cef_frame_t>?) {
        release(frame.map(UnsafeMutableRawPointer.init))
    }

    private nonisolated static func string(_ value: UnsafePointer<cef_string_t>?) -> String {
        ChromiumInterop.string(value)
    }
    
    private nonisolated static func navigationType(
        _ transition: cef_transition_type_t
    ) -> WKNavigationType {
        let raw = transition.rawValue
        let source = raw & TT_SOURCE_MASK.rawValue
        if raw & TT_FORWARD_BACK_FLAG.rawValue != 0 { return .backForward }
        switch source {
        case TT_LINK.rawValue: return .linkActivated
        case TT_FORM_SUBMIT.rawValue: return .formSubmitted
        case TT_RELOAD.rawValue: return .reload
        default: return .other
        }
    }

    private func withBrowser(_ raw: UnsafeMutableRawPointer?, _ body: (ChromiumClient, ChromiumPage) -> Void) {
        guard !isClosed, let page, let client = Self.owner(raw) else { return }
        body(client, page)
    }

    private func hold(_ pointer: UnsafeMutableRawPointer) {
        pendingCallbacks[UInt(bitPattern: pointer)] = UInt(bitPattern: pointer)
    }

    private func finish(_ pointer: UnsafeMutableRawPointer) -> Bool {
        pendingCallbacks.removeValue(forKey: UInt(bitPattern: pointer)) != nil
    }

    private func drop(_ pointer: UnsafeMutableRawPointer) {
        Self.release(pointer)
    }
    private nonisolated func acquireResourceHandler() -> UnsafeMutablePointer<cef_resource_request_handler_t>? {
        resourceStateLock.lock()
        defer { resourceStateLock.unlock() }
        guard !resourceHandlerClosed, let resource = resourcePointer else { return nil }
        ChromiumInterop.retain(UnsafeMutableRawPointer(resource))
        return resource
    }

    private nonisolated func detachResourceHandler() -> UnsafeMutablePointer<cef_resource_request_handler_t>? {
        resourceStateLock.lock()
        let resource = resourcePointer
        resourcePointer = nil
        resourceHandlerClosed = true
        resourceStateLock.unlock()
        return resource
    }

    /// CEF owns the client reference while the browser is alive. Parent calls
    /// this after OnBeforeClose (or when materialization fails).
    func close() {
        guard !isClosed else { return }
        let resource = detachResourceHandler()
        isClosed = true
        for key in certificateCallbacks {
            if let address = pendingCallbacks[key],
               let raw = UnsafeMutableRawPointer(bitPattern: address) {
                raw.assumingMemoryBound(to: cef_callback_t.self).pointee.cancel?(raw.assumingMemoryBound(to: cef_callback_t.self))
            }
        }
        certificateCallbacks.removeAll()
        for address in pendingCallbacks.values {
            if let pointer = UnsafeMutableRawPointer(bitPattern: address) {
                Self.release(pointer)
            }
        }
        pendingCallbacks.removeAll()
        for address in Array(downloadCallbacks.values) {
            guard let pointer = UnsafeMutablePointer<cef_download_item_callback_t>(bitPattern: address) else { continue }
            pointer.pointee.cancel?(pointer)
            Self.release(UnsafeMutableRawPointer(pointer))
        }
        downloadCallbacks.removeAll()
        for pointer in [
            lifeSpanPointer.map(UnsafeMutableRawPointer.init),
            loadPointer.map(UnsafeMutableRawPointer.init),
            displayPointer.map(UnsafeMutableRawPointer.init),
            downloadPointer.map(UnsafeMutableRawPointer.init),
            dialogPointer.map(UnsafeMutableRawPointer.init),
            contextMenuPointer.map(UnsafeMutableRawPointer.init),
            jsDialogPointer.map(UnsafeMutableRawPointer.init),
            permissionPointer.map(UnsafeMutableRawPointer.init),
            requestPointer.map(UnsafeMutableRawPointer.init),
            clientPointer.map(UnsafeMutableRawPointer.init)
        ] { Self.release(pointer) }
        if let resource { Self.release(UnsafeMutableRawPointer(resource)) }
        lifeSpanPointer = nil
        loadPointer = nil
        displayPointer = nil
        downloadPointer = nil
        dialogPointer = nil
        contextMenuPointer = nil
        jsDialogPointer = nil
        permissionPointer = nil
        requestPointer = nil
        clientPointer = nil
    }

    deinit {
        // Parent normally invokes close on the main actor after CEF's final
        // close callback. Keep this fallback for failed browser creation.
        if !isClosed {
            for key in certificateCallbacks {
                if let address = pendingCallbacks[key],
                   let raw = UnsafeMutableRawPointer(bitPattern: address) {
                    let callback = raw.assumingMemoryBound(to: cef_callback_t.self)
                    callback.pointee.cancel?(callback)
                }
            }
            for address in pendingCallbacks.values {
                if let pointer = UnsafeMutableRawPointer(bitPattern: address) {
                    Self.release(pointer)
                }
            }
            for address in downloadCallbacks.values {
                guard let pointer = UnsafeMutablePointer<cef_download_item_callback_t>(bitPattern: address) else { continue }
                pointer.pointee.cancel?(pointer)
                Self.release(UnsafeMutableRawPointer(pointer))
            }
            let resource = detachResourceHandler()
            for pointer in [
                lifeSpanPointer.map(UnsafeMutableRawPointer.init),
                loadPointer.map(UnsafeMutableRawPointer.init),
                displayPointer.map(UnsafeMutableRawPointer.init),
                downloadPointer.map(UnsafeMutableRawPointer.init),
                dialogPointer.map(UnsafeMutableRawPointer.init),
                contextMenuPointer.map(UnsafeMutableRawPointer.init),
                jsDialogPointer.map(UnsafeMutableRawPointer.init),
                permissionPointer.map(UnsafeMutableRawPointer.init),
                requestPointer.map(UnsafeMutableRawPointer.init),
                clientPointer.map(UnsafeMutableRawPointer.init)
            ] { Self.release(pointer) }
            if let resource { Self.release(UnsafeMutableRawPointer(resource)) }
        }
    }

    func makeClient() -> UnsafeMutablePointer<cef_client_t> {
        let life = ChromiumInterop.allocate(cef_life_span_handler_t.self, owner: self)
        life.pointee.on_after_created = { handlerSelf, browser in
            guard let browser else { return }
            // Parent owns the browser +1 returned by browser creation. This is
            // the callback's independent +1 and must always be released.
            ChromiumClient.release(UnsafeMutableRawPointer(browser))
            guard ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) != nil else { return }
        }
        life.pointee.do_close = { handlerSelf, browser in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 1 }
            return MainActor.assumeIsolated {
                client.page?.onCloseRequested?()
                return 1 // The embedded host view closes, never the WSurf window.
            }
        }
        life.pointee.on_before_close = { handlerSelf, browser in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                client.page?.didClose()
                client.close()
            }
        }
        life.pointee.on_before_popup = {
            handlerSelf, browser, frame, _, targetURL, targetFrameName, targetDisposition,
            userGesture, popupFeatures, _, _, _, _, _ in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
            let url = URL(string: ChromiumClient.string(targetURL))
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 1 }
            return MainActor.assumeIsolated {
                guard let page = client.page, !client.isClosed, let url else { return 1 }
                page.openWindow?(url, userGesture != 0)
                return 1
            }
        }
        lifeSpanPointer = life

        let load = ChromiumInterop.allocate(cef_load_handler_t.self, owner: self)
        load.pointee.on_loading_state_change = { handlerSelf, browser, loading, back, forward in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                client.page?.didChangeLoading(loading != 0, canGoBack: back != 0, canGoForward: forward != 0)
            }
        }
        load.pointee.on_load_start = { handlerSelf, browser, frame, _ in
            ChromiumClient.releaseBrowser(browser)
            defer { ChromiumClient.releaseFrame(frame) }
            guard let frame, frame.pointee.is_main?(frame) != 0,
                  let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.didStartLoad() }
        }
        load.pointee.on_load_end = { handlerSelf, browser, frame, status in
            ChromiumClient.releaseBrowser(browser)
            defer { ChromiumClient.releaseFrame(frame) }
            guard let frame, frame.pointee.is_main?(frame) != 0,
                  let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.didFinishLoad(status: Int(status)) }
        }
        load.pointee.on_load_error = { handlerSelf, browser, frame, code, text, failedURL in
            ChromiumClient.releaseBrowser(browser)
            defer { ChromiumClient.releaseFrame(frame) }
            guard let frame, frame.pointee.is_main?(frame) != 0,
                  let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let errorText = ChromiumClient.string(text)
            let url = ChromiumClient.string(failedURL)
            MainActor.assumeIsolated { client.page?.didFailLoad(code: Int(code.rawValue), text: errorText, url: url) }
        }
        loadPointer = load

        let display = ChromiumInterop.allocate(cef_display_handler_t.self, owner: self)
        display.pointee.on_address_change = { handlerSelf, browser, frame, url in
            ChromiumClient.releaseBrowser(browser)
            defer { ChromiumClient.releaseFrame(frame) }
            guard let frame, frame.pointee.is_main?(frame) != 0,
                  let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let resolved = URL(string: ChromiumClient.string(url))
            client.trackerPolicy.updateTopLevelURL(resolved)
            MainActor.assumeIsolated { client.page?.didChangeURL(resolved) }
        }
        display.pointee.on_title_change = { handlerSelf, browser, title in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.didChangeTitle(ChromiumClient.string(title)) }
        }
        display.pointee.on_fullscreen_mode_change = { handlerSelf, browser, fullscreen in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.didChangeFullscreen(fullscreen != 0) }
        }
        display.pointee.on_loading_progress_change = { handlerSelf, browser, progress in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.didChangeProgress(progress) }
        }
        display.pointee.on_status_message = { handlerSelf, browser, value in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let text = ChromiumClient.string(value)
            MainActor.assumeIsolated { client.page?.didHoverLink(URL(string: text)) }
        }
        display.pointee.on_console_message = { _, browser, _, _, _, _ in
            ChromiumClient.releaseBrowser(browser)
            return 0
        }
        display.pointee.on_media_access_change = { handlerSelf, browser, video, audio in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.captureChanged?(video != 0, audio != 0) }
        }
        displayPointer = display

        let download = ChromiumInterop.allocate(cef_download_handler_t.self, owner: self)
        download.pointee.can_download = { _, browser, _, _ in
            ChromiumClient.releaseBrowser(browser)
            return 1
        }
        download.pointee.on_before_download = { handlerSelf, browser, item, suggestedName, callback in
            ChromiumClient.releaseBrowser(browser)
            guard let item, let callback else {
                ChromiumClient.release(item.map(UnsafeMutableRawPointer.init))
                ChromiumClient.release(callback.map(UnsafeMutableRawPointer.init))
                return 0
            }
            let snapshot = ChromiumClient.download(item)
            ChromiumClient.release(UnsafeMutableRawPointer(item))
            let name = ChromiumClient.string(suggestedName)
            let callbackRaw = UnsafeMutableRawPointer(callback)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(callbackRaw)
                return 0
            }
            MainActor.assumeIsolated {
                guard !client.isClosed else { ChromiumClient.release(callbackRaw); return }
                client.hold(callbackRaw)
                let callbackAddress = UInt(bitPattern: callbackRaw)
                let decide: (@Sendable (CefDownloadDecision) -> Void) = { decision in
                    Task { @MainActor in
                        guard let callbackRaw = UnsafeMutableRawPointer(bitPattern: callbackAddress) else { return }
                        client.resolveDownload(callbackRaw, decision: decision, suggestedName: name)
                    }
                }
                if let page = client.page, let handler = page.downloadDecision {
                    handler(snapshot, name, decide)
                } else {
                    decide(.deny)
                }
            }
            return 1
        }
        download.pointee.on_download_updated = { handlerSelf, browser, item, callback in
            ChromiumClient.releaseBrowser(browser)
            guard let item else {
                ChromiumClient.release(callback.map(UnsafeMutableRawPointer.init))
                return
            }
            guard let callback else {
                ChromiumClient.release(UnsafeMutableRawPointer(item))
                return
            }
            let snapshot = ChromiumClient.download(item)
            let callbackRaw = UnsafeMutableRawPointer(callback)
            ChromiumClient.release(UnsafeMutableRawPointer(item))
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(callbackRaw)
                return
            }
            MainActor.assumeIsolated {
                guard !client.isClosed else { ChromiumClient.release(callbackRaw); return }
                if let oldAddress = client.downloadCallbacks.updateValue(UInt(bitPattern: callback), forKey: snapshot.id),
                   let old = UnsafeMutablePointer<cef_download_item_callback_t>(bitPattern: oldAddress) {
                    ChromiumClient.release(UnsafeMutableRawPointer(old))
                }
                client.page?.downloadProgress?(snapshot)
                if snapshot.isComplete || snapshot.isCanceled {
                    if let finalAddress = client.downloadCallbacks.removeValue(forKey: snapshot.id),
                       let final = UnsafeMutablePointer<cef_download_item_callback_t>(bitPattern: finalAddress) {
                        ChromiumClient.release(UnsafeMutableRawPointer(final))
                    }
                }
            }
        }
        downloadPointer = download

        makeJSDialogHandler()
        makeDialogHandler()
        makeContextMenuHandler()
        makePermissionHandler()
        makeResourceHandler()
        makeRequestHandler()

        let client = ChromiumInterop.allocate(cef_client_t.self, owner: self)
        client.pointee.get_life_span_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.lifeSpanPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_load_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.loadPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_display_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.displayPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_download_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.downloadPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_dialog_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.dialogPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_jsdialog_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.jsDialogPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_permission_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.permissionPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_request_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.requestPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_context_menu_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.contextMenuPointer else { return nil }
            ChromiumInterop.retain(UnsafeMutableRawPointer(handler))
            return handler
        }
        // The context handler leaves the native CEF menu and editing commands untouched.
        clientPointer = client
        return client
    }



    private nonisolated static func download(_ item: UnsafeMutablePointer<cef_download_item_t>) -> CefDownload {
        let url = ChromiumInterop.takeString(item.pointee.get_url?(item))
        let path = ChromiumInterop.takeString(item.pointee.get_full_path?(item))
        return CefDownload(
            id: item.pointee.get_id?(item) ?? 0,
            url: URL(string: url),
            receivedBytes: item.pointee.get_received_bytes?(item) ?? 0,
            totalBytes: item.pointee.get_total_bytes?(item) ?? 0,
            isComplete: item.pointee.is_complete?(item) != 0,
            isCanceled: item.pointee.is_canceled?(item) != 0 || item.pointee.is_interrupted?(item) != 0,
            fullPath: path.isEmpty ? nil : URL(fileURLWithPath: path)
        )
    }

    private func resolveDownload(_ raw: UnsafeMutableRawPointer, decision: CefDownloadDecision, suggestedName: String) {
        guard finish(raw) else { return }
        guard !isClosed else { drop(raw); return }
        let callback = raw.assumingMemoryBound(to: cef_before_download_callback_t.self)
        guard case .allow(let destination) = decision else { drop(raw); return }
        let path = destination ?? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent((suggestedName as NSString).lastPathComponent)
        ChromiumInterop.withString(path.path) { value in callback.pointee.cont?(callback, value, 0) }
        drop(raw)
    }

    // MARK: JavaScript dialogs

    private func makeJSDialogHandler() {
        let handler = ChromiumInterop.allocate(cef_jsdialog_handler_t.self, owner: self)
        handler.pointee.on_jsdialog = { handlerSelf, browser, origin, type, message, defaultText, callback, suppress in
            ChromiumClient.releaseBrowser(browser)
            guard let callback else { return 0 }
            suppress?.pointee = 0
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(UnsafeMutableRawPointer(callback)); return 0
            }
            let raw = UnsafeMutableRawPointer(callback)
            let kind = type == JSDIALOGTYPE_ALERT ? 0 : (type == JSDIALOGTYPE_CONFIRM ? 1 : 2)
            let originText = ChromiumClient.string(origin)
            let messageText = ChromiumClient.string(message)
            let prompt = ChromiumClient.string(defaultText)
            MainActor.assumeIsolated { client.presentJSDialog(raw, kind: kind, origin: originText, message: messageText, prompt: prompt) }
            return 1
        }
        handler.pointee.on_before_unload_dialog = { handlerSelf, browser, message, isReload, callback in
            ChromiumClient.releaseBrowser(browser)
            guard let callback else { return 0 }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(UnsafeMutableRawPointer(callback)); return 0
            }
            let raw = UnsafeMutableRawPointer(callback)
            MainActor.assumeIsolated { client.presentBeforeUnload(raw, message: ChromiumClient.string(message), isReload: isReload != 0) }
            return 1
        }
        handler.pointee.on_reset_dialog_state = { _, browser in ChromiumClient.releaseBrowser(browser) }
        handler.pointee.on_dialog_closed = { _, browser in ChromiumClient.releaseBrowser(browser) }
        jsDialogPointer = handler
    }

    private func presentJSDialog(_ raw: UnsafeMutableRawPointer, kind: Int, origin: String, message: String, prompt: String) {
        guard !isClosed else { Self.release(raw); return }
        hold(raw)
        guard let window = page?.window else {
            guard finish(raw) else { return }
            let callback = raw.assumingMemoryBound(to: cef_jsdialog_callback_t.self)
            callback.pointee.cont?(callback, 0, nil)
            drop(raw)
            return
        }
        let alert = NSAlert()
        alert.messageText = origin.isEmpty ? "JavaScript" : origin
        alert.informativeText = message
        switch kind {
        case 0:
            alert.addButton(withTitle: String(localized: "OK"))
        case 1:
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        default:
            let field = NSSecureTextField(string: prompt)
            field.frame.size = NSSize(width: 260, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        }
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, self.finish(raw), !self.isClosed else { return }
            let success = response == .alertFirstButtonReturn
            let input = (alert?.accessoryView as? NSSecureTextField)?.stringValue
            let callback = raw.assumingMemoryBound(to: cef_jsdialog_callback_t.self)
            ChromiumInterop.withString(input ?? "") { value in callback.pointee.cont?(callback, success ? 1 : 0, value) }
            self.drop(raw)
        }
    }

    private func presentBeforeUnload(_ raw: UnsafeMutableRawPointer, message: String, isReload: Bool) {
        guard !isClosed else { Self.release(raw); return }
        hold(raw)
        guard let window = page?.window else {
            guard finish(raw) else { return }
            let callback = raw.assumingMemoryBound(to: cef_jsdialog_callback_t.self)
            callback.pointee.cont?(callback, 0, nil)
            drop(raw)
            return
        }
        let alert = NSAlert()
        alert.messageText = isReload ? String(localized: "Reload page?") : String(localized: "Leave page?")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Leave"))
        alert.addButton(withTitle: String(localized: "Stay"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.finish(raw), !self.isClosed else { return }
            let callback = raw.assumingMemoryBound(to: cef_jsdialog_callback_t.self)
            callback.pointee.cont?(callback, response == .alertFirstButtonReturn ? 1 : 0, nil)
            self.drop(raw)
        }
    }

    // MARK: File chooser

    private func makeDialogHandler() {
        let handler = ChromiumInterop.allocate(cef_dialog_handler_t.self, owner: self)
        handler.pointee.on_file_dialog = { handlerSelf, browser, mode, title, defaultPath, filters, _, _, callback in
            ChromiumClient.releaseBrowser(browser)
            guard let callback else { return 0 }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(UnsafeMutableRawPointer(callback))
                return 0
            }
            let raw = UnsafeMutableRawPointer(callback)
            let accepted = ChromiumClient.stringList(filters)
            let panel: NSSavePanel
            if mode == FILE_DIALOG_SAVE {
                panel = NSSavePanel()
            } else {
                let open = NSOpenPanel()
                open.canChooseDirectories = mode == FILE_DIALOG_OPEN_FOLDER
                open.canChooseFiles = mode != FILE_DIALOG_OPEN_FOLDER
                open.allowsMultipleSelection = mode == FILE_DIALOG_OPEN_MULTIPLE
                open.allowedFileTypes = accepted.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                panel = open
            }
            panel.title = ChromiumClient.string(title)
            let defaultValue = ChromiumClient.string(defaultPath)
            if !defaultValue.isEmpty {
                let url = URL(fileURLWithPath: defaultValue)
                panel.directoryURL = url.deletingLastPathComponent()
                if let save = panel as? NSSavePanel { save.nameFieldStringValue = url.lastPathComponent }
            }
            let parameters = PageFileSelection.Parameters(
                allowsMultipleSelection: mode == FILE_DIALOG_OPEN_MULTIPLE,
                allowsDirectories: mode == FILE_DIALOG_OPEN_FOLDER
            )
            MainActor.assumeIsolated {
                client.presentFileDialog(raw, panel: panel, parameters: parameters, planned: mode != FILE_DIALOG_SAVE)
            }
            return 1
        }
        dialogPointer = handler
    }

    private func presentFileDialog(
        _ raw: UnsafeMutableRawPointer,
        panel: NSSavePanel,
        parameters: PageFileSelection.Parameters,
        planned: Bool
    ) {
        guard !isClosed else {
            Self.release(raw)
            return
        }
        hold(raw)
        guard let chromiumPage = page, let owner = chromiumPage.owner, let window = owner.window else {
            cancelFileDialog(raw)
            return
        }
        let selection = planned ? PageFileSelection.pending.object(forKey: owner) : nil
        selection?.requestedPanel = true
        let expectedURL = owner.url
        Task { @MainActor [weak self, weak chromiumPage, weak owner, selection] in
            guard let self, !self.isClosed, let chromiumPage, let owner,
                  owner.chromium === chromiumPage, owner.window === window else {
                selection?.finish(nil)
                self?.cancelFileDialog(raw)
                return
            }
            var frame: BrowserFrame?
            if let selection {
                guard !selection.isCompleted,
                      let expectedURL,
                      selection.validate(),
                      PageFileSelection.pending.object(forKey: owner) === selection,
                      await PageDriver.automationSnapshot(in: owner) == selection.observationID,
                      let current = try? await chromiumPage.frame(
                          id: nil, requestURL: expectedURL, isMainFrame: true
                      ),
                      current.isMainFrame,
                      current.request.url == expectedURL,
                      SitePermissions.origin(for: current.request.url) == selection.origin else {
                    selection.finish(nil)
                    self.cancelFileDialog(raw)
                    return
                }
                frame = current
            }
            let files: [URL]?
            if let chooser = selection?.selectFiles {
                files = await chooser(parameters)
            } else if let open = panel as? NSOpenPanel {
                selection?.cancelPanel = { [weak open] in open?.cancel(nil) }
                files = await PageDialogs.presentFilePanel(open, in: window)
            } else {
                files = await PageDialogs.presentFilePanel(panel, in: window)
            }
            if let selection {
                guard let frame,
                      await PageDriver.automationSnapshot(in: owner) == selection.observationID,
                      (try? await chromiumPage.isLive(frame: frame)) == true,
                      !Task.isCancelled,
                      !selection.isCompleted,
                      selection.validate(),
                      PageFileSelection.pending.object(forKey: owner) === selection else {
                    selection.finish(nil)
                    self.cancelFileDialog(raw)
                    return
                }
            }
            selection?.finish(files?.count)
            self.completeFileDialog(raw, files: files)
        }
    }

    private func cancelFileDialog(_ raw: UnsafeMutableRawPointer) {
        guard finish(raw) else { return }
        let callback = raw.assumingMemoryBound(to: cef_file_dialog_callback_t.self)
        callback.pointee.cancel?(callback)
        drop(raw)
    }

    private func completeFileDialog(_ raw: UnsafeMutableRawPointer, files: [URL]?) {
        guard finish(raw) else { return }
        guard !isClosed else {
            drop(raw)
            return
        }
        let callback = raw.assumingMemoryBound(to: cef_file_dialog_callback_t.self)
        guard let files, !files.isEmpty else {
            callback.pointee.cancel?(callback)
            drop(raw)
            return
        }
        guard let list = cef_string_list_alloc() else {
            callback.pointee.cancel?(callback)
            drop(raw)
            return
        }
        for path in files.map(\.path) {
            ChromiumInterop.withString(path) { cef_string_list_append(list, $0) }
        }
        callback.pointee.cont?(callback, list)
        cef_string_list_free(list)
        drop(raw)
    }

    private nonisolated static func stringList(_ list: cef_string_list_t?) -> [String] {
        guard let list else { return [] }
        var values: [String] = []
        for index in 0..<cef_string_list_size(list) {
            var value = cef_string_t()
            if cef_string_list_value(list, index, &value) != 0 {
                values.append(withUnsafePointer(to: &value) { ChromiumInterop.string($0) })
                ccef_string_clear(&value)
            }
        }
        return values
    }

    private func makeContextMenuHandler() {
        let handler = ChromiumInterop.allocate(cef_context_menu_handler_t.self, owner: self)
        handler.pointee.on_before_context_menu = { _, browser, frame, params, model in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
            ChromiumClient.release(params.map(UnsafeMutableRawPointer.init))
            ChromiumClient.release(model.map(UnsafeMutableRawPointer.init))
        }
        handler.pointee.run_context_menu = { _, browser, frame, params, model, callback in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
            ChromiumClient.release(params.map(UnsafeMutableRawPointer.init))
            ChromiumClient.release(model.map(UnsafeMutableRawPointer.init))
            ChromiumClient.release(callback.map(UnsafeMutableRawPointer.init))
            return 0
        }
        handler.pointee.on_context_menu_command = { _, browser, frame, params, _, _ in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
            ChromiumClient.release(params.map(UnsafeMutableRawPointer.init))
            return 0
        }
        handler.pointee.on_context_menu_dismissed = { _, browser, frame in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
        }
        contextMenuPointer = handler
    }


    private func makePermissionHandler() {
        let handler = ChromiumInterop.allocate(cef_permission_handler_t.self, owner: self)
        handler.pointee.on_request_media_access_permission = { handlerSelf, browser, frame, origin, requested, callback in
            ChromiumClient.releaseBrowser(browser)
            defer { ChromiumClient.releaseFrame(frame) }
            guard let callback else { return 0 }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(UnsafeMutableRawPointer(callback)); return 0
            }
            let raw = UnsafeMutableRawPointer(callback)
            let originText = ChromiumClient.string(origin)
            let known = UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue)
                | UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue)
                | UInt32(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue)
                | UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue)
            let kinds = ChromiumClient.permissions(for: ChromiumClient.mediaKinds(for: requested))
            let unknown = requested & ~known != 0
            MainActor.assumeIsolated {
                client.resolvePermission(raw, frame: frame, origin: originText, permissions: kinds, unknown: unknown, mediaMask: requested)
            }
            return 1
        }
        handler.pointee.on_show_permission_prompt = { handlerSelf, browser, promptID, origin, requested, callback in
            ChromiumClient.releaseBrowser(browser)
            guard let callback else { return 0 }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(UnsafeMutableRawPointer(callback)); return 0
            }
            let raw = UnsafeMutableRawPointer(callback)
            let kinds = ChromiumClient.requestKinds(for: requested)
            let permissions = ChromiumClient.permissions(for: kinds)
            MainActor.assumeIsolated {
                client.resolvePermissionPrompt(raw, frameURL: URL(string: ChromiumClient.string(origin)), permissions: permissions, unknown: kinds.contains(.other), promptID: promptID)
            }
            return 1
        }
        handler.pointee.on_dismiss_permission_prompt = { _, browser, _, _ in ChromiumClient.releaseBrowser(browser) }
        permissionPointer = handler
    }

    private nonisolated static func mediaKinds(for mask: UInt32) -> CefPermissionKind {
        var kinds: CefPermissionKind = []
        if mask & UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue) != 0
            || mask & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue) != 0 { kinds.insert(.microphone) }
        if mask & UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue) != 0
            || mask & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue) != 0 { kinds.insert(.camera) }
        return kinds
    }

    private nonisolated static func requestKinds(for mask: UInt32) -> CefPermissionKind {
        let mappings: [(UInt32, CefPermissionKind)] = [
            (UInt32(CEF_PERMISSION_TYPE_CAMERA_STREAM.rawValue), .camera),
            (UInt32(CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM.rawValue), .camera),
            (UInt32(CEF_PERMISSION_TYPE_MIC_STREAM.rawValue), .microphone),
            (UInt32(CEF_PERMISSION_TYPE_GEOLOCATION.rawValue), .geolocation),
            (UInt32(CEF_PERMISSION_TYPE_NOTIFICATIONS.rawValue), .notifications),
            (UInt32(CEF_PERMISSION_TYPE_CLIPBOARD.rawValue), .clipboard),
            (UInt32(CEF_PERMISSION_TYPE_MIDI_SYSEX.rawValue), .midi),
            (UInt32(CEF_PERMISSION_TYPE_POINTER_LOCK.rawValue), .pointerLock),
            (UInt32(CEF_PERMISSION_TYPE_STORAGE_ACCESS.rawValue), .storageAccess),
            (UInt32(CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS.rawValue), .storageAccess),
            (UInt32(CEF_PERMISSION_TYPE_SENSORS.rawValue), .sensors),
            (UInt32(CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT.rawValue), .windowManagement),
            (UInt32(CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS.rawValue), .downloads)
        ]
        var kinds: CefPermissionKind = []
        var known: UInt32 = 0
        for (flag, kind) in mappings {
            known |= flag
            if mask & flag != 0 { kinds.insert(kind) }
        }
        if mask & ~known != 0 { kinds.insert(.other) }
        return kinds
    }

    private nonisolated static func permissions(for kinds: CefPermissionKind) -> [WebPermission] {
        var values: [WebPermission] = []
        if kinds.contains(.camera) { values.append(.camera) }
        if kinds.contains(.microphone) { values.append(.microphone) }
        if kinds.contains(.geolocation) { values.append(.location) }
        if kinds.contains(.notifications) { values.append(.notifications) }
        return values
    }

    private func resolvePermission(_ raw: UnsafeMutableRawPointer, frame: UnsafeMutablePointer<cef_frame_t>?, origin: String, permissions: [WebPermission], unknown: Bool, mediaMask: UInt32) {
        hold(raw)
        guard !unknown, !permissions.isEmpty, let frame else { cancelPermission(raw, media: true); return }
        let frameID = ChromiumInterop.takeString(frame.pointee.get_identifier?(frame))
        let isMain = frame.pointee.is_main?(frame) != 0
        let frameURL = URL(string: ChromiumInterop.takeString(frame.pointee.get_url?(frame)))
        let callbackAddress = UInt(bitPattern: raw)
        ChromiumInterop.retain(raw)
        Task { @MainActor [weak self] in
            defer {
                if let callback = UnsafeMutableRawPointer(bitPattern: callbackAddress) { Self.release(callback) }
            }
            guard let callback = UnsafeMutableRawPointer(bitPattern: callbackAddress) else { return }
            guard let self else {
                Self.cancelPermissionCallback(callback, media: true)
                return
            }
            guard !self.isClosed, let page = self.page else {
                self.cancelPermission(callback, media: true)
                return
            }
            do {
                let trusted = try await page.frame(id: frameID, requestURL: frameURL, isMainFrame: isMain)
                guard Self.sameOrigin(origin, trusted.securityOrigin), try await page.isLive(frame: trusted) else { return self.cancelPermission(callback, media: true) }
                let allowed = await page.permissionDecision?(trusted, permissions) ?? false
                guard try await page.isLive(frame: trusted) else { return self.cancelPermission(callback, media: true) }
                self.completePermission(callback, allow: allowed, mediaMask: mediaMask)
            } catch { self.cancelPermission(callback, media: true) }
        }
    }

    private func resolvePermissionPrompt(_ raw: UnsafeMutableRawPointer, frameURL: URL?, permissions: [WebPermission], unknown: Bool, promptID: UInt64) {
        hold(raw)
        guard !unknown, !permissions.isEmpty else { cancelPermission(raw, media: false); return }
        let callbackAddress = UInt(bitPattern: raw)
        ChromiumInterop.retain(raw)
        Task { @MainActor [weak self] in
            defer {
                if let callback = UnsafeMutableRawPointer(bitPattern: callbackAddress) { Self.release(callback) }
            }
            guard let callback = UnsafeMutableRawPointer(bitPattern: callbackAddress) else { return }
            guard let self else {
                Self.cancelPermissionCallback(callback, media: false)
                return
            }
            guard !self.isClosed, let page = self.page else {
                self.cancelPermission(callback, media: false)
                return
            }
            do {
                let trusted = try await page.frame(id: nil, requestURL: frameURL, isMainFrame: true)
                guard trusted.isMainFrame, Self.sameOrigin(frameURL?.absoluteString ?? "", trusted.securityOrigin), try await page.isLive(frame: trusted) else { return self.cancelPermission(callback, media: false) }
                let allowed = await page.permissionDecision?(trusted, permissions) ?? false
                guard try await page.isLive(frame: trusted) else { return self.cancelPermission(callback, media: false) }
                guard self.finish(callback) else { return }
                let cefCallback = callback.assumingMemoryBound(to: cef_permission_prompt_callback_t.self)
                cefCallback.pointee.cont?(cefCallback, allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY)
                self.drop(callback)
            } catch { self.cancelPermission(callback, media: false) }
        }
    }

    private func completePermission(_ raw: UnsafeMutableRawPointer, allow: Bool, mediaMask: UInt32) {
        guard finish(raw) else { return }
        let callback = raw.assumingMemoryBound(to: cef_media_access_callback_t.self)
        if allow { callback.pointee.cont?(callback, mediaMask) } else { callback.pointee.cancel?(callback) }
        drop(raw)
    }
    private nonisolated static func cancelPermissionCallback(_ raw: UnsafeMutableRawPointer, media: Bool) {
        if media {
            let callback = raw.assumingMemoryBound(to: cef_media_access_callback_t.self)
            callback.pointee.cancel?(callback)
        } else {
            let callback = raw.assumingMemoryBound(to: cef_permission_prompt_callback_t.self)
            callback.pointee.cont?(callback, CEF_PERMISSION_RESULT_DENY)
        }
    }

    private func cancelPermission(_ raw: UnsafeMutableRawPointer, media: Bool) {
        guard finish(raw) else { return }
        Self.cancelPermissionCallback(raw, media: media)
        drop(raw)
    }

    private static func sameOrigin(_ origin: String, _ trusted: BrowserSecurityOrigin) -> Bool {
        guard let url = URL(string: origin), let host = url.host(), let scheme = url.scheme else { return false }
        return scheme.caseInsensitiveCompare(trusted.protocol) == .orderedSame
            && host.caseInsensitiveCompare(trusted.host) == .orderedSame
            && (url.port ?? (scheme.lowercased() == "https" ? 443 : 80)) == trusted.port
    }


    // MARK: Navigation, certificates and authentication

    private func makeResourceHandler() {
        let handler = ChromiumInterop.allocate(cef_resource_request_handler_t.self, owner: self)
        handler.pointee.on_before_resource_load = { handlerSelf, browser, frame, request, callback in
            defer { ChromiumClient.release(callback.map(UnsafeMutableRawPointer.init)) }
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
            defer { ChromiumClient.release(request.map(UnsafeMutableRawPointer.init)) }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)),
                  let request,
                  let rawURL = request.pointee.get_url?(request)
            else { return RV_CONTINUE }
            defer { cef_string_userfree_utf16_free(rawURL) }
            guard request.pointee.get_resource_type?(request) != RT_MAIN_FRAME else { return RV_CONTINUE }
            guard let url = URL(string: ChromiumClient.string(UnsafePointer(rawURL))) else { return RV_CONTINUE }
            return client.trackerPolicy.shouldBlock(url) ? RV_CANCEL : RV_CONTINUE
        }
        resourceStateLock.lock()
        resourcePointer = handler
        resourceStateLock.unlock()
    }

    private func makeRequestHandler() {
        let handler = ChromiumInterop.allocate(cef_request_handler_t.self, owner: self)
        handler.pointee.get_resource_request_handler = { handlerSelf, browser, frame, request, _, _, _, disable in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
            ChromiumClient.release(request.map(UnsafeMutableRawPointer.init))
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)),
                  let resource = client.acquireResourceHandler()
            else { return nil }
            disable?.pointee = 0
            return resource
        }
        handler.pointee.on_before_browse = { handlerSelf, browser, frame, request, userGesture, redirect in
            ChromiumClient.releaseBrowser(browser)
            let isMain = frame?.pointee.is_main?(frame) != 0
            let sourceURL = URL(string: ChromiumInterop.takeString(frame?.pointee.get_url?(frame)))
            let transition = request?.pointee.get_transition_type?(request) ?? TT_EXPLICIT
            ChromiumClient.releaseFrame(frame)
            defer { ChromiumClient.release(request.map(UnsafeMutableRawPointer.init)) }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 1 }
            let url = URL(string: ChromiumInterop.takeString(request?.pointee.get_url?(request)))
            guard let url, ["http", "https", "file", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "") else { return 1 }
            var navigationRequest = URLRequest(url: url)
            navigationRequest.httpMethod = ChromiumInterop.takeString(request?.pointee.get_method?(request))
            if let post = request?.pointee.get_post_data?(request) {
                defer { ChromiumClient.release(UnsafeMutableRawPointer(post)) }
                // Only presence is needed by the engine gate; CEF retains the submitted bytes.
                if post.pointee.get_element_count?(post) ?? 0 > 0 { navigationRequest.httpBody = Data() }
            }
            let navigationType = ChromiumClient.navigationType(transition)
            return MainActor.assumeIsolated {
                guard !client.isClosed, let page = client.page else { return 1 }
                guard page.navigationDecision?(navigationRequest, isMain, userGesture != 0, redirect != 0, navigationType, sourceURL) != false else { return 1 }
                if isMain { page.willNavigate(navigationRequest, isRedirect: redirect != 0) }
                return 0
            }
        }
        handler.pointee.on_open_urlfrom_tab = { handlerSelf, browser, frame, targetURL, _, userGesture in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
            let url = URL(string: ChromiumClient.string(targetURL))
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 1 }
            return MainActor.assumeIsolated {
                guard let page = client.page, let url else { return 1 }
                page.openWindow?(url, userGesture != 0)
                return 1
            }
        }
        handler.pointee.on_certificate_error = { handlerSelf, browser, _, requestURL, ssl, callback in
            ChromiumClient.releaseBrowser(browser)
            let certificate = ssl.flatMap { $0.pointee.get_x509_certificate?($0) }
            let chain = certificate.map(CertificateTrust.chainData(from:)) ?? []
            ChromiumClient.release(certificate.map(UnsafeMutableRawPointer.init))
            ChromiumClient.release(ssl.map(UnsafeMutableRawPointer.init))
            guard let callback else { return 0 }
            let raw = UnsafeMutableRawPointer(callback)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(raw)
                return 0
            }
            let url = URL(string: ChromiumClient.string(requestURL))
            DispatchQueue.main.async { [weak client] in
                guard let client else {
                    let callback = raw.assumingMemoryBound(to: cef_callback_t.self)
                    callback.pointee.cancel?(callback)
                    ChromiumInterop.release(raw)
                    return
                }
                client.resolveCertificate(raw, requestURL: url, chain: chain)
            }
            return 1
        }
        handler.pointee.get_auth_credentials = { handlerSelf, browser, origin, proxy, host, port, realm, scheme, callback in
            ChromiumClient.releaseBrowser(browser)
            guard let callback else { return 0 }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(UnsafeMutableRawPointer(callback)); return 0
            }
            let raw = UnsafeMutableRawPointer(callback)
            let challenge = CefAuthChallenge(origin: ChromiumClient.string(origin), isProxy: proxy != 0, host: ChromiumClient.string(host), port: Int(port), realm: ChromiumClient.string(realm), scheme: ChromiumClient.string(scheme))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { client.presentAuth(raw, challenge: challenge) }
            }
            return 1
        }
        handler.pointee.on_render_process_terminated = { handlerSelf, browser, status, code, _ in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.didTerminate() }
        }
        requestPointer = handler
    }

    private func resolveCertificate(_ raw: UnsafeMutableRawPointer, requestURL: URL?, chain: [Data]) {
        guard !isClosed else {
            let callback = raw.assumingMemoryBound(to: cef_callback_t.self)
            callback.pointee.cancel?(callback)
            Self.release(raw)
            return
        }
        hold(raw)
        certificateCallbacks.insert(UInt(bitPattern: raw))
        guard let page, let expectedURL = requestURL,
              let trust = CertificateTrust.makeTrust(from: chain, host: expectedURL.host)
        else {
            cancelCertificate(raw)
            return
        }
        let profileID = page.profileID
        let initialURL = page.owner?.url
        let expectedHost = expectedURL.host?.lowercased()
        Task { @MainActor [weak self, weak page] in
            guard let self, !self.isClosed, let page, page.profileID == profileID else {
                self?.cancelCertificate(raw)
                return
            }
            let decision = await CertificateTrust.decideInvalid(
                host: expectedHost ?? "",
                trust: trust,
                allowsExceptions: BrowserSettings.shared.allowsCertificateExceptions,
                in: page.window
            )
            guard !self.isClosed, page.profileID == profileID,
                  let currentURL = page.owner?.url,
                  currentURL == initialURL || currentURL.host?.lowercased() == expectedHost
            else {
                self.cancelCertificate(raw)
                return
            }
            guard self.finishCertificate(raw) else { return }
            let callback = raw.assumingMemoryBound(to: cef_callback_t.self)
            switch decision {
            case .proceed:
                callback.pointee.cont?(callback)
            case .cancel, .useDefaultHandling:
                callback.pointee.cancel?(callback)
            }
            self.drop(raw)
        }
    }

    private func cancelCertificate(_ raw: UnsafeMutableRawPointer) {
        certificateCallbacks.remove(UInt(bitPattern: raw))
        guard finish(raw) else { return }
        let callback = raw.assumingMemoryBound(to: cef_callback_t.self)
        callback.pointee.cancel?(callback)
        drop(raw)
    }

    private func finishCertificate(_ raw: UnsafeMutableRawPointer) -> Bool {
        certificateCallbacks.remove(UInt(bitPattern: raw))
        return finish(raw)
    }

    private func presentAuth(_ raw: UnsafeMutableRawPointer, challenge: CefAuthChallenge) {
        guard !isClosed else { Self.release(raw); return }
        hold(raw)
        guard let window = page?.window else {
            guard finish(raw) else { return }
            let callback = raw.assumingMemoryBound(to: cef_auth_callback_t.self)
            callback.pointee.cancel?(callback)
            drop(raw)
            return
        }
        let alert = NSAlert()
        alert.messageText = challenge.host
        alert.informativeText = challenge.realm.isEmpty ? String(localized: "Authentication required") : challenge.realm
        let username = NSTextField(string: "")
        let password = NSSecureTextField(string: "")
        let stack = NSStackView(views: [username, password])
        stack.orientation = .vertical
        stack.spacing = 8
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Sign In"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.finish(raw), !self.isClosed else { return }
            let callback = raw.assumingMemoryBound(to: cef_auth_callback_t.self)
            if response == .alertFirstButtonReturn {
                ChromiumInterop.withString(username.stringValue) { user in
                    ChromiumInterop.withString(password.stringValue) { pass in callback.pointee.cont?(callback, user, pass) }
                }
            } else { callback.pointee.cancel?(callback) }
            self.drop(raw)
        }
    }

    // MARK: Download controls

    func cancelDownload(id: UInt32) {
        guard let address = downloadCallbacks[id],
              let callback = UnsafeMutablePointer<cef_download_item_callback_t>(bitPattern: address) else { return }
        callback.pointee.cancel?(callback)
    }

    func pauseDownload(id: UInt32) {
        guard let address = downloadCallbacks[id],
              let callback = UnsafeMutablePointer<cef_download_item_callback_t>(bitPattern: address) else { return }
        callback.pointee.pause?(callback)
    }

    func resumeDownload(id: UInt32) {
        guard let address = downloadCallbacks[id],
              let callback = UnsafeMutablePointer<cef_download_item_callback_t>(bitPattern: address) else { return }
        callback.pointee.resume?(callback)
    }

    /// Revoke an active origin capture grant without reloading the document.
    func revokeCapture(_ permission: WebPermission) async throws {
        try await setCapturePermission(permission, setting: "denied")
    }

    /// Restore the browser's prompt state after a site policy changes back to
    /// Ask. This intentionally never grants permission.
    func restoreCapturePrompt(_ permission: WebPermission) async throws {
        try await setCapturePermission(permission, setting: "prompt")
    }

    private func setCapturePermission(_ permission: WebPermission, setting: String) async throws {
        let name = try permissionName(permission)
        guard !isClosed, let page else { throw ChromiumError.closed }
        let profileID = page.profileID
        let origin = try captureOrigin()
        let target = try await page.command("Target.getTargetInfo")
        guard let info = target["targetInfo"] as? [String: Any],
              let contextID = info["browserContextId"] as? String, !contextID.isEmpty
        else {
            throw ChromiumError.unavailable("Chromium did not return the selected browser context.")
        }
        guard !isClosed, page.profileID == profileID, captureOriginIfCurrent() == origin else {
            throw ChromiumError.staleFrame
        }
        _ = try await page.command(
            "Browser.setPermission",
            params: [
                "permission": ["name": name],
                "setting": setting,
                "origin": origin,
                "browserContextId": contextID
            ]
        )
        guard !isClosed, page.profileID == profileID, captureOriginIfCurrent() == origin else {
            throw ChromiumError.staleFrame
        }
    }

    private func permissionName(_ permission: WebPermission) throws -> String {
        switch permission {
        case .camera: return "camera"
        case .microphone: return "microphone"
        default: throw ChromiumError.unavailable("This permission is not a Chromium capture permission.")
        }
    }

    private func captureOrigin() throws -> String {
        guard let url = page?.owner?.url, let scheme = url.scheme, let host = url.host(), !host.isEmpty else {
            throw ChromiumError.unavailable("The Chromium page has no trusted capture origin.")
        }
        guard scheme == "http" || scheme == "https" else {
            throw ChromiumError.unavailable("Capture permissions require an HTTP(S) origin.")
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
    
    private func captureOriginIfCurrent() -> String? {
        guard let url = page?.owner?.url, let scheme = url.scheme, let host = url.host(), !host.isEmpty,
              scheme == "http" || scheme == "https"
        else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }
}
