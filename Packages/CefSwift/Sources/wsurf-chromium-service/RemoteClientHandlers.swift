// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-4b: the CEF client of one windowless browser, and the rule that keeps its memory right (plan item 4a).
//
// CEF asks a client for each handler on any thread (the IO thread included) and retains what it gets, so the handlers must be
// constants that live as long as the client does. They are made once, before the browser exists, and held by
// `RemoteClientHandlers`, which is the client's owner: they are released only in its `deinit`, which runs when CEF destroys the
// client. Each handler owns a `BrowserBox`, not the browser, and the box points to the browser WEAKLY. So no path from the
// browser to its client leads back to the browser, whatever happens: a creation that fails, a close before the browser exists,
// and a browser that never reaches `on_before_close` all free the browser when the host lets go of it, and the client (and its
// handlers) when CEF lets go of that.

import CCef
import CefKit
import Foundation
import IOSurface
import os

/// How many browsers and handler sets are alive: `debug.stats` reports them, so a test can see that every path frees both.
enum ServiceCounters {
    static let browsers = OSAllocatedUnfairLock(initialState: 0)
    static let handlerSets = OSAllocatedUnfairLock(initialState: 0)
    /// Navigations the service cancelled itself, for a scheme outside ``CefRemote/allowedNavigationSchemes`` (`debug.stats`).
    static let refusedNavigations = OSAllocatedUnfairLock(initialState: 0)
    /// `nav.external` events the rate limit (or the address's size) kept back (D4-8; `debug.stats`).
    static let droppedExternalSchemes = OSAllocatedUnfairLock(initialState: 0)
    /// The service's own history reads it gave up on, because no answer came (D4-8, review F8; `debug.stats`).
    static let historyTimeouts = OSAllocatedUnfairLock(initialState: 0)
}

/// A main-frame navigation as `on_before_browse` saw it, beyond its address: the question to WSurf carries it (D4-8).
struct NavigationDetails: Sendable {
    var method = ""
    /// The address of the page that started it (the request's referrer), or empty.
    var source = ""
    /// CEF's `cef_transition_type_t`.
    var transition: Int64 = 0
    var hasPostData = false
}

/// What every handler of one browser owns in place of the browser.
final class BrowserBox: @unchecked Sendable {
    // The one line the lifetime tests' mutation changes (`weak` off): with a strong reference the browser, its client, the
    // handlers and this box form a cycle, and no path frees any of them.
    weak var browser: RemoteBrowser?
}

final class RemoteClientHandlers: @unchecked Sendable {
    let lifeSpan: UnsafeMutablePointer<cef_life_span_handler_t>
    let load: UnsafeMutablePointer<cef_load_handler_t>
    let display: UnsafeMutablePointer<cef_display_handler_t>
    let request: UnsafeMutablePointer<cef_request_handler_t>
    let render: UnsafeMutablePointer<cef_render_handler_t>
    let find: UnsafeMutablePointer<cef_find_handler_t>

    init(box: BrowserBox) {
        lifeSpan = RemoteClientHandlers.makeLifeSpan(box)
        load = RemoteClientHandlers.makeLoad(box)
        display = RemoteClientHandlers.makeDisplay(box)
        request = RemoteClientHandlers.makeRequest(box)
        render = RemoteClientHandlers.makeRender(box)
        find = RemoteClientHandlers.makeFind(box)
        ServiceCounters.handlerSets.withLock { $0 += 1 }
    }

    /// CEF destroyed the client: give up the +1 each factory returned (each handler then frees its box).
    deinit {
        for pointer in [UnsafeMutableRawPointer(lifeSpan), UnsafeMutableRawPointer(load), UnsafeMutableRawPointer(display),
                        UnsafeMutableRawPointer(request), UnsafeMutableRawPointer(render), UnsafeMutableRawPointer(find)] {
            Native.release(pointer)
        }
        ServiceCounters.handlerSets.withLock { $0 -= 1 }
    }

