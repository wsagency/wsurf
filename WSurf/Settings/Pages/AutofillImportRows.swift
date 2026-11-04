// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Contacts
import SwiftUI
import UniformTypeIdentifiers

/// The Import & Export rows that bring payment cards from a Safari export, or contacts from Contacts, into the open vault. A review
/// lists titles only; Import writes in one commit and the notice offers Undo. With no vault yet the rows offer to create one; with a
/// locked vault they stay off, and the section's footnote says why.
struct AutofillImportRows: View {
    /// What a row's button does in the vault's state.
    enum Action: Equatable {
        case importItems, createVault, unavailable

        static func of(vaultExists: Bool?, isUnlocked: Bool, canCreateVault: Bool) -> Self {
            if isUnlocked {
                return .importItems
            }
            return vaultExists == false && canCreateVault ? .createVault : .unavailable
        }
    }

    let model: CredentialSettingsModel
    let createVault: () -> Void
    @State private var plan: AutofillImportPlan?
    @State private var problem: String?

    private var action: Action {
        .of(vaultExists: model.vaultExists, isUnlocked: model.isUnlocked, canCreateVault: model.canCreateVault)
    }

    var body: some View {
        DetailRow(title: "Import payment cards from a Safari export", caption: caption) {
            switch action {
            case .importItems:
                Button("Choose File…") { chooseSafariExport() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
            case .createVault:
                Button("Create Vault…", action: createVault).buttonStyle(.bordered)
            case .unavailable:
                Button("Choose File…") {}.buttonStyle(.bordered).disabled(true)
            }
        }
        RowSeparator()
        DetailRow(title: "Import contacts from Contacts", caption: contactsCaption) {
            switch action {
            case .importItems:
                ContactImportButton { contacts in review(contacts) }
                    .fixedSize()
                    .disabled(model.isBusy)
            case .createVault:
                Button("Create Vault…", action: createVault).buttonStyle(.bordered)
            case .unavailable:
                Button("Choose Contacts…") {}.buttonStyle(.bordered).disabled(true)
            }
        }
        if let problem {
            Text(verbatim: problem)
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // On one view, not a group: a group would give each of its rows its own sheet.
        RowSeparator()
            .sheet(item: $plan) { plan in
                AutofillImportReview(plan: plan) {
                    self.plan = nil
                    Task { await model.commitAutofillImport(plan) }
                } cancel: {
                    self.plan = nil
                }
            }
            // A review belongs to the unlock it was made under.
            .onChange(of: model.authorizationEpoch) { plan = nil }
    }

    private var caption: LocalizedStringResource? {
        action == .createVault ? "Cards and addresses are saved in a vault. Create one to import them." : nil
    }

    private var contactsCaption: LocalizedStringResource? {
        action == .importItems ? "Click each contact you want, then close the list: they are reviewed together." : nil
    }

    /// The contacts autofill can use, each once: a contact without such details, or with the same details as one before it, is left
    /// out. Nil when none is left.
    static func contactSources(_ contacts: [CNContact]) -> AutofillVaultMigration.Sources? {
        var seen = Set<[String]>()
        let usable = contacts.map(AutofillContact.init(contact:)).filter { $0.isValid && seen.insert(AutofillSaveCandidate.contact($0).values).inserted }
        return usable.isEmpty ? nil : AutofillVaultMigration.Sources(cards: [], contacts: usable)
    }

    private func chooseSafariExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose the ZIP that Safari exported, or its PaymentCards.json file.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        Task {
            do {
                let read = try await CredentialSettingsModel.safariCards(from: url)
                plan = await model.planAutofillImport(read.sources, skipped: read.skipped)
            } catch {
                problem = (error as? PaymentCardError)?.errorDescription ?? String(localized: "Couldn’t read this file.")
            }
        }
    }

    /// One review for every contact chosen in one opening of the picker; Import writes them in one commit with one Undo.
    private func review(_ contacts: [CNContact]) {
        guard let sources = Self.contactSources(contacts) else {
            problem = contacts.count == 1
                ? String(localized: "This contact has no details autofill can use.")
                : String(localized: "These contacts have no details autofill can use.")
            return
        }
        problem = nil
        Task { plan = await model.planAutofillImport(sources) }
    }
}

/// Titles only: a card's network and last four digits, a contact's title. Nothing is written until Import.
private struct AutofillImportReview: View {
    let plan: AutofillImportPlan
    let confirm: () -> Void
    let cancel: () -> Void

    private static let listedTitles = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import into the Vault").font(.headline)
            Text(caption).font(Theme.Font.label).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.titles.prefix(Self.listedTitles).enumerated()), id: \.offset) { _, title in
                        Text(verbatim: title)
                    }
                    if plan.titles.count > Self.listedTitles {
                        Text("and \(plan.titles.count - Self.listedTitles) more").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Import", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.writes == 0)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var caption: String {
        var text = plan.writes == 0
            ? String(localized: "The vault already holds everything here.")
            : String(localized: "\(plan.writes) of \(plan.titles.count) will be added to the vault. The others are already in it.")
        if plan.skipped > 0 {
            text += " " + String(localized: "\(plan.skipped) cards in the file couldn’t be read and are left out.")
        }
        return text
    }
}
