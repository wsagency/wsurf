// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CCef
import CefKit
import Foundation
import os
import WebKit

extension ChromiumClient {
    private static let authLog = Logger(subsystem: "io.wsagency.wsurf", category: "chromium")

    /// HTTP and proxy sign-in: the sheet WebKit tabs show (`AuthChallenge.requestCredential`), answered into CEF's callback.
    /// CEF asks again after a refused password, so the asks per server and realm are counted here for the "try again" line and
    /// the three-attempt limit WebKit tabs have.
    func presentAuth(_ raw: UnsafeMutableRawPointer, challenge: CefAuthChallenge, mainFrameURL: String?) {
        guard !isClosed else { Self.release(raw); return }
        hold(raw)
        let space = challenge.protectionSpace
        // CEF names the origin that asks, not the frame. Only the page's own origin (or a proxy) may take a password: an image or
        // frame of another site could otherwise put its sheet over this page, with a realm worded to look like the page's.
        let topLevel = [page?.owner?.url, mainFrameURL.flatMap { URL(string: $0) }]
        guard AuthChallenge.mayPrompt(for: space, topLevel: topLevel) else {
            Self.authLog.notice("HTTP sign-in cancelled: the request is not for the page's own website")
            cancelAuth(raw)
            return
        }
        let key = "\(challenge.isProxy)|\(challenge.host)|\(challenge.port)|\(challenge.realm)"
        let failures = authAttempts[key, default: 0]
        let window = page?.window
        guard let window,
              AuthChallenge.decision(for: space, previousFailureCount: failures) == .promptForCredential
        else {
            // No window to put the sheet on (a tab in the background), or the third refused password: answer cancel.
            Self.authLog.notice("HTTP sign-in cancelled: \(window == nil ? "the page has no window" : "too many refused passwords", privacy: .public)")
            authAttempts[key] = nil
            cancelAuth(raw)
            return
        }
        authAttempts[key] = failures + 1
        Task { @MainActor [weak self] in
            let credential = await AuthChallenge.requestCredential(for: space, previousFailures: failures, in: window)
            // Closing the client releases every pending callback, so a sheet that ends after it has nothing left to answer.
            guard let self, self.finish(raw) else { return }
            let callback = raw.assumingMemoryBound(to: cef_auth_callback_t.self)
            if let credential, let user = credential.user, let password = credential.password {
                ChromiumInterop.withString(user) { user in
                    ChromiumInterop.withString(password) { password in callback.pointee.cont?(callback, user, password) }
                }
            } else {
                self.authAttempts[key] = nil
                callback.pointee.cancel?(callback)
            }
            self.drop(raw)
        }
    }

    nonisolated func noteMainFrameRequest(_ address: String) {
        resourceStateLock.lock()
        mainFrameRequestURL = address
        resourceStateLock.unlock()
    }

    /// The main-frame request is over, whichever way: committed, failed, cancelled, a download, a 204. From then on the page's
    /// own address is the only one that counts, so an old request cannot lend its website a sheet.
    nonisolated func endMainFrameRequest() {
        resourceStateLock.lock()
        mainFrameRequestURL = nil
        resourceStateLock.unlock()
    }

    nonisolated func latestMainFrameRequestURL() -> String? {
        resourceStateLock.lock()
        defer { resourceStateLock.unlock() }
        return mainFrameRequestURL
    }

    private func cancelAuth(_ raw: UnsafeMutableRawPointer) {
        guard finish(raw) else { return }
        let callback = raw.assumingMemoryBound(to: cef_auth_callback_t.self)
        callback.pointee.cancel?(callback)
        drop(raw)
    }

}

extension CefAuthChallenge {
    /// The challenge as the sheet and `AuthChallenge.decision` know it.
    var protectionSpace: URLProtectionSpace {
        let method = switch scheme.lowercased() {
        case "digest":
            NSURLAuthenticationMethodHTTPDigest
        case "ntlm":
            NSURLAuthenticationMethodNTLM
        default:
            NSURLAuthenticationMethodHTTPBasic
        }
        if isProxy {
            return URLProtectionSpace(
                proxyHost: host, port: port, type: NSURLProtectionSpaceHTTPProxy,
                realm: realm.isEmpty ? nil : realm, authenticationMethod: method
            )
        }
        return URLProtectionSpace(
            host: host, port: port, protocol: URL(string: origin)?.scheme ?? "http",
            realm: realm.isEmpty ? nil : realm, authenticationMethod: method
        )
    }
}
