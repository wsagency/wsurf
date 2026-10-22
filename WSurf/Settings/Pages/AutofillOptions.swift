// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The top of the Autofill page's Settings tab: what autofill offers to save and fill, which applies to every vault of the profile, then
/// Apple Pay. A private profile shows the switches off.
struct AutofillOptions: View {
    @Bindable var settings: BrowserSettings
    let context: BrowserProfileContext

    init(context: BrowserProfileContext) {
        self.context = context
        settings = context.settings
    }

    var body: some View {
        SettingsSection(title: "Save and fill", symbol: "rectangle.and.pencil.and.ellipsis") {
            DetailRow(title: "Save and fill passwords", caption: "Offer to save new logins after you sign in.") {
                SettingsToggle($settings.fillsPasswords)
            }
            .settingsAnchor("autofill.passwords")
            RowSeparator()
            DetailRow(title: "Save and fill payment cards", caption: "Offer to save new cards at checkout.") {
                SettingsToggle($settings.fillsPaymentCards)
            }
            .settingsAnchor("autofill.cards")
            RowSeparator()
            DetailRow(title: "Save and fill contacts and addresses", caption: "Offer to save contact details entered in forms.") {
                SettingsToggle($settings.fillsContacts)
            }
            .settingsAnchor("autofill.contacts")
            RowSeparator()
            AutofillSavePromptReset(kind: .card, context: context)
            RowSeparator()
            AutofillSavePromptReset(kind: .contact, context: context)
        }
        .disabled(context.profile.isPrivate)
        if let installed = PasswordExtensionPolicy.provider(in: context.extensions.installed + context.extensions.systemExtensions) {
            Text("\(installed.displayName) is also enabled and may still fill passwords on its own. Turn it off in Extensions to use only Credential Manager.")
                .font(Theme.Font.label).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SettingsSection(title: "Apple Pay", symbol: "apple.logo") {
            DetailRow(title: "Pay with iPhone", caption: "Scan a code to pay with iPhone.") {
                Text("Website support required").foregroundStyle(.secondary).font(Theme.Font.caption)
            }
        }
        .settingsAnchor("autofill.applePay")
    }
}
