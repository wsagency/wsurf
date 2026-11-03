// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import CefKit
import Foundation

extension ChromiumClient {
    // MARK: File access

    /// Whether `url`, a subresource, must be cancelled because it is a file the page may not read. The scope is judged by the
    /// document of the frame that asks, never by the browser's last address; a frame that cannot say what it shows is refused.
    nonisolated func refusesFile(_ url: URL, requestedBy frame: UnsafeMutablePointer<cef_frame_t>?) -> Bool {
        guard url.isFileURL else { return false }
        var document: URL?
        if let frame, frame.pointee.is_valid?(frame) == 1 {
            document = URL(string: ChromiumInterop.takeString(frame.pointee.get_url?(frame)))
        }
        return fileScope.refuses(url, requestedBy: document)
    }

    // MARK: JavaScript dialogs

    func makeJSDialogHandler() {
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
        let request = PageDialogQueue.Request(
            kind: kind == 0 ? .alert : (kind == 1 ? .confirm : .prompt), message: message,
            origin: PageDialogText.origin(ofURL: origin), defaultText: kind == 2 ? prompt : nil)
        completeDialog(raw, request) { Self.jsDialogAlert(kind: kind, origin: origin, message: message, prompt: prompt) }
    }

    /// The sheet for an alert (0), confirm (1) or prompt (2). A prompt takes plain text, like WebKit's.
    static func jsDialogAlert(kind: Int, origin: String, message: String, prompt: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = origin.isEmpty ? "JavaScript" : origin
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        guard kind != 0 else { return alert }
        alert.addButton(withTitle: String(localized: "Cancel"))
        if kind == 2 {
            let field = NSTextField(string: prompt)
            field.frame.size = NSSize(width: 260, height: 24)
            alert.accessoryView = field
        }
        return alert
    }

