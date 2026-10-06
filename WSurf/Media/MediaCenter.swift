// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import os
import SwiftUI
import WebKit

@MainActor
@Observable
final class MediaModel {
    var title = ""
    var pageTitle = ""
    var trackTitle = ""
    var artist = ""
    var album = ""
    var isActive = false
    var isInNativePiP = false
    var hasVideo = false

    // MARK: - Transport state

    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var volume: Double = 1
    var isMuted = false
    var artworkURL: URL?
    var picturePage: BrowserPage?

    var playerViewportRect: CGRect?
    var controlledTabID: UUID?

    var isLive = false

    var progress: Double? {
        guard !isLive, duration > 0 else { return nil }
        return min(max(currentTime / duration, 0), 1)
    }
}

@MainActor
final class MediaCenter {
    let model = MediaModel()
    let watched = MediaModel()

    /// Disabling the dock leaves `watched` active so lyrics can still follow the current tab.
    var isEnabled = true {
        didSet {
            guard !isEnabled else { return }
            releaseControl()
        }
    }

    /// Disable video in the card when automatic Picture in Picture uses the floating window.
    var lendsPicture = true {
        didSet {
            guard !lendsPicture else { return }
            setPicture(nil)
        }
    }

    var onReturnedInline: ((BrowserPage) -> Void)?
    var onTabAudioChanged: ((BrowserPage, Bool) -> Void)?
    var onTabVideoChanged: ((BrowserPage, Bool) -> Void)?
    var onTabUnmuted: ((BrowserPage) -> Void)?
    var onPictureOutChanged: ((BrowserPage, Bool) -> Void)?
    var onControlledTabChanged: ((UUID?, UUID?) -> Void)?
    var onPictureChanged: (() -> Void)?

    nonisolated static var frameScriptSource: String {
        MediaScript.source
    }
    nonisolated static let frameScriptHandlerName = "wsurfpip"

    @MainActor
    func install(in page: BrowserPage) {
        page.installScript(MediaScript.source, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.frameScriptHandlerName, in: .page) { [weak self] message in
            guard let body = message.body as? String else { return }
            self?.receiveScriptMessage(body, from: message.page, isMainFrame: message.frameInfo.isMainFrame)
        }
    }

    func receiveScriptMessage(_ message: String, from page: BrowserPage, isMainFrame: Bool) {
        if message == "picture-in-picture" || message == "inline" {
            applyPresentationMode(message, from: page)
            return
        }
        if isMainFrame, message == "hello" {
            forgetPicture(page)
        }
        if message == "tabunmuted" {
            onTabUnmuted?(page)
            return
        }
        if let controlled = controlledPage, page === controlled {
            if isMainFrame, let playing = Self.audioReport(in: message) {
                onTabAudioChanged?(controlled, playing)
            }
            if isMainFrame, let hasVideo = Self.videoReport(in: message) {
                onTabVideoChanged?(controlled, hasVideo)
            }
            handleScriptMessage(message, from: controlled, isMainFrame: isMainFrame)
            return
        }
        if page === pipTargetPage,
           handlePiPMessage(message, from: page, isMainFrame: isMainFrame) { return }
        guard isMainFrame else { return }
        if let playing = Self.audioReport(in: message) {
            onTabAudioChanged?(page, playing)
        }
        if let hasVideo = Self.videoReport(in: message) {
            onTabVideoChanged?(page, hasVideo)
        }
        if page === watchedPage {
            applyWatched(message)
        }
    }

    // MARK: - The tab you are looking at

    func watch(page: BrowserPage, title: String, tabID: UUID, artwork: URL?) {
        guard watchedPage !== page else { return }
        watchedPage = page
        watched.artworkURL = artwork
        watched.controlledTabID = tabID
        watched.pageTitle = title
        watched.trackTitle = ""
        watched.artist = ""
        watched.album = ""
        watched.title = title
        watched.currentTime = 0
        watched.duration = 0
        watched.isLive = false
        watched.isPlaying = true
        watched.isActive = true
        Self.post("wsurf-resend", to: page)
    }

