// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation

@MainActor
enum AuthChallenge {
    enum Decision: Equatable {
        case evaluateServerTrust
        case useDefaultHandling
        case rejectProtectionSpace
        case promptForCredential
    }

    static func decision(
        for space: URLProtectionSpace,
        previousFailureCount: Int
    ) -> Decision {
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return .evaluateServerTrust
        }
        guard isPasswordBased(space.authenticationMethod) else {
            return .useDefaultHandling
        }
        guard previousFailureCount < 3 else {
            return .rejectProtectionSpace
        }
        return .promptForCredential
    }

    /// `scheme://host[:port]`, lowercased and without the scheme's default port, or nil for an address without a host.
    static func origin(scheme: String?, host: String?, port: Int?) -> String? {
        guard let scheme = scheme?.lowercased(), !scheme.isEmpty, let host = host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let isDefault = port == nil || port == 0 || (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port ?? 0)"
    }

    static func origin(of url: URL?) -> String? {
        origin(scheme: url?.scheme, host: url?.host(percentEncoded: false), port: url?.port)
    }

    /// What the sheet calls the one that asks: the website's address, or a proxy's host and port.
    static func askingOrigin(of space: URLProtectionSpace) -> String {
        if space.isProxy() {
            return space.port == 0 ? space.host : "\(space.host):\(space.port)"
        }
        return origin(scheme: space.protocol, host: space.host, port: space.port) ?? space.host
    }

    /// Whether a challenge may put a password sheet over the page. Neither engine says which frame a challenge belongs to, so the
    /// rule is the one the address bar can stand behind: the challenge is for the page's own website (its address, or the main-frame
    /// request in flight), or for a proxy. An image or frame from another website that answers 401 raises no sheet: its realm,
    /// which the server words as it likes, could pass for the page's own and take the page's password.
    static func mayPrompt(for space: URLProtectionSpace, topLevel: [URL?]) -> Bool {
        if space.isProxy() {
            return true
        }
        guard let asking = origin(scheme: space.protocol, host: space.host, port: space.port) else {
            return false
        }
        return topLevel.contains { origin(of: $0) == asking }
    }

    static func isPasswordBased(_ method: String) -> Bool {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            return true
        default:
            return false
        }
    }

    /// Tests answer the sheet. WebKit drives the delegate itself, outside any task a test could mark, so this is a plain static.
    static var credentialForTesting: ((URLProtectionSpace, Int) -> URLCredential?)?

    /// The sign-in sheet of both engines: the website's WebKit challenge and Chromium's `get_auth_credentials`.
    static func requestCredential(
        for space: URLProtectionSpace,
        previousFailures: Int,
        in window: NSWindow?
    ) async -> URLCredential? {
        if let stub = credentialForTesting {
            return stub(space, previousFailures)
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign in to \(askingOrigin(of: space))")
        alert.informativeText = (previousFailures > 0
            ? String(localized: "That username or password wasn’t accepted. Try again.")
            : String(localized: "This website is asking for a username and password.")) + realmLine(for: space)
        alert.addButton(withTitle: String(localized: "Sign In"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let fields = NSStackView(views: [])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.alignment = .leading

        let user = NSTextField(string: "")
        user.placeholderString = String(localized: "Username")
        let password = NSSecureTextField(string: "")
        password.placeholderString = String(localized: "Password")
        for field in [user, password] as [NSTextField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            fields.addArrangedSubview(field)
        }
        fields.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user

        let response = await present(alert, in: window)
        guard response == .alertFirstButtonReturn, !user.stringValue.isEmpty else { return nil }
        return URLCredential(
            user: user.stringValue,
            password: password.stringValue,
            persistence: .forSession
        )
    }

    /// The realm is the server's own wording: it is set apart as the website's message, in quotes, and cut at 80 characters.
    private static func realmLine(for space: URLProtectionSpace) -> String {
        guard let realm = space.realm, !realm.isEmpty else { return "" }
        let trimmed = realm.count > 80 ? String(realm.prefix(80)) + "…" : realm
        return "\n" + String(localized: "The website’s message: “\(trimmed)”")
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
