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
    var highlight: String?
    @State private var destination: AutofillDestination?

    private var passwordProvider: Binding<PasswordProvider> {
        Binding(
            get: { coordinator.context.settings.passwordProvider },
            set: { coordinator.context.settings.passwordProvider = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            if let destination {
                SubPageHeader(backTitle: "Autofill", onBack: { self.destination = nil }) {}
                switch destination {
                case .passwords:
                    PasswordSettings(context: coordinator.context)
                case .credentials:
                    CredentialSettings(profile: coordinator.context.profile)
                case .cards:
                    PaymentCardSettings(context: coordinator.context)
                case .contacts:
                    ContactAutofillSettings(context: coordinator.context)
                }
            } else {
                SettingsPageHeader(title: "Autofill", caption: "WSurf stores saved details on this Mac.")
                SettingsCard {
                    DrillInRow(title: "Passwords", symbol: "key", tint: .orange, caption: "Save and fill website logins.") { destination = .passwords }
                    RowSeparator()
                    DrillInRow(
                        title: "Credential Manager",
                        symbol: "lock.shield",
                        tint: .indigo,
                        caption: "Passwords, passkeys and verification codes in an encrypted vault."
                    ) {
                        destination = .credentials
                    }
                    RowSeparator()
                    DrillInRow(title: "Payment cards", symbol: "creditcard", tint: .blue, caption: "Save and fill payment cards.") { destination = .cards }
                    RowSeparator()
                    DrillInRow(title: "Contacts and addresses", symbol: "person.crop.rectangle", tint: .green, caption: "Save and fill contact details.") { destination = .contacts }
                }
                SettingsCard {
                    DetailRow(title: "Password provider", caption: "Choose which store fills and saves website logins. Switching never moves or deletes saved data.") {
                        Picker("Password provider", selection: passwordProvider) {
                            Text("Passwords").tag(PasswordProvider.legacy)
                            Text("Credential Manager").tag(PasswordProvider.credentialManager)
                        }.labelsHidden().fixedSize()
                    }
                }
                .disabled(coordinator.context.profile.isPrivate)
                .settingsAnchor("autofill.passwordProvider")
                if coordinator.context.settings.passwordProvider == .credentialManager,
                   let installed = PasswordExtensionPolicy.provider(
                       in: coordinator.context.extensions.installed + coordinator.context.extensions.systemExtensions,
                       selectedID: coordinator.context.settings.passwordExtensionID
                   ) {
                    Text("\(installed.displayName) is also enabled and may still fill passwords on its own. Turn it off in Extensions to use only Credential Manager.")
                        .font(Theme.Font.label).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .environment(\.settingsDescriptionLineLimit, 1)
        .id(coordinator.context.contextID)
        .onChange(of: highlight, initial: true) { _, anchor in
            if let target = AutofillDestination(anchor: anchor) {
                destination = target
            }
        }
        // A queued system import opens the credential page of the profile this window shows. Showing it fetches
        // nothing and unlocks nothing; the import is claimed only when the user reviews it from a profile's page.
        .onChange(of: CredentialExchangeCoordinator.shared.pendingToken, initial: true) { _, token in
            if token != nil {
                destination = .credentials
            }
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
