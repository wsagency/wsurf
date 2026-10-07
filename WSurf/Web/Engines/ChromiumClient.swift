// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import CefKit
import Foundation
import Security
import WebKit

nonisolated final class ChromiumTrackerPolicy: @unchecked Sendable {
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

/// CEF's UI request has no ID, and its IO request ID is not a navigation ID.
/// Publish native response metadata only when the committed CDP loader confirms
/// the same values; a late same-URL request cannot claim a newer navigation.
@MainActor
final class ChromiumDocumentResponses {
    private struct Metadata: Hashable {
        let url: URL?
        let status: Int
        let headers: [String: String]

        init(_ response: HTTPURLResponse) {
            var components = response.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            components?.fragment = nil
            url = components?.url ?? response.url
            status = response.statusCode
            headers = response.allHeaderFields.reduce(into: [:]) { fields, field in
                fields[String(describing: field.key).lowercased()] =
                    String(describing: field.value).replacingOccurrences(of: "\n", with: ", ")
            }
        }
    }

    private var nativeResponses: [Metadata: HTTPURLResponse] = [:]
    private var confirmedResponses: [String: (frameID: String, metadata: Metadata)] = [:]
    private var committedDocument: (frameID: String, loaderID: String)?
    private var delivered = false

    func reset() {
        nativeResponses.removeAll(keepingCapacity: true)
        confirmedResponses.removeAll(keepingCapacity: true)
        committedDocument = nil
        delivered = false
    }

    func receive(_ response: HTTPURLResponse) -> HTTPURLResponse? {
        guard !delivered else { return nil }
        nativeResponses[Metadata(response)] = response
        return takeCommittedResponse()
    }

    func confirm(_ response: HTTPURLResponse, frameID: String, loaderID: String) -> HTTPURLResponse? {
        guard !delivered, !frameID.isEmpty, !loaderID.isEmpty else { return nil }
        confirmedResponses[loaderID] = (frameID, Metadata(response))
        return takeCommittedResponse()
    }

    func commit(frameID: String, loaderID: String) -> HTTPURLResponse? {
        guard !delivered, !frameID.isEmpty, !loaderID.isEmpty else { return nil }
        committedDocument = (frameID, loaderID)
        return takeCommittedResponse()
    }

    private func takeCommittedResponse() -> HTTPURLResponse? {
        guard let committedDocument,
              let confirmed = confirmedResponses[committedDocument.loaderID],
              confirmed.frameID == committedDocument.frameID,
              let response = nativeResponses[confirmed.metadata] else { return nil }
        delivered = true
        nativeResponses.removeAll(keepingCapacity: true)
        confirmedResponses.removeAll(keepingCapacity: true)
        return response
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

    nonisolated(unsafe) var clientPointer: UnsafeMutablePointer<cef_client_t>?
    nonisolated(unsafe) var lifeSpanPointer: UnsafeMutablePointer<cef_life_span_handler_t>?
    nonisolated(unsafe) var loadPointer: UnsafeMutablePointer<cef_load_handler_t>?
    nonisolated(unsafe) var framePointer: UnsafeMutablePointer<cef_frame_handler_t>?
    nonisolated(unsafe) var displayPointer: UnsafeMutablePointer<cef_display_handler_t>?
    nonisolated(unsafe) var downloadPointer: UnsafeMutablePointer<cef_download_handler_t>?
    nonisolated(unsafe) var dialogPointer: UnsafeMutablePointer<cef_dialog_handler_t>?
    nonisolated(unsafe) var contextMenuPointer: UnsafeMutablePointer<cef_context_menu_handler_t>?
    nonisolated(unsafe) var jsDialogPointer: UnsafeMutablePointer<cef_jsdialog_handler_t>?
    nonisolated(unsafe) var permissionPointer: UnsafeMutablePointer<cef_permission_handler_t>?
    nonisolated(unsafe) var requestPointer: UnsafeMutablePointer<cef_request_handler_t>?
    nonisolated(unsafe) var resourcePointer: UnsafeMutablePointer<cef_resource_request_handler_t>?
    nonisolated private let resourceStateLock = NSLock()
    nonisolated(unsafe) private var resourceHandlerClosed = false

    nonisolated let trackerPolicy: ChromiumTrackerPolicy
    let documentResponses = ChromiumDocumentResponses()
    private var pendingCallbacks: [UInt: UInt] = [:]
    private var certificateCallbacks: Set<UInt> = []
    var downloadCallbacks: [UInt32: UInt] = [:]
    private(set) var isClosed = false
    private var nativeDocuments: [String: UInt64] = [:]
    private var documentEpoch: UInt64 = 0

    init(page: ChromiumPage) {
        self.page = page
        trackerPolicy = ChromiumTrackerPolicy(
            blocksTrackers: page.context.settings.blocksTrackers,
            exemptHosts: page.context.contentBlocker.exemptHosts,
            topLevelURL: page.owner?.url
        )
    }

    func updateSettings(_ settings: BrowserSettings) {
        guard let page else { return }
        trackerPolicy.update(
            blocksTrackers: settings.blocksTrackers,
            exemptHosts: page.context.contentBlocker.exemptHosts,
            topLevelURL: page.owner?.url
        )
    }

    func advanceDocument(_ frame: UnsafeMutablePointer<cef_frame_t>, attached: Bool = false) {
        guard !isClosed, frame.pointee.is_valid?(frame) == 1 else { return }
        let id = ChromiumInterop.takeString(frame.pointee.get_identifier?(frame))
        guard !id.isEmpty, attached || nativeDocuments[id] != nil else { return }
        documentEpoch += 1
        nativeDocuments[id] = documentEpoch
    }

    func retireDocument(_ frame: UnsafeMutablePointer<cef_frame_t>) {
        nativeDocuments[ChromiumInterop.takeString(frame.pointee.get_identifier?(frame))] = nil
    }

    func externalAppSnapshot(for source: BrowserFrame?) -> (documents: [String: UInt64], sourceIsUnique: Bool)? {
        guard !isClosed, let page, !nativeDocuments.isEmpty else { return nil }
        guard let source else { return (nativeDocuments, false) }
        let origin = SitePermissions.webOrigin(for: source.request.url)
        guard !origin.isEmpty else { return (nativeDocuments, false) }
        return page.withBrowser { browser -> (documents: [String: UInt64], sourceIsUnique: Bool)? in
            var match: (id: String, epoch: UInt64)?
            for (id, epoch) in nativeDocuments {
                guard let frame = ChromiumInterop.withString(id, {
                    browser.pointee.get_frame_by_identifier?(browser, $0)
                }) else { return nil }
                defer { Self.releaseFrame(frame) }
                guard frame.pointee.is_valid?(frame) == 1 else { return nil }
                let url = URL(string: ChromiumInterop.takeString(frame.pointee.get_url?(frame)))
                let candidate = SitePermissions.webOrigin(for: url)
                // Inherited/opaque documents cannot establish a unique HTTP source.
                guard !candidate.isEmpty else { return (nativeDocuments, false) }
                if candidate == origin {
                    guard match == nil else { return (nativeDocuments, false) }
                    match = (id, epoch)
                }
            }
            guard let match else { return nil }
            return ([match.id: match.epoch], true)
        } ?? nil
    }

    func isCurrentExternalAppSnapshot(_ documents: [String: UInt64]) -> Bool {
        guard !isClosed, let page, !documents.isEmpty else { return false }
        return page.withBrowser { browser in
            for (id, epoch) in documents {
                guard nativeDocuments[id] == epoch,
                      let frame = ChromiumInterop.withString(id, {
                          browser.pointee.get_frame_by_identifier?(browser, $0)
                      }) else { return false }
                defer { Self.releaseFrame(frame) }
                guard frame.pointee.is_valid?(frame) == 1 else { return false }
            }
            return true
        } ?? false
    }

    nonisolated static func owner(_ raw: UnsafeMutableRawPointer?) -> ChromiumClient? {
        ChromiumInterop.owner(ChromiumClient.self, of: raw)
    }

    nonisolated static func release(_ raw: UnsafeMutableRawPointer?) {
        ChromiumInterop.release(raw)
    }

    private static func browser(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<cef_browser_t>? {
        raw?.assumingMemoryBound(to: cef_browser_t.self)
    }

    nonisolated static func releaseBrowser(_ browser: UnsafeMutablePointer<cef_browser_t>?) {
        release(browser.map(UnsafeMutableRawPointer.init))
    }

    nonisolated static func releaseFrame(_ frame: UnsafeMutablePointer<cef_frame_t>?) {
        release(frame.map(UnsafeMutableRawPointer.init))
    }

    nonisolated static func string(_ value: UnsafePointer<cef_string_t>?) -> String {
        ChromiumInterop.string(value)
    }

    private nonisolated static func navigationType(
        _ transition: cef_transition_type_t
    ) -> WKNavigationType {
        let raw = transition.rawValue
        let source = raw & TT_SOURCE_MASK.rawValue
        if raw & TT_FORWARD_BACK_FLAG.rawValue != 0 {
            return .backForward
        }
        switch source {
        case TT_LINK.rawValue:
            return .linkActivated
        case TT_FORM_SUBMIT.rawValue:
            return .formSubmitted
        case TT_RELOAD.rawValue:
            return .reload
        default:
            return .other
        }
    }

    private func withBrowser(_ raw: UnsafeMutableRawPointer?, _ body: (ChromiumClient, ChromiumPage) -> Void) {
        guard !isClosed, let page, let client = Self.owner(raw) else { return }
        body(client, page)
    }

    func hold(_ pointer: UnsafeMutableRawPointer) {
        pendingCallbacks[UInt(bitPattern: pointer)] = UInt(bitPattern: pointer)
    }

    func finish(_ pointer: UnsafeMutableRawPointer) -> Bool {
        pendingCallbacks.removeValue(forKey: UInt(bitPattern: pointer)) != nil
    }

    func drop(_ pointer: UnsafeMutableRawPointer) {
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
    nonisolated func acquireRequestHandler() -> UnsafeMutablePointer<cef_request_handler_t>? {
        resourceStateLock.lock()
        defer { resourceStateLock.unlock() }
        guard let request = requestPointer else { return nil }
        ChromiumInterop.retain(UnsafeMutableRawPointer(request))
        return request
    }

    private nonisolated func detachRequestHandler() -> UnsafeMutablePointer<cef_request_handler_t>? {
        resourceStateLock.lock()
        let request = requestPointer
        requestPointer = nil
        resourceStateLock.unlock()
        return request
    }

    /// CEF owns the client reference while the browser is alive. Parent calls
    /// this after OnBeforeClose (or when materialization fails).
    func close() {
        guard !isClosed else { return }
        documentResponses.reset()
        nativeDocuments.removeAll()
        let request = detachRequestHandler()
        let resource = detachResourceHandler()
        isClosed = true
        for key in certificateCallbacks {
            if let address = pendingCallbacks[key],
               let raw = UnsafeMutableRawPointer(bitPattern: address) {
                let callback = raw.assumingMemoryBound(to: cef_callback_t.self)
                callback.pointee.cancel?(callback)
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
            framePointer.map(UnsafeMutableRawPointer.init),
            displayPointer.map(UnsafeMutableRawPointer.init),
            downloadPointer.map(UnsafeMutableRawPointer.init),
            dialogPointer.map(UnsafeMutableRawPointer.init),
            contextMenuPointer.map(UnsafeMutableRawPointer.init),
            jsDialogPointer.map(UnsafeMutableRawPointer.init),
            permissionPointer.map(UnsafeMutableRawPointer.init),
            clientPointer.map(UnsafeMutableRawPointer.init),
        ] { Self.release(pointer) }
        if let resource {
            Self.release(UnsafeMutableRawPointer(resource))
        }
        if let request {
            Self.release(UnsafeMutableRawPointer(request))
        }
        lifeSpanPointer = nil
        loadPointer = nil
        framePointer = nil
        displayPointer = nil
        downloadPointer = nil
        dialogPointer = nil
        contextMenuPointer = nil
        jsDialogPointer = nil
        permissionPointer = nil
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
            let request = detachRequestHandler()
            for pointer in [
                lifeSpanPointer.map(UnsafeMutableRawPointer.init),
                loadPointer.map(UnsafeMutableRawPointer.init),
                framePointer.map(UnsafeMutableRawPointer.init),
                displayPointer.map(UnsafeMutableRawPointer.init),
                downloadPointer.map(UnsafeMutableRawPointer.init),
                dialogPointer.map(UnsafeMutableRawPointer.init),
                contextMenuPointer.map(UnsafeMutableRawPointer.init),
                jsDialogPointer.map(UnsafeMutableRawPointer.init),
                permissionPointer.map(UnsafeMutableRawPointer.init),
                clientPointer.map(UnsafeMutableRawPointer.init),
            ] { Self.release(pointer) }
            if let resource {
                Self.release(UnsafeMutableRawPointer(resource))
            }
            if let request {
                Self.release(UnsafeMutableRawPointer(request))
            }
        }
    }

    // MARK: File chooser

    func presentFileDialog(
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

    func makePermissionHandler() {
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
                if let callback = UnsafeMutableRawPointer(bitPattern: callbackAddress) {
                    Self.release(callback)
                }
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
                guard Self.sameOrigin(origin, trusted.securityOrigin),
                      try await page.isLive(frame: trusted) else {
                    return self.cancelPermission(callback, media: true)
                }
                let allowed = await page.permissionDecision?(trusted, permissions) ?? false
                guard try await page.isLive(frame: trusted) else {
                    return self.cancelPermission(callback, media: true)
                }
                self.completePermission(callback, allow: allowed, mediaMask: mediaMask)
            } catch {
                self.cancelPermission(callback, media: true)
            }
        }
    }

    private func resolvePermissionPrompt(_ raw: UnsafeMutableRawPointer, frameURL: URL?, permissions: [WebPermission], unknown: Bool, promptID: UInt64) {
        hold(raw)
        guard !unknown, !permissions.isEmpty else { cancelPermission(raw, media: false); return }
        let callbackAddress = UInt(bitPattern: raw)
        ChromiumInterop.retain(raw)
        Task { @MainActor [weak self] in
            defer {
                if let callback = UnsafeMutableRawPointer(bitPattern: callbackAddress) {
                    Self.release(callback)
                }
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
                guard trusted.isMainFrame,
                      Self.sameOrigin(frameURL?.absoluteString ?? "", trusted.securityOrigin),
                      try await page.isLive(frame: trusted) else {
                    return self.cancelPermission(callback, media: false)
                }
                let allowed = await page.permissionDecision?(trusted, permissions) ?? false
                guard try await page.isLive(frame: trusted) else {
                    return self.cancelPermission(callback, media: false)
                }
                guard self.finish(callback) else { return }
                let cefCallback = callback.assumingMemoryBound(to: cef_permission_prompt_callback_t.self)
                cefCallback.pointee.cont?(cefCallback, allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY)
                self.drop(callback)
            } catch {
                self.cancelPermission(callback, media: false)
            }
        }
    }

    private func completePermission(_ raw: UnsafeMutableRawPointer, allow: Bool, mediaMask: UInt32) {
        guard finish(raw) else { return }
        let callback = raw.assumingMemoryBound(to: cef_media_access_callback_t.self)
        if allow {
            callback.pointee.cont?(callback, mediaMask)
        } else {
            callback.pointee.cancel?(callback)
        }
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

    static func sameOrigin(_ origin: String, _ trusted: BrowserSecurityOrigin) -> Bool {
        guard let url = URL(string: origin), let host = url.host(), let scheme = url.scheme else { return false }
        return scheme.caseInsensitiveCompare(trusted.protocol) == .orderedSame
            && host.caseInsensitiveCompare(trusted.host) == .orderedSame
            && PageFrameRegistry.portMatches(url: url, securityPort: trusted.port)
    }

    // MARK: Navigation, certificates and authentication

    /// Copy all CEF-owned values before the IO callback returns. Foundation
    /// supplies MIME/Content-Disposition filename parsing for both engines.
    nonisolated static func documentResponse(
        _ response: UnsafeMutablePointer<cef_response_t>,
        request: UnsafeMutablePointer<cef_request_t>
    ) -> HTTPURLResponse? {
        let resolved = ChromiumInterop.takeString(response.pointee.get_url?(response))
        let address = resolved.isEmpty ? ChromiumInterop.takeString(request.pointee.get_url?(request)) : resolved
        guard let url = URL(string: address) else { return nil }
        var headers: [String: String] = [:]
        if let map = cef_string_multimap_alloc() {
            defer { cef_string_multimap_free(map) }
            response.pointee.get_header_map?(response, map)
            for index in 0..<cef_string_multimap_size(map) {
                var key = cef_string_t()
                var value = cef_string_t()
                defer {
                    cef_string_utf16_clear(&key)
                    cef_string_utf16_clear(&value)
                }
                guard cef_string_multimap_key(map, index, &key) != 0,
                      cef_string_multimap_value(map, index, &value) != 0 else { continue }
                let name = string(&key).lowercased()
                let text = string(&value)
                headers[name] = headers[name].map { "\($0), \(text)" } ?? text
            }
        }
        let mime = ChromiumInterop.takeString(response.pointee.get_mime_type?(response))
        if !mime.isEmpty, headers["content-type"] == nil {
            headers["content-type"] = mime
        }
        return HTTPURLResponse(
            url: url, statusCode: Int(response.pointee.get_status?(response) ?? 0),
            httpVersion: nil, headerFields: headers
        )
    }

    func makeResourceHandler() {
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
        handler.pointee.on_resource_response = { handlerSelf, browser, frame, request, response in
            defer {
                ChromiumClient.releaseBrowser(browser)
                ChromiumClient.releaseFrame(frame)
                ChromiumClient.release(request.map(UnsafeMutableRawPointer.init))
                ChromiumClient.release(response.map(UnsafeMutableRawPointer.init))
            }
            guard let frame, frame.pointee.is_valid?(frame) == 1, frame.pointee.is_main?(frame) == 1,
                  let request, request.pointee.get_resource_type?(request) == RT_MAIN_FRAME,
                  let response,
                  let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)),
                  let copied = ChromiumClient.documentResponse(response, request: request)
            else { return 0 }
            Task { @MainActor [weak client] in
                guard let client, !client.isClosed,
                      let response = client.documentResponses.receive(copied) else { return }
                client.page?.didReceiveMainFrameResponse(response)
            }
            return 0
        }
        resourceStateLock.lock()
        resourcePointer = handler
        resourceStateLock.unlock()
    }

    func makeRequestHandler() {
        let handler = ChromiumInterop.allocate(cef_request_handler_t.self, owner: self)
        handler.pointee.get_resource_request_handler = { handlerSelf, browser, frame, request, _, _, _, disable in
            defer {
                ChromiumClient.releaseBrowser(browser)
                ChromiumClient.releaseFrame(frame)
                ChromiumClient.release(request.map(UnsafeMutableRawPointer.init))
            }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)),
                  let resource = client.acquireResourceHandler()
            else { return nil }
            disable?.pointee = 0
            return resource
        }
        handler.pointee.on_before_browse = { handlerSelf, browser, frame, request, userGesture, redirect in
            ChromiumClient.releaseBrowser(browser)
            // CEF supplies the navigated frame, not necessarily the initiator.
            // External handoffs bind only to an independently matched referrer frame.
            let sourceURL = URL(string: ChromiumInterop.takeString(request?.pointee.get_referrer_url?(request)))
            let transition = request?.pointee.get_transition_type?(request) ?? TT_EXPLICIT
            let isMain = frame?.pointee.is_main?(frame) == 1
            ChromiumClient.releaseFrame(frame)
            defer { ChromiumClient.release(request.map(UnsafeMutableRawPointer.init)) }
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 1 }
            let url = URL(string: ChromiumInterop.takeString(request?.pointee.get_url?(request)))
            guard let url else { return 1 }
            var navigationRequest = URLRequest(url: url)
            navigationRequest.httpMethod = ChromiumInterop.takeString(request?.pointee.get_method?(request))
            if let post = request?.pointee.get_post_data?(request) {
                defer { ChromiumClient.release(UnsafeMutableRawPointer(post)) }
                // Only presence is needed by the engine gate; CEF retains the submitted bytes.
                if post.pointee.get_element_count?(post) ?? 0 > 0 {
                    navigationRequest.httpBody = Data()
                }
            }
            let navigationType = ChromiumClient.navigationType(transition)
            return MainActor.assumeIsolated {
                guard !client.isClosed, let page = client.page else { return 1 }
                let sourceFrame = ExternalApp.staysInWebView(url) ? nil : page.sourceFrame(for: sourceURL)
                guard page.navigationDecision?(
                    navigationRequest, isMain, userGesture != 0, redirect != 0, navigationType, sourceURL, sourceFrame
                ) != false else { return 1 }
                guard ["http", "https", "file", "about", "data", "blob", "chrome-extension"].contains(url.scheme?.lowercased() ?? "") else { return 1 }
                if isMain {
                    page.willNavigate(navigationRequest, isRedirect: redirect != 0)
                }
                return 0
            }
        }
        handler.pointee.on_open_urlfrom_tab = { handlerSelf, browser, frame, targetURL, _, userGesture in
            ChromiumClient.releaseBrowser(browser)
            let sourceURL = frame?.pointee.is_valid?(frame) == 1
                ? URL(string: ChromiumInterop.takeString(frame?.pointee.get_url?(frame))) : nil
            ChromiumClient.releaseFrame(frame)
            let url = URL(string: ChromiumClient.string(targetURL))
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 1 }
            return MainActor.assumeIsolated {
                guard let page = client.page, !client.isClosed, let url else { return 1 }
                let sourceFrame = page.sourceFrame(for: sourceURL)
                page.openWindow?(url, userGesture != 0, sourceURL, sourceFrame)
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
                ChromiumClient.release(UnsafeMutableRawPointer(callback))
                return 0
            }
            let raw = UnsafeMutableRawPointer(callback)
            let challenge = CefAuthChallenge(
                origin: ChromiumClient.string(origin),
                isProxy: proxy != 0,
                host: ChromiumClient.string(host),
                port: Int(port),
                realm: ChromiumClient.string(realm),
                scheme: ChromiumClient.string(scheme)
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated { client.presentAuth(raw, challenge: challenge) }
            }
            return 1
        }
        handler.pointee.on_render_process_terminated = { handlerSelf, browser, _, _, _ in
            ChromiumClient.releaseBrowser(browser)
            guard let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                client.nativeDocuments.removeAll()
                client.page?.didTerminate()
            }
        }
        resourceStateLock.lock()
        requestPointer = handler
        resourceStateLock.unlock()
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
                allowsExceptions: page.context.settings.allowsCertificateExceptions,
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

}