    func unwatch() {
        guard watchedPage != nil else { return }
        watchedPage = nil
        watched.controlledTabID = nil
        watched.artworkURL = nil
        watched.title = ""
        watched.pageTitle = ""
        watched.trackTitle = ""
        watched.artist = ""
        watched.album = ""
        watched.isActive = false
    }

    private func applyWatched(_ message: String) {
        if message == "hello" {
            watched.currentTime = 0
            watched.duration = 0
            watched.isLive = false
            return
        }
        if message.hasPrefix("state:") {
            guard let fields = Self.fields(in: String(message.dropFirst("state:".count))) else { return }
            applyTiming(fields, to: watched)
            return
        }
        if message.hasPrefix("meta:") {
            applyMetadata(String(message.dropFirst("meta:".count)), to: watched)
            return
        }
        if message == "ended" {
            watched.isPlaying = false
        }
    }

    // MARK: - The tab in the dock

    func controlTab(
        page: BrowserPage,
        title: String,
        tabID: UUID,
        isPlaying: Bool = true,
        artwork: URL?
    ) {
        guard isEnabled, controlledTabID != tabID || controlledPage !== page else { return }
        let previous = controlledTabID
        setPicture(nil)
        model.playerViewportRect = nil
        model.controlledTabID = tabID
        controlledPage = page
        if previous != tabID {
            onControlledTabChanged?(previous, tabID)
        }
        model.artworkURL = artwork
        artworkIsGuess = artwork == nil
        model.pageTitle = title
        model.trackTitle = ""
        model.artist = ""
        model.album = ""
        model.title = title.isEmpty ? String(localized: "Now Playing") : title
        model.isInNativePiP = nativePiPPage === page
        model.hasVideo = false
        model.isPlaying = isPlaying
        model.isLive = false
        model.currentTime = 0
        model.duration = 0
        model.isActive = true
        needsReveal = true
        Self.post("wsurf-resend", to: page)
    }

    func releaseControl() {
        guard let previous = controlledTabID else { return }
        setPicture(nil)
        model.isInNativePiP = false
        model.hasVideo = false
        model.playerViewportRect = nil
        model.controlledTabID = nil
        controlledPage = nil
        onControlledTabChanged?(previous, nil)
        model.artworkURL = nil
        model.pageTitle = ""
        model.trackTitle = ""
        model.artist = ""
        model.album = ""
        model.isActive = false
        needsReveal = true
        Pipeline.log.notice("media: released tab playback control")
    }

    func pageDidReset(_ page: BrowserPage) {
        forgetPicture(page)
        if page === watchedPage {
            watched.currentTime = 0
            watched.duration = 0
            watched.isLive = false
        }
        guard page === controlledPage else { return }
        forgetControlledPage()
        dropDockIfThePageStaysQuiet(page)
    }

