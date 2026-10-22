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
    @ObservationIgnored private var frames: [ObjectIdentifier: [String: BrowserFrame]] = [:]

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
        page.addScriptMessageHandler(name: Self.handlerName, in: Self.world) { [weak self] message in
            guard let self else { return }
            if let body = message.body as? [String: Any], body["action"] as? String == "ready" {
                guard let documentID = body["documentID"] as? String, UUID(uuidString: documentID) != nil else { return }
                var values = self.frames[ObjectIdentifier(message.page)] ?? [:]
                values[documentID] = message.frameInfo
                if message.frameInfo.isMainFrame {
                    self.frames[ObjectIdentifier(message.page)] = [documentID: message.frameInfo]
                } else {
                    self.frames[ObjectIdentifier(message.page)] = values
                }
                AutofillDiagnostics.note(.scriptReady, kind: .password)
                self.applyPolicy(in: message.page, frame: message.frameInfo)
            } else {
                AutofillSuggestions.shared.receive(message, kind: .password, world: Self.world, bridge: "__wsurfPasswords")
            }
        }
    }
    static func isSecure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil }
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
