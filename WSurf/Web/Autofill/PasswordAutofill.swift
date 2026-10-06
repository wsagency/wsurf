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
    private(set) var profileID = Profile.originalID
    var isPrivate: Bool {
        profileID == Profile.privateID
    }
    @ObservationIgnored var extensions: () -> [InstalledExtension] = { [] }
    var isEnabled: Bool {
        !isPrivate && BrowserSettings.shared.fillsPasswords
            && PasswordExtensionPolicy.provider(in: extensions(), selectedID: BrowserSettings.shared.passwordExtensionID) == nil
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
        guard page.profileID == profileID else { return }
        let enabled = isEnabled
        Task {
            _ = try? await page.callAsyncJavaScript(
                "globalThis.__wsurfPasswords?.setEnabled(enabled);",
                arguments: ["enabled": enabled],
                in: frame,
                contentWorld: Self.world
            )
        }
    }
    func use(profileID: UUID) {
        self.profileID = profileID
        frames.removeAll()
        refreshPolicy()
    }

    func install(in page: BrowserPage) {
        pages.add(page)
        page.installScript(AutofillFormScript.source + AutofillSuggestionScript.source, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(PasswordAutofillScript.clientSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.handlerName, in: Self.world) { [weak self] message in
            guard let self, message.page.profileID == self.profileID else { return }
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
                AutofillSuggestions.shared.receive(message, kind: .password, profileID: self.profileID, world: Self.world, bridge: "__wsurfPasswords")
            }
        }
    }
    static func isSecure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil }
}
