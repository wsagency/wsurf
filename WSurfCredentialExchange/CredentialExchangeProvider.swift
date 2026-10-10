// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices

/// The extension's only job is to exist: the system offers credential exchange to apps that ship a credential
/// provider. It reads and writes no credentials, keeps no store and shares nothing with the containing app, so the
/// one thing it shows is where the credentials are managed.
final class CredentialExchangeProvider: ASCredentialProviderViewController {
    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Credentials are managed in WSurf"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)

        let explanation = NSTextField(wrappingLabelWithString: String(
            localized: "WSurf doesn’t fill passwords, passkeys or verification codes through this extension. To move credentials between WSurf and another app, open Settings in WSurf and choose Credentials."
        ))
        explanation.preferredMaxLayoutWidth = 360

        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(finish(_:)))
        done.keyEquivalent = "\r"

        let content = NSStackView(views: [title, explanation, done])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        content.setCustomSpacing(20, after: explanation)
        view = content
    }

    override func prepareInterfaceForExtensionConfiguration() {
        // The view built in `loadView()` is the whole configuration screen.
    }

    @objc private func finish(_ sender: Any?) {
        extensionContext.completeExtensionConfigurationRequest()
    }
}
