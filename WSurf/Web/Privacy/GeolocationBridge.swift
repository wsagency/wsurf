// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CoreLocation
import Foundation
import WebKit

@MainActor
final class GeolocationBridge: NSObject {
    static let shared = GeolocationBridge()

    nonisolated static let handlerName = "wsurfgeo"

    /// Resolves the page currently owned by a tab. The resolver is supplied by
    /// the browser coordinator so a retired page can never claim a request.
    var tabResolver: ((BrowserPage) -> BrowserTab?)?

    private static let world = WKContentWorld.page
    private let manager = CLLocationManager()

    private struct Request {
        weak var page: BrowserPage?
        let frame: BrowserFrame
        let jsID: Int
        let isWatch: Bool
        let origin: String
    }

    private var oneShots: [Request] = []
    private var watches: [Request] = []
    private var awaitingAuthorization: [Request] = []

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: - Installation

    @MainActor
    func install(in page: BrowserPage) {
        page.installScript(Self.scriptSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        page.addScriptMessageHandler(name: Self.handlerName, in: Self.world) { [weak self] message in
            guard let self, message.frameInfo.isMainFrame,
                  let parsed = Self.parse(message.body) else { return }
            self.handle(type: parsed.type, jsID: parsed.jsID, message: message)
        }
    }

    // MARK: - The page's side

    nonisolated static let scriptSource = """
        (function () {
          var send = globalThis.__wsurfSend;
          if (typeof send !== 'function' || globalThis.__wsurfGeo) { return; }
          var post = function (m) { send('wsurfgeo', m); };
          var nextId = 1;
          var pending = {};
          var geo = {
            getCurrentPosition: function (success, error, options) {
              var id = nextId++;
              pending[id] = { success: success, error: error };
              post({ type: 'get', id: id });
            },
            watchPosition: function (success, error, options) {
              var id = nextId++;
              pending[id] = { success: success, error: error, watch: true };
              post({ type: 'watch', id: id });
              return id;
            },
            clearWatch: function (id) {
              delete pending[id];
              post({ type: 'clear', id: id });
            }
          };
          Object.defineProperty(navigator, 'geolocation', { value: geo, configurable: true });
          window.__wsurfGeo = {
            position: function (id, coords, timestamp) {
              var p = pending[id];
              if (!p) { return; }
              if (!p.watch) { delete pending[id]; }
              try { p.success({ coords: coords, timestamp: timestamp }); } catch (e) {}
            },
            failure: function (id, code, message) {
              var p = pending[id];
              if (!p) { return; }
              if (!p.watch) { delete pending[id]; }
              if (p.error) {
                try {
                  p.error({ code: code, message: message,
                            PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
                } catch (e) {}
              }
            }
          };
        })();
        """

    // MARK: - Requests

    nonisolated static func parse(_ body: Any) -> (type: String, jsID: Int)? {
        guard let body = body as? [String: Any],
              let type = body["type"] as? String,
              let jsID = body["id"] as? Int
        else { return nil }
        return (type, jsID)
    }

    private func context(for message: BrowserScriptMessage) -> (BrowserTab, String)? {
        let frame = message.frameInfo
        guard frame.isMainFrame,
              let frameURL = frame.request.url,
              let tab = tabResolver?(message.page),
              tab.isMaterialised,
              tab.isPrivate == message.page.isPrivate else { return nil }
        let origin = SitePermissions.origin(for: frameURL)
        guard !origin.isEmpty,
              SitePermissions.isPotentiallyTrustworthy(frame.request.url),
              origin == SitePermissions.origin(for: message.page.url),
              origin == tab.permissions.origin,
              frame.securityOrigin == BrowserSecurityOrigin(url: frameURL)
        else { return nil }
        return (tab, origin)
    }

    private func isCurrent(_ request: Request) async -> Bool {
        guard let page = request.page,
              let frameURL = request.frame.request.url,
              let tab = tabResolver?(page),
              tab.isMaterialised,
              tab.isPrivate == page.isPrivate,
              tab.permissions.origin == request.origin,
              SitePermissions.isPotentiallyTrustworthy(request.frame.request.url),
              request.frame.securityOrigin == BrowserSecurityOrigin(url: frameURL),
              SitePermissions.origin(for: page.url) == request.origin,
              SitePermissions.origin(for: request.frame.request.url) == request.origin
        else { return false }

        if let chromium = page.chromium {
            return (try? await chromium.isLive(frame: request.frame)) == true
        }
        return page.webKit != nil && request.frame.webKit != nil
    }

    private func hasCurrentGrant(_ request: Request) -> Bool {
        guard let page = request.page,
              let frameURL = request.frame.request.url,
              let tab = tabResolver?(page),
              tab.isMaterialised,
              tab.isPrivate == page.isPrivate,
              tab.permissions.origin == request.origin,
              SitePermissions.origin(for: page.url) == request.origin,
              SitePermissions.origin(for: frameURL) == request.origin,
              SitePermissions.isPotentiallyTrustworthy(frameURL),
              request.frame.securityOrigin == BrowserSecurityOrigin(url: frameURL)
        else { return false }
        return tab.permissions.isGranted(.location)
    }

    private func matches(_ request: Request, page: BrowserPage) -> Bool {
        request.page === page || request.page == nil
    }

    private func matches(_ lhs: Request, _ rhs: Request) -> Bool {
        lhs.page === rhs.page
            && lhs.jsID == rhs.jsID
            && lhs.frame.documentID == rhs.frame.documentID
            && lhs.isWatch == rhs.isWatch
    }

    private func handle(type: String, jsID: Int, message: BrowserScriptMessage) {
        guard let (tab, origin) = context(for: message) else { return }
        let page = message.page
        let frame = message.frameInfo
        switch type {
        case "get", "watch":
            let isWatch = type == "watch"
            let request = Request(page: page, frame: frame, jsID: jsID, isWatch: isWatch, origin: origin)
            Task { @MainActor [weak self, weak tab] in
                guard let self, let tab,
                      await self.isCurrent(request) else { return }
                guard await tab.permissions.decide(.location) else {
                    await self.fail(request, code: 1, message: "Permission denied")
                    return
                }
                guard await self.isCurrent(request) else { return }
                self.begin(request)
            }
        case "clear":
            let removed = watches.filter {
                $0.page === page && $0.frame.documentID == frame.documentID && $0.jsID == jsID
            }
            watches.removeAll {
                $0.page === page && $0.frame.documentID == frame.documentID && $0.jsID == jsID
            }
            for request in removed {
                guard let page = request.page,
                      !watches.contains(where: { $0.page === page }) else { continue }
                tabResolver?(page)?.permissions.setLive(.location, false)
            }
            refreshLiveAndPower()
        default:
            break
        }
    }

    private func begin(_ request: Request) {
        guard let page = request.page,
              let tab = tabResolver?(page),
              tab.permissions.isGranted(.location) else {
            Task { @MainActor [weak self] in
                await self?.fail(request, code: 1, message: "Permission denied")
            }
            return
        }
        tab.onLocationRevoked = { [weak self, weak page] in
            guard let page else { return }
            self?.stopWatches(for: page)
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !awaitingAuthorization.contains(where: { matches($0, request) }) {
                awaitingAuthorization.append(request)
            }
            manager.requestWhenInUseAuthorization()
            return
        case .denied, .restricted:
            Task { @MainActor [weak self] in
                await self?.fail(request, code: 2, message: "Location is unavailable")
            }
            return
        default:
            break
        }

        if request.isWatch {
            watches.append(request)
        } else {
            oneShots.append(request)
        }
        refreshLiveAndPower()
        if request.isWatch, let last = manager.location {
            Task { @MainActor [weak self] in
                await self?.deliver(last, to: [request])
            }
        }
        if watches.isEmpty {
            manager.requestLocation()
        }
    }

    func stopWatches(for page: BrowserPage) {
        let revoked = oneShots.filter { matches($0, page: page) }
            + watches.filter { matches($0, page: page) }
            + awaitingAuthorization.filter { matches($0, page: page) }
        oneShots.removeAll { matches($0, page: page) }
        watches.removeAll { matches($0, page: page) }
        awaitingAuthorization.removeAll { matches($0, page: page) }
        tabResolver?(page)?.permissions.setLive(.location, false)
        refreshLiveAndPower()
        for request in revoked where request.page != nil {
            Task { @MainActor [weak self] in
                await self?.fail(request, code: 1, message: "Permission denied")
            }
        }
    }

    private func refreshLiveAndPower() {
        watches.removeAll { request in
            guard let page = request.page else { return true }
            return SitePermissions.origin(for: page.url) != request.origin
        }
        if watches.isEmpty {
            manager.stopUpdatingLocation()
        } else {
            manager.startUpdatingLocation()
        }
        var livePages = Set<ObjectIdentifier>()
        for watch in watches {
            guard let page = watch.page else { continue }
            livePages.insert(ObjectIdentifier(page))
            tabResolver?(page)?.permissions.setLive(.location, true)
        }
        for request in oneShots {
            guard let page = request.page,
                  !livePages.contains(ObjectIdentifier(page)) else { continue }
            tabResolver?(page)?.permissions.setLive(.location, false)
        }
    }

    private func dropWatch(_ request: Request) {
        watches.removeAll { matches($0, request) }
        refreshLiveAndPower()
    }

    // MARK: - Answers

    private func deliver(_ location: CLLocation, to requests: [Request]) async {
        for request in requests {
            guard await isCurrent(request), let page = request.page else {
                if request.isWatch {
                    dropWatch(request)
                }
                continue
            }
            guard hasCurrentGrant(request) else {
                if request.isWatch {
                    dropWatch(request)
                }
                await fail(request, code: 1, message: "Permission denied")
                continue
            }
            let coordinate = location.coordinate
            let coords: [String: Any] = [
                "latitude": coordinate.latitude,
                "longitude": coordinate.longitude,
                "accuracy": location.horizontalAccuracy,
                "altitude": location.altitude,
                "altitudeAccuracy": location.verticalAccuracy,
                "heading": location.course >= 0 ? location.course : NSNull(),
                "speed": location.speed >= 0 ? location.speed : NSNull(),
            ]
            guard hasCurrentGrant(request) else {
                if request.isWatch {
                    dropWatch(request)
                }
                await fail(request, code: 1, message: "Permission denied")
                continue
            }
            _ = try? await page.callAsyncJavaScript(
                "globalThis.__wsurfGeo?.position(id, coords, timestamp);",
                arguments: ["id": request.jsID, "coords": coords,
                            "timestamp": Int(location.timestamp.timeIntervalSince1970 * 1000), ],
                in: request.frame, contentWorld: Self.world
            )
        }
    }

    private func fail(_ request: Request, code: Int, message: String) async {
        guard await isCurrent(request), let page = request.page else { return }
        _ = try? await page.callAsyncJavaScript(
            "globalThis.__wsurfGeo?.failure(id, code, message);",
            arguments: ["id": request.jsID, "code": code, "message": message],
            in: request.frame, contentWorld: Self.world
        )
    }
}

// MARK: - CLLocationManagerDelegate

extension GeolocationBridge: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let parked = awaitingAuthorization
        awaitingAuthorization = []
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            let revoked = parked + oneShots + watches
            oneShots = []
            watches = []
            for request in revoked {
                if let page = request.page {
                    tabResolver?(page)?.permissions.setLive(.location, false)
                }
                Task { @MainActor [weak self] in
                    await self?.fail(request, code: 1, message: "Permission denied")
                }
            }
            refreshLiveAndPower()
            return
        }
        for request in parked {
            guard hasCurrentGrant(request) else {
                Task { @MainActor [weak self] in
                    await self?.fail(request, code: 1, message: "Permission denied")
                }
                continue
            }
            awaitingAuthorization.append(request)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard await self.isCurrent(request) else {
                    self.awaitingAuthorization.removeAll { self.matches($0, request) }
                    return
                }
                guard self.awaitingAuthorization.contains(where: { self.matches($0, request) }) else { return }
                self.awaitingAuthorization.removeAll { self.matches($0, request) }
                guard self.hasCurrentGrant(request) else {
                    await self.fail(request, code: 1, message: "Permission denied")
                    return
                }
                self.begin(request)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let waiting = oneShots
        oneShots = []
        Task { @MainActor [weak self] in
            await self?.deliver(latest, to: waiting)
            await self?.deliver(latest, to: self?.watches ?? [])
            self?.refreshLiveAndPower()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let denied = (error as? CLError)?.code == .denied
        let waiting = oneShots
        oneShots = []
        if denied {
            let revoked = waiting + watches
            watches = []
            for request in revoked {
                if let page = request.page {
                    tabResolver?(page)?.permissions.setLive(.location, false)
                }
                Task { @MainActor [weak self] in
                    await self?.fail(request, code: 1, message: "Permission denied")
                }
            }
            refreshLiveAndPower()
            return
        }
        for request in waiting {
            Task { @MainActor [weak self] in
                await self?.fail(request, code: 2, message: "Position unavailable")
            }
        }
        refreshLiveAndPower()
    }
}