    /// The client of one browser, owning its handlers. The caller owns the +1 it comes with.
    static func makeClient(for box: BrowserBox) -> UnsafeMutablePointer<cef_client_t> {
        let handlers = RemoteClientHandlers(box: box)
        let client = Native.allocate(cef_client_t.self, owner: handlers)
        client.pointee.get_life_span_handler = { clientSelf in RemoteClientHandlers.handler(clientSelf) { $0.lifeSpan } }
        client.pointee.get_load_handler = { clientSelf in RemoteClientHandlers.handler(clientSelf) { $0.load } }
        client.pointee.get_display_handler = { clientSelf in RemoteClientHandlers.handler(clientSelf) { $0.display } }
        client.pointee.get_request_handler = { clientSelf in RemoteClientHandlers.handler(clientSelf) { $0.request } }
        client.pointee.get_render_handler = { clientSelf in RemoteClientHandlers.handler(clientSelf) { $0.render } }
        client.pointee.get_find_handler = { clientSelf in RemoteClientHandlers.handler(clientSelf) { $0.find } }
        return client
    }

    /// A handler to return to CEF, with the reference the caller takes. It reads a constant of the client's own holder, which
    /// lives as long as the client CEF is calling through, so nothing it reads can be released under it. Runs on any thread.
    private static func handler<T>(
        _ clientSelf: UnsafeMutablePointer<cef_client_t>?, _ pick: (RemoteClientHandlers) -> UnsafeMutablePointer<T>
    ) -> UnsafeMutablePointer<T>? {
        guard let handlers = Native.owner(RemoteClientHandlers.self, clientSelf.map(UnsafeMutableRawPointer.init)) else { return nil }
        let pointer = pick(handlers)
        Native.retain(UnsafeMutableRawPointer(pointer))
        return pointer
    }

    /// The browser a callback belongs to, if the host still has it. Callbacks run on the UI thread (the main thread).
    private static func browser<T>(_ handlerSelf: UnsafeMutablePointer<T>?) -> RemoteBrowser? {
        Native.owner(BrowserBox.self, handlerSelf.map(UnsafeMutableRawPointer.init))?.browser
    }

    private static func isMain(_ frame: UnsafeMutablePointer<cef_frame_t>?) -> Bool {
        frame?.pointee.is_main?(frame) == 1
    }

    /// What WSurf's navigation gate needs besides the address (`ChromiumClient.on_before_browse` reads the same from the request).
    /// The request is borrowed: the caller releases it.
    private static func navigationDetails(of request: UnsafeMutablePointer<cef_request_t>) -> NavigationDetails {
        var details = NavigationDetails()
        details.method = Native.take(request.pointee.get_method?(request))
        details.source = Native.take(request.pointee.get_referrer_url?(request))
        details.transition = Int64(request.pointee.get_transition_type?(request).rawValue ?? 0)
        if let post = request.pointee.get_post_data?(request) {
            // Only presence matters to the gate (a submitted request is never replayed in another engine); CEF keeps the bytes.
            details.hasPostData = (post.pointee.get_element_count?(post) ?? 0) > 0
            Native.release(UnsafeMutableRawPointer(post))
        }
        return details
    }

    // MARK: Life span

