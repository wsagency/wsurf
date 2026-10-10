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
            && !PasswordExtensionPolicy.suppressesNativeFill(
                provider: context.settings.passwordProvider,
                in: context.extensions.installed + context.extensions.systemExtensions,
                selectedID: context.settings.passwordExtensionID
            )
    }
    @ObservationIgnored private let pages = NSHashTable<BrowserPage>.weakObjects()
    @ObservationIgnored private var frames: [ObjectIdentifier: [String: BrowserFrame]] = [:]

    func refreshPolicy() {
        AutofillSaveCoordinator.shared.refreshPolicy()
        refreshPages { _ in true }
    }
    /// One profile switched password provider: only its pages are told, and only its save sessions are refreshed.
    func providerChanged(in context: BrowserProfileContext) {
        AutofillSaveCoordinator.shared.providerChanged(in: context)
        refreshPages { $0 === context }
    }
    private func refreshPages(where matches: (BrowserProfileContext) -> Bool) {
        for page in pages.allObjects where matches(page.context) {
            for frame in (frames[ObjectIdentifier(page)] ?? [:]).values {
                applyPolicy(in: page, frame: frame)
            }
        }
    }
    private func applyPolicy(in page: BrowserPage, frame: BrowserFrame) {
        let context = page.context
        let enabled = isEnabled(in: context), manager = context.settings.passwordProvider == .credentialManager
        Task {
            do {
                guard page.context === context else { return }
                _ = try await page.callAsyncJavaScript(
                    "globalThis.__wsurfPasswords?.setCredentialManager(manager); globalThis.__wsurfPasswords?.setEnabled(enabled);",
                    arguments: ["enabled": enabled, "manager": manager],
                    in: frame,
                    contentWorld: Self.world
                )
            } catch {
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
