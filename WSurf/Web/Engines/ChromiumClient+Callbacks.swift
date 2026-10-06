// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import CefKit
import Foundation

extension ChromiumClient {
    func makeClient() -> UnsafeMutablePointer<cef_client_t> {
        makeLifeSpanHandler()
        makeLoadHandler()
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
            fullPath: path.isEmpty ? nil : URL(fileURLWithPath: path)
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
        life.pointee.on_before_popup = { handlerSelf, browser, frame, _, targetURL, _, _, userGesture, _, _, _, _, _, _ in
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
    }

    private func makeLoadHandler() {
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