    private func dropDockIfThePageStaysQuiet(_ page: BrowserPage) {
        controlledPageResets += 1
        let reset = controlledPageResets
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  reset == controlledPageResets,
                  page === controlledPage,
                  !model.isPlaying
            else { return }
            releaseControl()
        }
    }

    @ObservationIgnored private var controlledPageResets = 0

    private func forgetControlledPage() {
        setPicture(nil)
        model.hasVideo = false
        model.pageTitle = ""
        model.trackTitle = ""
        model.artist = ""
        model.album = ""
        model.title = String(localized: "Now Playing")
        model.artworkURL = nil
        artworkIsGuess = true
        model.playerViewportRect = nil
        model.currentTime = 0
        model.duration = 0
        model.isLive = false
        model.isPlaying = false
        needsReveal = true
    }

    private func setPicture(_ page: BrowserPage?) {
        guard model.picturePage !== page else { return }
        model.picturePage = page
        onPictureChanged?()
    }

    var controlledTabID: UUID? {
        model.controlledTabID
    }
    private weak var controlledPage: BrowserPage?
    private weak var watchedPage: BrowserPage?
    private weak var pipTargetPage: BrowserPage?
    private var needsReveal = true

    var pictureCrop: CGRect? {
        guard let page = model.picturePage,
              let rect = model.playerViewportRect else { return nil }
        return MediaCropMath.visibleCrop(
            viewportRect: rect,
            viewBounds: page.bounds,
            topInset: 0
        )
    }
    private var artworkIsGuess = true

    nonisolated static func poster(forPage urlString: String) -> URL? {
        guard let url = URL(string: urlString), let host = url.host()?.lowercased() else { return nil }
        let path = url.pathComponents.dropFirst()

        if host.contains("twitch.tv") {
            guard path.count == 1, let login = path.first,
                  !login.isEmpty,
                  login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            else { return nil }
            return URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_\(login.lowercased())-440x248.jpg")
        }

        var id: String?
        if host.contains("youtube.com") {
            id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "v" }?.value
        } else if host.contains("youtu.be") {
            id = path.first
        }
        guard let id, !id.isEmpty else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }

    func close() {
        guard model.isActive else { return }
        send("wsurf-pause")
        releaseControl()
    }

    // MARK: - Transport

    func playPause() {
        model.isPlaying.toggle()
        send(model.isPlaying ? "wsurf-play" : "wsurf-pause")
    }

    func skip(by seconds: Double) {
        if model.duration > 0 {
            model.currentTime = min(max(model.currentTime + seconds, 0), model.duration)
        }
        send("wsurf-seek:\(seconds)")
    }

    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        if model.duration > 0 {
            model.currentTime = model.duration * clamped
        }
        send("wsurf-seekto:\(clamped)")
    }

    func setVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 1)
        model.volume = clamped
        model.isMuted = clamped <= 0
        send("wsurf-volume:\(clamped)")
    }

    func toggleMute() {
        model.isMuted.toggle()
        send("wsurf-mute:\(model.isMuted ? 1 : 0)")
    }

    private func send(_ message: String) {
        guard let controlledPage else { return }
        Self.post(message, to: controlledPage)
    }

    static func seek(to seconds: Double, on page: BrowserPage) {
        post("wsurf-seekabs:\(seconds)", to: page)
    }

    static func setMuted(_ muted: Bool, on page: BrowserPage) {
        post("wsurf-mute:\(muted ? 1 : 0)", to: page)
    }
    private static func post(_ message: String, to page: BrowserPage) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]),
              let escaped = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            _ = try? await page.evaluateJavaScript("""
            window.postMessage(\(escaped), '*');
            Array.prototype.forEach.call(document.querySelectorAll('iframe'), function (f) {
              try { f.contentWindow.postMessage(\(escaped), '*'); } catch (e) {}
            });
            """)
        }
    }

    nonisolated private static func audioReport(in message: String) -> Bool? {
        guard message.hasPrefix("audio:") else { return nil }
        return message.hasSuffix("1")
    }

    nonisolated private static func videoReport(in message: String) -> Bool? {
        guard message.hasPrefix("video:") else { return nil }
        return message.hasSuffix("1")
    }

    var canToggleNativePiP: Bool {
        controlledPage?.webKit != nil
    }

    var nativePiPUnavailableReason: LocalizedStringResource? {
        guard model.hasVideo, let page = controlledPage, page.webKit == nil else { return nil }
        return "Picture in Picture is unavailable for Chromium pages"
    }

    func toggleNativePiP() {
        guard let controlledPage, controlledPage.webKit != nil else {
            Pipeline.log.notice("media: native Picture in Picture is unavailable for Chromium")
            return
        }
        togglePictureInPicture(for: controlledPage)
    }

    func isPictureOut(_ page: BrowserPage) -> Bool {
        nativePiPPage === page
    }

    func exitPictureInPicture(for page: BrowserPage) {
        guard let webKit = page.webKit, nativePiPPage === page else { return }
        returnAskedAt = Date()
        if Self.pictureInPictureActive(webKit) == true, Self.togglePictureInPicture(on: webKit) {
            forgetGestureRequest()
            return
        }
        Self.post("wsurf-pip-exit", to: page)
        if Self.pictureInPictureActive(webKit) == false {
            setPictureInPicture(false, for: page)
        }
    }

    func togglePictureInPicture(for page: BrowserPage) {
        guard let webKit = page.webKit else {
            Pipeline.log.notice("media: native Picture in Picture is unavailable for Chromium")
            return
        }
        if nativePiPPage === page {
            exitPictureInPicture(for: page)
            return
        }
        if Self.canTogglePictureInPicture(webKit), Self.togglePictureInPicture(on: webKit) {
            forgetGestureRequest()
            return
        }
        pipRequestedAt = Date()
        pipTargetPage = page
        pipTargetRect = nil
        Self.post("wsurf-rect", to: page)
        Self.post("wsurf-pip", to: page)
    }

    func requestNativePiP(on page: BrowserPage) {
        guard let webKit = page.webKit else {
            Pipeline.log.notice("media: automatic native Picture in Picture is unavailable for Chromium")
            return
        }
        if Self.canTogglePictureInPicture(webKit), Self.togglePictureInPicture(on: webKit) {
            forgetGestureRequest()
            return
        }
        pipRequestedAt = Date()
        pipTargetPage = page
        pipTargetRect = nil
        Self.post("wsurf-rect", to: page)
        Self.post("wsurf-pip-auto", to: page)
    }

    private var pipRequestedAt: Date?
    private var pipTargetRect: CGRect?
    private var pipGesturePoint: CGPoint?
    private weak var nativePiPPage: BrowserPage?
    private var pictureWentOutAt: Date?
    private var returnAskedAt: Date?
    private static let gestureWindow: TimeInterval = 10
    private static let settleAfterLeaving: TimeInterval = 1
    private static let returnWindow: TimeInterval = 5

    private func forgetGestureRequest() {
        pipRequestedAt = nil
        pipTargetPage = nil
        pipTargetRect = nil
        pipGesturePoint = nil
    }

    private func forgetPicture(_ page: BrowserPage) {
        guard nativePiPPage === page else { return }
        nativePiPPage = nil
        if pipTargetPage === page {
            forgetGestureRequest()
        }
        if page === controlledPage {
            model.isInNativePiP = false
        }
        returnAskedAt = nil
        onPictureOutChanged?(page, false)
    }

    func notePictureReturnAsk(for page: BrowserPage) -> Bool {
        guard nativePiPPage === page else { return false }
        if let wentOut = pictureWentOutAt,
           Date().timeIntervalSince(wentOut) < Self.settleAfterLeaving {
            return false
        }
        returnAskedAt = Date()
        return true
    }

    private func returnWasAsked(for page: BrowserPage) -> Bool {
        guard let asked = returnAskedAt else { return false }
        return Date().timeIntervalSince(asked) < Self.returnWindow
    }
    private func applyPresentationMode(_ message: String, from page: BrowserPage) {
        if message == "inline" { returnAskedAt = Date() }
        setPictureInPicture(message == "picture-in-picture", for: page)
    }

    func setPictureInPicture(_ isNative: Bool, for page: BrowserPage) {
        guard !isNative || page.webKit != nil else {
            Pipeline.log.notice("media: ignored native Picture in Picture report from Chromium")
            return
        }
        if page === controlledPage {
            model.isInNativePiP = isNative
        }
        if isNative {
            guard nativePiPPage !== page else { return }
            if let previous = nativePiPPage {
                forgetPicture(previous)
            }
            pipRequestedAt = nil
            nativePiPPage = page
            pictureWentOutAt = Date()
            onPictureOutChanged?(page, true)
            return
        }
        guard nativePiPPage === page else { return }
        let wasAsked = returnWasAsked(for: page)
        forgetPicture(page)
        returnAskedAt = nil
        if wasAsked {
            onReturnedInline?(page)
        }
    }

    private func handlePiPMessage(
        _ message: String,
        from page: BrowserPage,
        isMainFrame: Bool
    ) -> Bool {
        if isMainFrame, message.hasPrefix("rect:") {
            pipTargetRect = Self.rect(in: String(message.dropFirst("rect:".count)))
            return false
        }
        if isMainFrame, message.hasPrefix("pipat:") {
            pipGesturePoint = Self.point(in: String(message.dropFirst("pipat:".count)))
            return true
        }
        if message == "diag:need-gesture" {
            answerGestureRequest(on: page)
            return true
        }
        if message.hasPrefix("diag:") {
            Pipeline.log.notice("Media diagnostic received")
            return true
        }
        return false
    }

    private func answerGestureRequest(on page: BrowserPage) {
        guard let asked = pipRequestedAt,
              Date().timeIntervalSince(asked) < Self.gestureWindow,
              let webKit = page.webKit
        else {
            Pipeline.log.notice("media: unsolicited gesture request ignored")
            return
        }
        if let cssPoint = pipGesturePoint {
            pipGesturePoint = nil
            synthesizeGestureClick(on: webKit, atPagePoint: cssPoint)
        } else {
            let rect = page === controlledPage ? model.playerViewportRect : pipTargetRect
            synthesizeGestureClick(on: webKit, viewportRect: rect)
        }
    }

    nonisolated private static func point(in payload: String) -> CGPoint? {
        let parts = payload.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Script messages

    private func handleScriptMessage(_ message: String, from source: BrowserPage, isMainFrame: Bool) {
        if message == "hello" {
            if isMainFrame {
                forgetControlledPage()
            }
            return
        }
        if message.hasPrefix("state:") {
            applyState(String(message.dropFirst("state:".count)), from: source)
            return
        }
        if message.hasPrefix("rect:") {
            guard isMainFrame else { return }
            applyRect(String(message.dropFirst("rect:".count)))
            return
        }
        if message == "ended" {
            model.isPlaying = false
        } else if message.hasPrefix("pipat:"), isMainFrame {
            pipGesturePoint = Self.point(in: String(message.dropFirst("pipat:".count)))
        } else if message.hasPrefix("meta:") {
            applyMetadata(String(message.dropFirst("meta:".count)), to: model)
        } else if message == "diag:need-gesture" {
            answerGestureRequest(on: source)
        } else if message.hasPrefix("diag:") {
            Pipeline.log.notice("Media diagnostic received")
        }
    }

    private func applyState(_ json: String, from source: BrowserPage) {
        guard let fields = Self.fields(in: json) else { return }
        if source === controlledPage {
            let hasVideo = (fields["w"] ?? 0) > 0
            model.hasVideo = hasVideo
            if hasVideo, lendsPicture {
                setPicture(source)
                if needsReveal {
                    needsReveal = false
                    Self.post("wsurf-reveal", to: source)
                }
            }
        }
        applyTiming(fields, to: model)
    }

    nonisolated private static func fields(in json: String) -> [String: Double]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Double]
    }

    private func applyTiming(_ fields: [String: Double], to target: MediaModel) {
        let isLive = fields["l"] == 1
        if let time = fields["t"], abs(time - target.currentTime) > 0.05 {
            target.currentTime = time
        }
        if let duration = fields["d"], duration > 0, duration != target.duration {
            target.duration = duration
        }
        if isLive {
            if !target.isLive {
                target.isLive = true
            }
        } else if target.isLive, let duration = fields["d"], duration > 0 {
            target.isLive = false
        }
        if let playing = fields["p"] {
            let isPlaying = playing == 1
            if isPlaying != target.isPlaying {
                target.isPlaying = isPlaying
            }
        }
        if let volume = fields["v"], abs(volume - target.volume) > 0.005 {
            target.volume = volume
        }
        if let muted = fields["m"] {
            let isMuted = muted == 1
            if isMuted != target.isMuted {
                target.isMuted = isMuted
            }
        }
    }

    private func applyRect(_ json: String) {
        guard !json.isEmpty else {
            if model.playerViewportRect != nil {
                model.playerViewportRect = nil
            }
            return
        }
        guard let rect = Self.rect(in: json), rect != model.playerViewportRect else { return }
        model.playerViewportRect = rect
    }

    nonisolated private static func rect(in json: String) -> CGRect? {
        guard let data = json.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = fields["x"], let y = fields["y"],
              let width = fields["w"], let height = fields["h"],
              width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func applyMetadata(_ json: String, to target: MediaModel) {
        guard let data = json.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }

        let track = fields["t"] ?? ""
        let artist = fields["a"] ?? ""
        let album = fields["al"] ?? ""
        if target.trackTitle != track {
            target.trackTitle = track
        }
        if target.artist != artist {
            target.artist = artist
        }
        if target.album != album {
            target.album = album
        }
        if !track.isEmpty {
            target.title = artist.isEmpty ? track : "\(track) — \(artist)"
        }

        guard let art = fields["art"], let url = URL(string: art),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return }
        let isGuess = fields["g"] == "1"
        if target === model {
            guard !isGuess || artworkIsGuess || model.artworkURL == nil else { return }
            artworkIsGuess = isGuess
        }
        if url != target.artworkURL {
            target.artworkURL = url
        }
    }

    private func synthesizeGestureClick(on webView: WKWebView, atPagePoint cssPoint: CGPoint) {
        let bounds = webView.bounds
        let raw = NSPoint(
            x: cssPoint.x,
            y: cssPoint.y + webView.obscuredContentInsets.top
        )
        let point = NSPoint(
            x: min(max(raw.x, bounds.minX + 1), bounds.maxX - 1),
            y: min(max(raw.y, bounds.minY + 1), bounds.maxY - 1)
        )
        deliverGestureClick(on: webView, at: point)
    }

    private func synthesizeGestureClick(on webView: WKWebView, viewportRect: CGRect?) {
        let point: NSPoint
        if let rect = viewportRect,
           let crop = MediaCropMath.visibleCrop(
               viewportRect: rect,
               viewBounds: webView.bounds,
               topInset: webView.obscuredContentInsets.top
           ) {
            point = NSPoint(x: crop.midX, y: crop.midY)
        } else {
            point = NSPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        }
        deliverGestureClick(on: webView, at: point)
    }

    private func deliverGestureClick(on webView: WKWebView, at point: NSPoint) {
        guard let window = webView.window else {
            Pipeline.log.notice("media: no hosting window for gesture click")
            return
        }
        let windowPoint = webView.convert(point, to: nil)
        func mouseEvent(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }
        if let down = mouseEvent(.leftMouseDown) {
            webView.mouseDown(with: down)
        }
        if let up = mouseEvent(.leftMouseUp) {
            webView.mouseUp(with: up)
        }
    }

    // MARK: - WebKit switches (all diagnosed via the diag log)

    nonisolated private static let canToggleSelector = Selector(("_canTogglePictureInPicture"))
    nonisolated private static let toggleSelector = Selector(("_togglePictureInPicture"))
    nonisolated private static let isActiveSelector = Selector(("_isPictureInPictureActive"))

    nonisolated static func canTogglePictureInPicture(_ webView: WKWebView) -> Bool {
        answersTrue(canToggleSelector, on: webView)
    }

    nonisolated static func pictureInPictureActive(_ webView: WKWebView) -> Bool? {
        guard webView.responds(to: isActiveSelector) else { return nil }
        return answersTrue(isActiveSelector, on: webView)
    }

    @discardableResult
    nonisolated static func togglePictureInPicture(on webView: WKWebView) -> Bool {
        guard webView.responds(to: toggleSelector) else {
            Pipeline.log.notice("media: no toggle SPI, falling back to a synthesized gesture")
            return false
        }
        webView.perform(toggleSelector)
        return true
    }

    nonisolated private static func answersTrue(_ selector: Selector, on webView: WKWebView) -> Bool {
        guard webView.responds(to: selector), let method = webView.method(for: selector) else {
            return false
        }
        typealias Answer = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Answer.self)(webView, selector)
    }

    static func enablePictureInPicture(on preferences: WKPreferences) {
        if preferences.responds(to: Selector(("_setAllowsPictureInPictureMediaPlayback:"))) {
            preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        enablePiPFeatureFlags(on: preferences)
    }

    private static func enablePiPFeatureFlags(on preferences: WKPreferences) {
        let featuresSelector = Selector(("_features"))
        let setSelector = Selector(("_setEnabled:forFeature:"))
        guard (WKPreferences.self as AnyObject).responds(to: featuresSelector),
              preferences.responds(to: setSelector),
              let result = (WKPreferences.self as AnyObject).perform(featuresSelector),
              let features = result.takeUnretainedValue() as? [AnyObject],
              let method = preferences.method(for: setSelector)
        else {
            Pipeline.log.notice("media: feature-flag SPI unavailable, native PiP off")
            return
        }

        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let setEnabled = unsafeBitCast(method, to: SetEnabled.self)

        for feature in features {
            let key = (feature.value(forKey: "key") as? String) ?? ""
            let lowered = key.lowercased()
            guard lowered.contains("pictureinpicture") || lowered.contains("presentationmode") else {
                continue
            }
            setEnabled(preferences, setSelector, true, feature)
        }
    }
}

