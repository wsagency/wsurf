// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import os
import UserNotifications
import WebKit

@MainActor
final class NotificationBridge: NSObject {
    static let shared = NotificationBridge()

    nonisolated static let handlerName = "wsurfnotify"

    /// Resolves the page currently owned by a tab. The resolver is supplied by
    /// the browser coordinator so a retired page can never claim a request.
    var tabResolver: ((BrowserPage) -> BrowserTab?)?

    private static let world = WKContentWorld.page

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Installation

    @MainActor
    func install(in page: BrowserPage) {
        page.installScript(Self.scriptSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        page.addScriptMessageHandler(name: Self.handlerName, in: Self.world) { [weak self] message in
            guard let self, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any] else { return }
            self.handle(body, message: message)
        }
    }

    // MARK: - The page's side

    nonisolated static let scriptSource = """
        (function () {
          var send = globalThis.__wsurfSend;
          if (typeof send !== 'function' || globalThis.__wsurfNotify) { return; }
          var post = function (m) { send('wsurfnotify', m); };
          var nextId = 1;
          var permission = 'default';
          var pending = {};
          function WSurfNotification(title, options) {
            options = options || {};
            this.title = String(title);
            this.body = options.body ? String(options.body) : '';
            this.tag = options.tag ? String(options.tag) : '';
            this.onclick = null;
            this.onerror = null;
            post({ type: 'show', id: 0, title: this.title, body: this.body, tag: this.tag });
          }
          WSurfNotification.prototype.close = function () {};
          Object.defineProperty(WSurfNotification, 'permission', {
            get: function () { return permission; }
          });
          WSurfNotification.requestPermission = function (callback) {
            var id = nextId++;
            return new Promise(function (resolve) {
              pending[id] = function (value) {
                if (callback) { try { callback(value); } catch (e) {} }
                resolve(value);
              };
              post({ type: 'request', id: id });
            });
          };
          window.Notification = WSurfNotification;
          window.__wsurfNotify = {
            setPermission: function (value) {
              if (value === 'granted' || value === 'denied' || value === 'default') {
                permission = value;
              }
            },
            resolve: function (id, value) {
              if (value === 'granted' || value === 'denied') { permission = value; }
              var f = pending[id];
              delete pending[id];
              if (f) { f(value); }
            }
          };
          post({ type: 'hello', id: 0 });
        })();
        """

    // MARK: - Requests

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
    private func isCurrent(page: BrowserPage, frame: BrowserFrame, origin: String) async -> Bool {
        guard let tab = tabResolver?(page),
              let frameURL = frame.request.url,
              tab.isMaterialised,
              tab.isPrivate == page.isPrivate,
              tab.permissions.origin == origin,
              SitePermissions.isPotentiallyTrustworthy(frame.request.url),
              frame.securityOrigin == BrowserSecurityOrigin(url: frameURL),
              SitePermissions.origin(for: page.url) == origin,
              SitePermissions.origin(for: frame.request.url) == origin
        else { return false }
        if let chromium = page.chromium {
            return (try? await chromium.isLive(frame: frame)) == true
        }
        return page.webKit != nil && frame.webKit != nil
    }

    private func handle(_ body: [String: Any], message: BrowserScriptMessage) {
        guard let type = body["type"] as? String,
              let (tab, origin) = context(for: message) else { return }
        let page = message.page
        let frame = message.frameInfo
        switch type {
        case "hello":
            let state: String = if tab.permissions.isGranted(.notifications) {
                "granted"
            } else if tab.permissions.menuPolicy(for: .notifications) == .deny {
                "denied"
            } else {
                "default"
            }
            Task { @MainActor [weak self] in
                guard let self, await self.isCurrent(page: page, frame: frame, origin: origin) else { return }
                await self.push(permission: state, to: page, frame: frame)
            }
        case "request":
            guard let jsID = body["id"] as? Int else { return }
            Task { @MainActor [weak self, weak tab] in
                guard let self, let tab,
                      await self.isCurrent(page: page, frame: frame, origin: origin) else { return }
                let outcome = await tab.permissions.outcome(.notifications)
                var answer: String
                switch outcome {
                case .granted:
                    let allowed = (try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])) ?? false
                    answer = allowed ? "granted" : "denied"
                case .denied:
                    answer = "denied"
                case .undecided:
                    answer = "default"
                }
                guard await self.isCurrent(page: page, frame: frame, origin: origin) else { return }
                await self.resolve(jsID, with: answer, in: page, frame: frame)
            }
        case "show":
            guard tab.permissions.isGranted(.notifications) else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      await self.isCurrent(page: page, frame: frame, origin: origin) else { return }
                guard await self.systemAuthorizationIsGranted(),
                      await self.isCurrent(page: page, frame: frame, origin: origin) else { return }
                await self.deliver(
                    title: body["title"] as? String ?? "",
                    text: body["body"] as? String ?? "",
                    tag: body["tag"] as? String ?? "",
                    from: tab
                )
            }
        default:
            break
        }
    }

    private func systemAuthorizationIsGranted() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    private func resolve(_ jsID: Int, with answer: String, in page: BrowserPage, frame: BrowserFrame) async {
        _ = try? await page.callAsyncJavaScript(
            "globalThis.__wsurfNotify?.resolve(id, answer);",
            arguments: ["id": jsID, "answer": answer], in: frame, contentWorld: Self.world
        )
    }

    private func push(permission: String, to page: BrowserPage, frame: BrowserFrame) async {
        _ = try? await page.callAsyncJavaScript(
            "globalThis.__wsurfNotify?.setPermission(permission);",
            arguments: ["permission": permission], in: frame, contentWorld: Self.world
        )
    }

    // MARK: - Delivery

    private func deliver(title: String, text: String, tag: String, from tab: BrowserTab) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.subtitle = tab.permissions.displayHost
        let identifier = tag.isEmpty
            ? UUID().uuidString
            : "\(tab.permissions.displayHost)#\(tag)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Pipeline.log.error("notification: delivery failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationBridge: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NSApp.activate()
    }
}
