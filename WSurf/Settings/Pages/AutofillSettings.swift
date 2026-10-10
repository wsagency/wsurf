// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

enum AutofillDestination: String {
    case passwords, credentials, cards, contacts

    init?(anchor: String?) {
        guard let anchor else { return nil }
        self.init(rawValue: anchor == "autofill.applePay" ? "cards" : anchor.replacingOccurrences(of: "autofill.", with: ""))
    }
}

struct AutofillSettings: View {
    let coordinator: AppCoordinator
    @Bindable var settings: BrowserSettings
    var highlight: String?
    @State private var destination: AutofillDestination?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            if let destination {
                SubPageHeader(backTitle: "Autofill", onBack: { self.destination = nil }) {}
                switch destination {
                case .passwords:
                    PasswordSettings(settings: settings, extensions: coordinator.extensions, profileID: coordinator.profiles.current.id)
                case .credentials:
                    CredentialSettings(profile: coordinator.profiles.current)
                case .cards:
                    PaymentCardSettings(settings: settings, profileID: coordinator.profiles.current.id)
                case .contacts:
                    ContactAutofillSettings(settings: settings, profile: coordinator.profiles.current)
                }
            } else {
                SettingsPageHeader(title: "Autofill", caption: "WSurf stores saved details on this Mac.")
                SettingsCard {
                    DrillInRow(title: "Passwords", symbol: "key", tint: .orange, caption: "Save and fill website logins.") { destination = .passwords }
                    RowSeparator()
                    DrillInRow(title: "Credential Manager", symbol: "lock.shield", tint: .indigo, caption: "Passwords, passkeys and verification codes in an encrypted vault.") { destination = .credentials }
                    RowSeparator()
                    DrillInRow(title: "Payment cards", symbol: "creditcard", tint: .blue, caption: "Save and fill payment cards.") { destination = .cards }
                    RowSeparator()
                    DrillInRow(title: "Contacts and addresses", symbol: "person.crop.rectangle", tint: .green, caption: "Save and fill contact details.") { destination = .contacts }
                }
                SettingsCard {
                    DetailRow(title: "Password provider", caption: "Choose which store fills and saves website logins. Switching never moves or deletes saved data.") {
                        Picker("Password provider", selection: $settings.passwordProvider) {
                            Text("Passwords").tag(PasswordProvider.legacy)
                            Text("Credential Manager").tag(PasswordProvider.credentialManager)
                        }.labelsHidden().fixedSize()
                    }
                }
                .disabled(coordinator.profiles.current.isPrivate)
                .settingsAnchor("autofill.passwordProvider")
                if settings.passwordProvider == .credentialManager,
                   let installed = PasswordExtensionPolicy.provider(
                       in: coordinator.extensions.installed + coordinator.extensions.systemExtensions, selectedID: settings.passwordExtensionID
                   ) {
                    Text("\(installed.displayName) is also enabled and may still fill passwords on its own. Turn it off in Extensions to use only Credential Manager.")
                        .font(Theme.Font.label).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .environment(\.settingsDescriptionLineLimit, 1)
        .id(coordinator.profiles.current.id)
        .onChange(of: highlight, initial: true) { _, anchor in
            if let target = AutofillDestination(anchor: anchor) {
                destination = target
            }
        }
        // A queued system import opens the current profile's credential page. Showing it fetches nothing and unlocks nothing.
        .onChange(of: CredentialExchangeCoordinator.shared.pendingToken, initial: true) { _, token in
            if token != nil { destination = .credentials }
        }
    }
}

struct AutofillPageStatus: View {
    let isBusy: Bool
    let error: String?
    let kind: AutofillSaveKind

    private var loadingMessage: LocalizedStringResource {
        switch kind {
        case .password:
            "Accessing passwords…"
        case .card:
            "Accessing cards…"
        case .contact:
            "Accessing addresses…"
        }
    }

    var body: some View {
        if isBusy {
            HStack(spacing: 8) {
                Spinner(size: 14)
                Text(loadingMessage).foregroundStyle(.secondary)
            }.padding(.vertical, 12)
        }
        if let error {
            Text(verbatim: error).foregroundStyle(.secondary).font(Theme.Font.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
        }
    }
}