enum MediaRoster {
    static func isCandidate(
        isPlayingAudio: Bool,
        isMuted: Bool,
        isInternalPage: Bool,
        isActive: Bool,
        isVisibleInSplit: Bool,
        isDocked: Bool
    ) -> Bool {
        guard !isInternalPage, !isActive, !isVisibleInSplit else { return false }
        if isDocked {
            return true
        }
        return isPlayingAudio && !isMuted
    }

    static func isPickerItem(
        isPlayingAudio: Bool,
        isMuted: Bool,
        isInternalPage: Bool,
        isActive: Bool,
        isVisibleInSplit: Bool,
        isDocked: Bool,
        hasPlayed: Bool
    ) -> Bool {
        isCandidate(
            isPlayingAudio: isPlayingAudio || hasPlayed,
            isMuted: isMuted,
            isInternalPage: isInternalPage,
            isActive: isActive,
            isVisibleInSplit: isVisibleInSplit,
            isDocked: isDocked
        )
    }

    /// Keep lyrics visible after the current page pauses or mutes.
    static func isLyricsSource(
        isPlayingAudio: Bool,
        hasPlayed: Bool,
        isInternalPage: Bool,
        isDeferred: Bool
    ) -> Bool {
        guard !isInternalPage, !isDeferred else { return false }
        return isPlayingAudio || hasPlayed
    }

    static func lyricsOwner(
        pinned: UUID?,
        active: UUID?,
        docked: UUID?,
        candidates: [UUID]
    ) -> UUID? {
        for choice in [pinned, active, docked] {
            if let choice, candidates.contains(choice) {
                return choice
            }
        }
        return nil
    }

    static func pictureTarget(
        active: UUID?,
        isActivePlaying: Bool,
        docked: UUID?,
        isDockedPlaying: Bool
    ) -> UUID? {
        if let active, isActivePlaying {
            return active
        }
        return isDockedPlaying ? docked : nil
    }

    static func successor(to previous: UUID, in roster: [UUID]) -> UUID? {
        guard let index = roster.firstIndex(of: previous) else { return roster.first }
        guard roster.count > 1 else { return nil }
        return roster[(index + 1) % roster.count]
    }
}