    private static func makeLifeSpan(_ box: BrowserBox) -> UnsafeMutablePointer<cef_life_span_handler_t> {
        let life = Native.allocate(cef_life_span_handler_t.self, owner: box)
        life.pointee.on_after_created = { handlerSelf, browser in
            guard let browser else { return }
            defer { Native.release(UnsafeMutableRawPointer(browser)) }
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else {
                // The host dropped this browser before CEF made it (a close before creation): nobody will close it, so close it
                // (after this callback: `Native.closeLater`).
                Native.closeLater(browser)
                return
            }
            MainActor.assumeIsolated { owner.didCreate(browser) }
        }
        life.pointee.do_close = { _, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            return 0
        }
        life.pointee.on_before_close = { handlerSelf, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.didClose() }
        }
        life.pointee.on_before_popup = { _, browser, frame, _, _, _, _, _, _, _, popupClient, _, extraInfo, _ in
            // Pop-ups are not part of phase 2 (plan §1.3: only on_before_browse asks WSurf): none opens.
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            Native.release(popupClient?.pointee.map(UnsafeMutableRawPointer.init))
            Native.release(extraInfo?.pointee.map(UnsafeMutableRawPointer.init))
            return 1
        }
        return life
    }

    // MARK: Load

    private static func makeLoad(_ box: BrowserBox) -> UnsafeMutablePointer<cef_load_handler_t> {
        let load = Native.allocate(cef_load_handler_t.self, owner: box)
        load.pointee.on_loading_state_change = { handlerSelf, browser, loading, back, forward in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.loadingStateChanged(loading: loading != 0, canGoBack: back != 0, canGoForward: forward != 0) }
        }
        load.pointee.on_load_start = { handlerSelf, browser, frame, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            let main = RemoteClientHandlers.isMain(frame)
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            guard main, let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.loadStarted() }
        }
        load.pointee.on_load_end = { handlerSelf, browser, frame, status in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            let main = RemoteClientHandlers.isMain(frame)
            let url = frame.map { Native.take($0.pointee.get_url?($0)) } ?? ""
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            guard main, let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.loadEnded(url: url, status: Int64(status)) }
        }
        load.pointee.on_load_error = { handlerSelf, browser, frame, code, text, failedURL in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            let main = RemoteClientHandlers.isMain(frame)
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            let message = Native.string(text)
            let url = Native.string(failedURL)
            guard main, let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.loadFailed(code: Int64(code.rawValue), text: message, url: url) }
        }
        return load
    }

    // MARK: Display

    private static func makeDisplay(_ box: BrowserBox) -> UnsafeMutablePointer<cef_display_handler_t> {
        let display = Native.allocate(cef_display_handler_t.self, owner: box)
        display.pointee.on_address_change = { handlerSelf, browser, frame, url in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            let main = RemoteClientHandlers.isMain(frame)
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            let address = Native.string(url)
            guard main, let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.addressChanged(address) }
        }
        display.pointee.on_title_change = { handlerSelf, browser, title in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            let text = Native.string(title)
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.titleChanged(text) }
        }
        display.pointee.on_loading_progress_change = { handlerSelf, browser, progress in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.progressChanged(progress) }
        }
        return display
    }

    // MARK: Request

    private static func makeRequest(_ box: BrowserBox) -> UnsafeMutablePointer<cef_request_handler_t> {
        let request = Native.allocate(cef_request_handler_t.self, owner: box)
        request.pointee.on_before_browse = { handlerSelf, browser, frame, nativeRequest, userGesture, isRedirect in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            let main = RemoteClientHandlers.isMain(frame)
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            let url = nativeRequest.map { Native.take($0.pointee.get_url?($0)) } ?? ""
            let details = nativeRequest.map { RemoteClientHandlers.navigationDetails(of: $0) } ?? NavigationDetails()
            Native.release(nativeRequest.map(UnsafeMutableRawPointer.init))
            // Every frame passes the scheme allowlist WSurf applies in process (`ChromiumClient`), here and without a round trip:
            // a URL that does not parse, or whose scheme is not listed, is cancelled whatever the host would answer. WSurf is told
            // (one way, rate limited) so that it can still offer the app that handles `mailto:` or `tel:` (D4-8, review D1).
            guard let target = URL(string: url), CefRemote.allowsNavigation(to: target) else {
                ServiceCounters.refusedNavigations.withLock { $0 += 1 }
                if let owner = RemoteClientHandlers.browser(handlerSelf) {
                    MainActor.assumeIsolated {
                        owner.refusedScheme(url: url, isMain: main, userGesture: userGesture != 0, source: details.source)
                    }
                }
                return 1
            }
            // Sub-frames with an allowed scheme are not asked about: the page's own scripts and ads load their frames, and a wait on
            // WSurf for each would cost the service up to a second apiece. (The scheme gate above still applies to them.) A browser
            // the host no longer has cancels (nobody could answer for it).
            guard main else { return 0 }
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return 1 }
            let allowed = MainActor.assumeIsolated {
                owner.mayNavigate(to: url, isRedirect: isRedirect != 0, userGesture: userGesture != 0, details: details)
            }
            return allowed ? 0 : 1
        }
        request.pointee.on_open_urlfrom_tab = { _, browser, frame, _, _, _ in
            // As pop-ups: a link opened in a new tab is not opened in phase 2.
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            return 1
        }
        request.pointee.on_render_process_terminated = { handlerSelf, browser, status, code, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.renderProcessTerminated(status: Int64(status.rawValue), code: Int64(code)) }
        }
        return request
    }

    // MARK: Render (geometry, and the frames of D4-7)

    private static func makeRender(_ box: BrowserBox) -> UnsafeMutablePointer<cef_render_handler_t> {
        let render = Native.allocate(cef_render_handler_t.self, owner: box)
        render.pointee.get_view_rect = { handlerSelf, browser, rect in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let rect else { return }
            let size = RemoteClientHandlers.browser(handlerSelf).map { owner in MainActor.assumeIsolated { owner.sizeDIP } } ?? CGSize(width: 1, height: 1)
            rect.pointee = cef_rect_t(x: 0, y: 0, width: Int32(max(1, size.width.rounded())), height: Int32(max(1, size.height.rounded())))
        }
        render.pointee.get_screen_info = { handlerSelf, browser, info in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let info, let owner = RemoteClientHandlers.browser(handlerSelf) else { return 0 }
            let (scale, size) = MainActor.assumeIsolated { (owner.scale, owner.sizeDIP) }
            info.pointee.device_scale_factor = Float(scale)
            info.pointee.depth = 24
            info.pointee.depth_per_component = 8
            info.pointee.is_monochrome = 0
            let rect = cef_rect_t(x: 0, y: 0, width: Int32(max(1, size.width.rounded())), height: Int32(max(1, size.height.rounded())))
            info.pointee.rect = rect
            info.pointee.available_rect = rect
            return 1
        }
        render.pointee.on_popup_show = { handlerSelf, browser, show in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.presenter.setPopup(visible: show != 0) }
        }
        render.pointee.on_popup_size = { handlerSelf, browser, rect in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let rect, let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            let frame = CGRect(x: CGFloat(rect.pointee.x), y: CGFloat(rect.pointee.y),
                               width: CGFloat(rect.pointee.width), height: CGFloat(rect.pointee.height))
            MainActor.assumeIsolated { owner.presenter.setPopup(rect: frame) }
        }
        render.pointee.on_paint = { handlerSelf, browser, type, _, _, buffer, width, height in
            let entry = Clock.nowNanoseconds
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let buffer, let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated {
                owner.presenter.present(pixels: buffer, width: Int(width), height: Int(height),
                                        element: type == PET_POPUP ? .popup : .view, entry: entry)
            }
        }
        render.pointee.on_accelerated_paint = { handlerSelf, browser, type, _, _, info in
            let entry = Clock.nowNanoseconds
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let info, let pointer = info.pointee.shared_texture_io_surface,
                  let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            // CEF's surface is borrowed for this callback only (CEF reuses it after): the presenter copies it before it returns.
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated {
                owner.presenter.present(surface: surface, element: type == PET_POPUP ? .popup : .view, entry: entry)
            }
        }
        return render
    }

    // MARK: Find

    private static func makeFind(_ box: BrowserBox) -> UnsafeMutablePointer<cef_find_handler_t> {
        let find = Native.allocate(cef_find_handler_t.self, owner: box)
        find.pointee.on_find_result = { handlerSelf, browser, identifier, count, _, active, final in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteClientHandlers.browser(handlerSelf) else { return }
            MainActor.assumeIsolated {
                owner.findResult(identifier: Int64(identifier), count: Int64(count), active: Int64(active), final: final != 0)
            }
        }
        return find
    }
}
