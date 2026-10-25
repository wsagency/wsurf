// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class PasswordAutofill {
    static let shared = PasswordAutofill()
    static let world = AutofillPage.world
    private static let handlerName = "wsurfPasswords"
    func isEnabled(in context: BrowserProfileContext) -> Bool {
        !context.profile.isPrivate && context.settings.fillsPasswords
    }
    @ObservationIgnored private let pages = NSHashTable<BrowserPage>.weakObjects()
    @ObservationIgnored private(set) var frames: [ObjectIdentifier: [String: BrowserFrame]] = [:]

    func refreshPolicy() {
        AutofillSaveCoordinator.shared.refreshPolicy()
        for page in pages.allObjects {
            for frame in (frames[ObjectIdentifier(page)] ?? [:]).values {
                applyPolicy(in: page, frame: frame)
            }
        }
    }
    private func applyPolicy(in page: BrowserPage, frame: BrowserFrame) {
        let context = page.context
        Task {
            await AutofillPolicyDelivery.deliver {
                guard page.context === context else { return }
                // Read when sent, so a retry never restores a policy that a later change replaced.
                _ = try await page.callAsyncJavaScript(
                    "globalThis.__wsurfPasswords?.setEnabled(enabled);",
                    arguments: ["enabled": self.isEnabled(in: context)],
                    in: frame,
                    contentWorld: Self.world
                )
            } failed: { error in
                AutofillDiagnostics.policyFailed(.password, error: error, isMainFrame: frame.isMainFrame)
            }
        }
    }

    func install(in page: BrowserPage) {
        pages.add(page)
        page.installScript(AutofillFormScript.source + AutofillSuggestionScript.source, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(PasswordAutofillScript.clientSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.handlerName, in: Self.world) { [weak self] message in self?.receive(message) }
        // The page's own invalidation point: closing the page (a closed tab, a replaced engine) ends here, and so does a retired document.
        page.addCredentialInvalidationObserver { [weak self] page, documentID in self?.forgetFrames(of: page, retiring: documentID) }
    }

    func receive(_ message: BrowserScriptMessage) {
        if let body = message.body as? [String: Any], body["action"] as? String == "ready" {
            guard let documentID = body["documentID"] as? String, UUID(uuidString: documentID) != nil else { return }
            var values = frames[ObjectIdentifier(message.page)] ?? [:]
            values[documentID] = message.frameInfo
            if message.frameInfo.isMainFrame {
                frames[ObjectIdentifier(message.page)] = [documentID: message.frameInfo]
            } else {
                frames[ObjectIdentifier(message.page)] = values
            }
            AutofillDiagnostics.note(.scriptReady, kind: .password)
            applyPolicy(in: message.page, frame: message.frameInfo)
        } else if let body = message.body as? [String: Any], body["action"] as? String == "context" {
            CredentialPicker.shared.noteContext(message)
        } else {
            AutofillSuggestions.shared.receive(message, kind: .password, world: Self.world, bridge: "__wsurfPasswords")
        }
    }

    /// A page that closed, or one of its documents that is gone (`documentID`), is no longer tracked. The start of a navigation is
    /// not that: it can fail or turn into a download and leave the document, and its registration, alive. The next main document
    /// replaces the page's frames in `receive`.
    private func forgetFrames(of page: BrowserPage, retiring documentID: String?) {
        let key = ObjectIdentifier(page)
        guard var values = frames[key] else { return }
        if let documentID, !documentID.isEmpty {
            values[documentID] = nil
            frames[key] = values.isEmpty ? nil : values
        } else if page.isClosed {
            frames[key] = nil
        }
    }
    static func isSecure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil }
}

extension BrowserFrame {
    /// The frame's origin for autofill (suggestions, Pick Credential…, save offers), when the address its script reports is of that
    /// origin. The origin is the engine's word for the frame, a Chromium cross-site frame's included, never the page's: a frame
    /// cannot claim another origin, and one whose origin is not trusted (opaque, sandboxed, an inheriting about:blank or srcdoc in
    /// a cross-site frame) or not HTTPS gets nothing.
    func autofillOrigin(reportedURL url: URL) -> String? {
        guard hasTrustedSecurityOrigin, securityOrigin.protocol == "https", securityOrigin.host == url.host?.lowercased(),
              (securityOrigin.port == 0 ? 443 : securityOrigin.port) == (url.port ?? 443) else { return nil }
        return SavedPassword.origin(for: url)
    }
}

/// Sends one frame its autofill policy. A frame can refuse the first call while its document is still starting, and its script would
/// then keep autofill off until the next policy change, so a refused call is tried once more after `delay`.
enum AutofillPolicyDelivery {
    @discardableResult
    static func deliver(
        retryAfter delay: Duration = .milliseconds(300), _ send: () async throws -> Void, failed: (any Error) -> Void
    ) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(for: delay)
            }
            do {
                try await send()
                return true
            } catch {
                failed(error)
            }
        }
        return false
    }
}