    private func presentBeforeUnload(_ raw: UnsafeMutableRawPointer, message: String, isReload: Bool) {
        guard !isClosed else { Self.release(raw); return }
        hold(raw)
        let request = PageDialogQueue.Request(
            kind: .beforeUnload, message: message, origin: PageDialogText.origin(ofURL: page?.owner?.url?.absoluteString ?? ""),
            isReload: isReload)
        completeDialog(raw, request) {
            let alert = NSAlert()
            alert.messageText = isReload ? String(localized: "Reload page?") : String(localized: "Leave page?")
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "Leave"))
            alert.addButton(withTitle: String(localized: "Stay"))
            return alert
        }
    }

    /// Hands the dialog to the tab's queue, which shows `makeSheet` to the user, once they can see the tab, unless a connection
    /// answers first; then completes CEF's callback, with Cancel or Stay when the page went away first. Nothing is sent once
    /// the browser has closed.
    private func completeDialog(
        _ raw: UnsafeMutableRawPointer, _ request: PageDialogQueue.Request, makeSheet: @escaping @MainActor () -> NSAlert
    ) {
        let queue = page?.owner?.dialogs
        Task { @MainActor [weak self] in
            let answer = await PageDialogs.routed(request, via: queue) {
                // A page its tab has let go of (CEF asks one being closed before it unloads) is shown to nobody.
                guard let queue else { return .init(accepted: false) }
                let alert = makeSheet()
                let response = await PageDialogs.present(alert, over: self?.page, queue: queue)
                return .init(accepted: response == .alertFirstButtonReturn, text: (alert.accessoryView as? NSTextField)?.stringValue)
            }
            guard let self, self.finish(raw), !self.isClosed else { return }
            let callback = raw.assumingMemoryBound(to: cef_jsdialog_callback_t.self)
            ChromiumInterop.withString(answer?.text ?? "") { value in
                callback.pointee.cont?(callback, answer?.accepted == true ? 1 : 0, value)
            }
            self.drop(raw)
        }
    }

    func makeClient() -> UnsafeMutablePointer<cef_client_t> {
        makeLifeSpanHandler()
        makeLoadHandler()
        makeFrameHandler()
        makeDisplayHandler()
        makeDownloadHandler()
        makeJSDialogHandler()
        makeDialogHandler()
        makeContextMenuHandler()
        makePermissionHandler()
        makeResourceHandler()
        makeRequestHandler()
        return makeClientHandler()
    }

    nonisolated static func download(_ item: UnsafeMutablePointer<cef_download_item_t>) -> CefDownload {
        let url = ChromiumInterop.takeString(item.pointee.get_url?(item))
        let path = ChromiumInterop.takeString(item.pointee.get_full_path?(item))
        return CefDownload(
            id: item.pointee.get_id?(item) ?? 0,
            url: URL(string: url),
            receivedBytes: item.pointee.get_received_bytes?(item) ?? 0,
            totalBytes: item.pointee.get_total_bytes?(item) ?? 0,
            isComplete: item.pointee.is_complete?(item) != 0,
            isCanceled: item.pointee.is_canceled?(item) != 0 || item.pointee.is_interrupted?(item) != 0,
            fullPath: path.isEmpty ? nil : URL(fileURLWithPath: path),
            originalURL: URL(string: ChromiumInterop.takeString(item.pointee.get_original_url?(item))),
            mimeType: Optional(ChromiumInterop.takeString(item.pointee.get_mime_type?(item))).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func resolveDownload(_ raw: UnsafeMutableRawPointer, decision: CefDownloadDecision, suggestedName: String) {
        guard finish(raw) else { return }
        guard !isClosed else { drop(raw); return }
        let callback = raw.assumingMemoryBound(to: cef_before_download_callback_t.self)
        guard case .allow(let destination) = decision else { drop(raw); return }
        let path = destination ?? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent((suggestedName as NSString).lastPathComponent)
        ChromiumInterop.withString(path.path) { value in callback.pointee.cont?(callback, value, 0) }
        drop(raw)
    }
    nonisolated static func mediaKinds(for mask: UInt32) -> CefPermissionKind {
        var kinds: CefPermissionKind = []
        if mask & UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue) != 0
            || mask & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue) != 0 {
            kinds.insert(.microphone)
        }
        if mask & UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue) != 0
            || mask & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue) != 0 {
            kinds.insert(.camera)
        }
        return kinds
    }

    nonisolated static func requestKinds(for mask: UInt32) -> CefPermissionKind {
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
            (UInt32(CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS.rawValue), .downloads),
        ]
        var kinds: CefPermissionKind = []
        var known: UInt32 = 0
        for (flag, kind) in mappings {
            known |= flag
            if mask & flag != 0 {
                kinds.insert(kind)
            }
        }
        if mask & ~known != 0 {
            kinds.insert(.other)
        }
        return kinds
    }

    nonisolated static func permissions(for kinds: CefPermissionKind) -> [WebPermission] {
        var values: [WebPermission] = []
        if kinds.contains(.camera) {
            values.append(.camera)
        }
        if kinds.contains(.microphone) {
            values.append(.microphone)
        }
        if kinds.contains(.geolocation) {
            values.append(.location)
        }
        if kinds.contains(.notifications) {
            values.append(.notifications)
        }
        return values
    }
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
                "browserContextId": contextID,
            ]
        )
        guard !isClosed, page.profileID == profileID, captureOriginIfCurrent() == origin else {
            throw ChromiumError.staleFrame
        }
    }

    private func permissionName(_ permission: WebPermission) throws -> String {
        switch permission {
        case .camera:
            return "camera"
        case .microphone:
            return "microphone"
        default:
            throw ChromiumError.unavailable("This permission is not a Chromium capture permission.")
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
    private func makeLifeSpanHandler() {
        let life = ChromiumInterop.allocate(cef_life_span_handler_t.self, owner: self)
        life.pointee.on_after_created = { handlerSelf, browser in
            guard let browser else { return }
            // Parent owns the browser +1 returned by browser creation. This is
            // the callback's independent +1 and must always be released.
            defer { ChromiumClient.release(UnsafeMutableRawPointer(browser)) }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            // Only a pop-up's page takes it: every other browser is the one its page made itself.
            MainActor.assumeIsolated { client.page?.adoptPopup(browser) }
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
        life.pointee.on_before_popup = { handlerSelf, browser, frame, popupID, targetURL, _, disposition, userGesture, _, windowInfo, popupClient, _, extraInfo, _ in
            ChromiumClient.releaseBrowser(browser)
            let sourceURL = frame?.pointee.is_valid?(frame) == 1
                ? URL(string: ChromiumInterop.takeString(frame?.pointee.get_url?(frame))) : nil
            ChromiumClient.releaseFrame(frame)
            // The client and extra information CEF offers (the opener's) arrive with a reference that is ours to drop, kept or
            // replaced; a replacement goes back with one of its own.
            ChromiumClient.release(popupClient?.pointee.map(UnsafeMutableRawPointer.init))
            ChromiumClient.release(extraInfo?.pointee.map(UnsafeMutableRawPointer.init))
            // `window.open()` with no address opens about:blank, which its opener then writes or navigates.
            let target = ChromiumClient.string(targetURL)
            let url = target.isEmpty ? URL(string: "about:blank") : URL(string: target)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 1 }
            return MainActor.assumeIsolated {
                guard let page = client.page, !client.isClosed, let url else { return 1 }
                let sourceFrame = page.sourceFrame(for: sourceURL)
                let gesture = userGesture != 0
                guard let openPopup = page.openPopup else {
                    page.openWindow?(url, gesture, sourceURL, sourceFrame)
                    return 1
                }
                guard let host = openPopup(url, gesture, sourceURL, sourceFrame, disposition == CEF_WOD_NEW_BACKGROUND_TAB) else { return 1 }
                guard let windowInfo, let popupClient, let hosted = host.hostPopup(id: popupID, opener: page, in: &windowInfo.pointee) else {
                    host.popupAborted()
                    return 1
                }
                popupClient.pointee = hosted
                return 0
            }
        }
        life.pointee.on_before_popup_aborted = { handlerSelf, browser, popupID in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.pendingPopups[popupID]?.popupAborted() }
        }
        lifeSpanPointer = life
    }

    private func makeFrameHandler() {
        let handler = ChromiumInterop.allocate(cef_frame_handler_t.self, owner: self)
        handler.pointee.on_frame_attached = { handlerSelf, browser, frame, _ in
            defer {
                ChromiumClient.releaseBrowser(browser)
                ChromiumClient.releaseFrame(frame)
            }
            guard let frame, let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.advanceDocument(frame, attached: true) }
        }
        handler.pointee.on_frame_detached = { handlerSelf, browser, frame in
            defer {
                ChromiumClient.releaseBrowser(browser)
                ChromiumClient.releaseFrame(frame)
            }
            guard let frame, let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.retireDocument(frame) }
        }
        handler.pointee.on_frame_destroyed = handler.pointee.on_frame_detached
        framePointer = handler
    }

    private func makeLoadHandler() {
        let load = ChromiumInterop.allocate(cef_load_handler_t.self, owner: self)
        load.pointee.on_loading_state_change = { handlerSelf, browser, loading, back, forward in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            if loading == 0 {
                client.endMainFrameRequest()
            }
            MainActor.assumeIsolated {
                client.page?.didChangeLoading(loading != 0, canGoBack: back != 0, canGoForward: forward != 0)
            }
        }
        load.pointee.on_load_start = { handlerSelf, browser, frame, _ in
            ChromiumClient.releaseBrowser(browser)
            defer { ChromiumClient.releaseFrame(frame) }
            guard let frame,
                  let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                client.advanceDocument(frame)
                if frame.pointee.is_main?(frame) == 1 {
                    client.endMainFrameRequest()
                    client.page?.didStartLoad()
                }
            }
        }
        load.pointee.on_load_end = { handlerSelf, browser, frame, status in
            ChromiumClient.releaseBrowser(browser)
            defer { ChromiumClient.releaseFrame(frame) }
            guard let frame, frame.pointee.is_main?(frame) != 0,
                  let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            client.endMainFrameRequest()
            MainActor.assumeIsolated { client.page?.didFinishLoad(status: Int(status)) }
        }
        load.pointee.on_load_error = { handlerSelf, browser, frame, code, text, failedURL in
            ChromiumClient.releaseBrowser(browser)
            defer { ChromiumClient.releaseFrame(frame) }
            guard let frame,
                  let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                if code != ERR_ABORTED {
                    client.advanceDocument(frame)
                }
                if frame.pointee.is_main?(frame) == 1 {
                    client.endMainFrameRequest()
                    client.page?.didFailLoad(code: Int(code.rawValue),
                                            text: ChromiumClient.string(text), url: ChromiumClient.string(failedURL))
                }
            }
        }
        loadPointer = load
    }

    private func makeDisplayHandler() {
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
        display.pointee.on_title_change = { handlerSelf, browser, _ in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { client.page?.didChangeTitle() }
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
    }

    private func makeDownloadHandler() {
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
    }

    private func makeClientHandler() -> UnsafeMutablePointer<cef_client_t> {
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
        client.pointee.get_frame_handler = { clientSelf in
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.framePointer else { return nil }
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
            guard let me = ChromiumClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)) else { return nil }
            return me.acquireRequestHandler()
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

    func makeContextMenuHandler() {
        let handler = ChromiumInterop.allocate(cef_context_menu_handler_t.self, owner: self)
        handler.pointee.on_before_context_menu = { handlerSelf, browser, frame, params, model in
            if let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)), let params, let model {
                let editable = params.pointee.is_editable?(params) == 1
                let clicked = frame.map { frame in
                    CredentialPicker.ChromiumFrame(
                        id: ChromiumInterop.takeString(frame.pointee.get_identifier?(frame)),
                        url: URL(string: ChromiumInterop.takeString(frame.pointee.get_url?(frame))),
                        isMain: frame.pointee.is_main?(frame) == 1
                    )
                }
                let link = URL(string: ChromiumInterop.takeString(params.pointee.get_link_url?(params)))
                MainActor.assumeIsolated {
                    client.offerPDFItems(in: model)
                    client.offerLinkItems(in: model, link: link, frameURL: clicked?.url)
                    client.offerCredentialPicker(in: model, editable: editable, frame: clicked)
                }
            }
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
        handler.pointee.on_context_menu_command = { handlerSelf, browser, frame, params, command, _ in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
            ChromiumClient.release(params.map(UnsafeMutableRawPointer.init))
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            return MainActor.assumeIsolated {
                command == ChromiumClient.pickCredentialCommand
                    ? client.runCredentialPicker()
                    : client.openContextLink(command) || client.runPDFCommand(command)
            } ? 1 : 0
        }
        handler.pointee.on_context_menu_dismissed = { _, browser, frame in
            ChromiumClient.releaseBrowser(browser)
            ChromiumClient.releaseFrame(frame)
        }
        contextMenuPointer = handler
    }

    /// The Pick Credential… command: the first id CEF leaves to the embedder.
    nonisolated static let pickCredentialCommand = Int32(MENU_ID_USER_FIRST.rawValue)

    /// The Open Link commands, the ids after it. A private tab offers no plain window, as a WebKit one does not
    /// (`TabContextMenu.linkWindowItems`).
    nonisolated static func linkCommands(isPrivate: Bool) -> [(id: Int32, opening: ChromiumPage.LinkOpening, title: LocalizedStringResource)] {
        let all: [(id: Int32, opening: ChromiumPage.LinkOpening, title: LocalizedStringResource)] = [
            (pickCredentialCommand + 1, .tab, "Open Link in New Tab"),
            (pickCredentialCommand + 2, .window, "Open Link in New Window"),
            (pickCredentialCommand + 3, .privateWindow, "Open Link in New Private Window"),
        ]
        return all.filter { $0.opening != .window || !isPrivate }
    }

    /// The PDF commands, the ids after the Open Link ones.
    nonisolated static let downloadPDFCommand = pickCredentialCommand + 4
    nonisolated static let openPDFCommand = pickCredentialCommand + 5

    /// The engine's own menu has no Save for a PDF viewer's page, so a tab that shows a PDF gets Download PDF, which saves the PDF
    /// as a download, and Open in Preview, which saves it and opens the copy (`BrowserTab.savePDF`).
    func offerPDFItems(in model: UnsafeMutablePointer<cef_menu_model_t>) {
        guard let page, page.showsPDF?() == true else { return }
        let items = [
            (Self.downloadPDFCommand, String(localized: "Download PDF")),
            (Self.openPDFCommand, String(localized: "Open in Preview")),
        ]
        var index = 0
        for (command, title) in items {
            let added = ChromiumInterop.withString(title) { model.pointee.insert_item_at?(model, index, command, $0) }
            if added == 1 {
                index += 1
            }
        }
        guard index > 0 else { return }
        _ = model.pointee.insert_separator_at?(model, index)
    }

    /// Runs a PDF command of the menu that is open, if `command` is one.
    func runPDFCommand(_ command: Int32) -> Bool {
        guard command == Self.downloadPDFCommand || command == Self.openPDFCommand, let save = page?.onSavePDF else { return false }
        save(command == Self.openPDFCommand)
        return true
    }

    /// The engine's own menu has no item for a link (Back, Forward, Print, View Page Source), so a right-click on one gets what a
    /// WebKit tab's menu has first: the link in a new tab, in a new window and in a new private window (a private tab offers the
    /// last alone), as `TabContextMenu.linkWindowItems` does.
    func offerLinkItems(in model: UnsafeMutablePointer<cef_menu_model_t>, link: URL?, frameURL: URL?) {
        page?.contextLink = nil
        guard let link, let page else { return }
        var index = 0
        for command in Self.linkCommands(isPrivate: page.context.profile.isPrivate) {
            let added = ChromiumInterop.withString(String(localized: command.title)) {
                model.pointee.insert_item_at?(model, index, command.id, $0)
            }
            if added == 1 {
                index += 1
            }
        }
        guard index > 0 else { return }
        _ = model.pointee.insert_separator_at?(model, index)
        page.contextLink = (link, frameURL)
    }

    /// Runs an Open Link command of the menu that is open, if `command` is one.
    func openContextLink(_ command: Int32) -> Bool {
        guard let page, let link = page.contextLink,
              let opening = Self.linkCommands(isPrivate: false).first(where: { $0.id == command })?.opening else { return false }
        page.contextLink = nil
        page.openLinkFromMenu?(link.url, link.frameURL, opening)
        return true
    }

    /// Puts Pick Credential… at the top of an editable field's menu when the tab offers it, and remembers which frame the engine says
    /// was right-clicked and when.
    func offerCredentialPicker(in model: UnsafeMutablePointer<cef_menu_model_t>, editable: Bool, frame: CredentialPicker.ChromiumFrame?) {
        pickCredentialMenu = nil
        guard editable, let page, page.canPickCredential?() == true else { return }
        let added = ChromiumInterop.withString(String(localized: "Pick Credential…")) {
            model.pointee.insert_item_at?(model, 0, Self.pickCredentialCommand, $0)
        }
        guard added == 1 else { return }
        if (model.pointee.get_count?(model) ?? 0) > 1 {
            _ = model.pointee.insert_separator_at?(model, 1)
        }
        pickCredentialMenu = CredentialPicker.Menu(opened: .now, chromiumFrame: frame)
    }

    func runCredentialPicker() -> Bool {
        guard let menu = pickCredentialMenu, let page else { return false }
        pickCredentialMenu = nil
        page.onPickCredential?(menu)
        return true
    }

    func makeDialogHandler() {
        let handler = ChromiumInterop.allocate(cef_dialog_handler_t.self, owner: self)
        handler.pointee.on_file_dialog = { handlerSelf, browser, mode, title, defaultPath, filters, acceptExtensions, _, callback in
            ChromiumClient.releaseBrowser(browser)
            guard let callback else { return 0 }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                ChromiumClient.release(UnsafeMutableRawPointer(callback))
                return 0
            }
            let raw = UnsafeMutableRawPointer(callback)
            let filters = ChromiumClient.stringList(filters)
            let extensions = ChromiumClient.stringList(acceptExtensions)
            let panel: NSSavePanel
            if mode == FILE_DIALOG_SAVE {
                panel = NSSavePanel()
            } else {
                let open = NSOpenPanel()
                open.canChooseDirectories = mode == FILE_DIALOG_OPEN_FOLDER
                open.canChooseFiles = mode != FILE_DIALOG_OPEN_FOLDER
                open.allowsMultipleSelection = mode == FILE_DIALOG_OPEN_MULTIPLE
                let contentTypes = ChromiumInterop.fileDialogContentTypes(filters: filters, extensions: extensions)
                if !contentTypes.isEmpty {
                    open.allowedContentTypes = contentTypes
                }
                panel = open
            }
            panel.title = ChromiumClient.string(title)
            let defaultValue = ChromiumClient.string(defaultPath)
            if !defaultValue.isEmpty {
                let url = URL(fileURLWithPath: defaultValue)
                panel.directoryURL = url.deletingLastPathComponent()
                panel.nameFieldStringValue = url.lastPathComponent
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

}
