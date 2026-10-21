// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - Exchange

/// What the export sheet was opened for. The epoch travels with the selection, so a lock or re-unlock makes the export
/// fail instead of sending a different vault than the user chose from; the model also refuses a selection whose accounts
/// changed since. The sheet reads the credentials from the model, so a refresh after a refused export is what it shows.
struct CredentialExportContext: Identifiable {
    let id = UUID()
    let epoch: UInt64
    /// A plain-text password CSV file instead of the system hand-off to another app.
    var csv = false
}

struct CredentialExportSheet: View {
    let model: CredentialSettingsModel
    var csv = false
    let export: ([CredentialExportSelection]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [UUID: CredentialExportSelection] = [:]
    /// The credentials as the user last saw them: a refresh is compared against this to name what changed.
    @State private var shown: [CredentialSummary]
    /// The vault's own stamps for those credentials, from the last read that could vouch for them.
    @State private var shownStamps: [UUID: AccountStamp]
    @State private var review: CredentialExportReview?
    @State private var query = ""
    /// Set once the user asked to export from this sheet, so only that attempt's ending is shown here.
    @State private var attempted = false

    init(model: CredentialSettingsModel, csv: Bool = false, export: @escaping ([CredentialExportSelection]) -> Void) {
        self.model = model
        self.csv = csv
        self.export = export
        _shown = State(initialValue: model.summaries)
        _shownStamps = State(initialValue: model.exportStamps ?? [:])
    }

    private var chosen: [CredentialExportSelection] {
        model.summaries.compactMap { selection[$0.id] }.filter(\.hasParts)
    }

    /// The credentials this export can carry that match the search: the list's rule, over the summaries' precomputed keys. A
    /// credential that holds only cards and other items has nothing an export sends, so it is not listed.
    private var listed: [CredentialSummary] {
        let all = csv ? model.summaries.filter(CredentialCSVExport.isExportable) : model.summaries
        return CredentialListFilter.visible(all.filter { CredentialExportSelection(allOf: $0).hasParts }, query: query, filter: .all)
    }

    /// What a CSV file cannot hold, counted over the whole vault and shown before anything is written.
    private var csvLeftOut: String {
        let all = model.summaries
        let counts = (
            noWebsite: all.filter { $0.hasPassword && $0.origins.isEmpty }.count,
            noPassword: all.filter { !$0.hasPassword }.count,
            passkeys: all.reduce(0) { $0 + $1.passkeys.count },
            codes: all.filter(\.hasTOTP).count
        )
        return String(localized: """
            A CSV file holds only passwords with a website. It will not contain: \(counts.noWebsite) logins without a website, \
            \(counts.noPassword) credentials without a password, \(counts.passkeys) passkeys or \(counts.codes) verification \
            code setups. Notes are written only for a login whose Notes choice is on.
            """)
    }

    /// Whose vault the selection leaves from: the profile, and the vault when its name is readable.
    private var exportSource: String {
        guard let vault = model.vaultName else {
            return String(localized: "Exporting from the profile “\(model.profile.name)”.")
        }
        return String(localized: "Exporting from the vault “\(vault)” of the profile “\(model.profile.name)”.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(csv ? "Export Passwords to CSV" : "Export Credentials").font(.headline)
            Text(verbatim: exportSource)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if csv {
                Text("""
                    This saves the selected passwords to a CSV file that is NOT encrypted: anyone who can open the file \
                    can read every password in it. You choose where it goes, and WSurf never deletes it for you. Delete \
                    it as soon as you have imported it elsewhere. Don’t open it in a spreadsheet app, which may change or \
                    run cells that start with = + - or @.
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: csvLeftOut)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("""
                    Choose what to send to another app. The system passes your selection to the app you pick next, and \
                    that app can read it: any passwords, passkeys, verification code setups and notes you select aren’t \
                    encrypted by WSurf. WSurf doesn’t write a file, and your vault keeps its own copy.
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if attempted, let message = model.transferMessage {
                Text(verbatim: message.text)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
            if let review, !review.isEmpty {
                reviewNotice(review)
            }
            selectionBar
            ScrollView {
                // Lazy: the sheet lists every credential, and a vault holds thousands.
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(listed) { summary in
                        credentialRow(summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            if let error = model.error {
                Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.error = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(csv ? "Choose File…" : "Export…") {
                    attempted = true
                    review = nil
                    export(chosen)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: model.summaries) { reconcile() }
        .onChange(of: model.exportStamps) { reconcile() }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            TextField("Search by name, username or website", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search credentials")
            Button("Select All") { selection = CredentialExportSelection.setting(true, for: listed, csv: csv, in: selection) }
            Button("Select None") { selection = CredentialExportSelection.setting(false, for: listed, csv: csv, in: selection) }
            Text("\(chosen.count) selected").foregroundStyle(.secondary).fixedSize()
        }
        .controlSize(.small)
    }

    /// One credential is one unit: its switch selects every part, and shows a mixed state while only some are. The parts it holds are
    /// under the disclosure triangle.
    @ViewBuilder
    private func credentialRow(_ summary: CredentialSummary) -> some View {
        let parts = partBindings(summary)
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                if summary.hasLogin {
                    Toggle("Login", isOn: binding(summary.id, \.password))
                }
                if !csv {
                    ForEach(summary.passkeys) { passkey in
                        Toggle(isOn: passkeyBinding(summary.id, passkey.id)) {
                            Text(verbatim: "\(String(localized: "Passkey")) · \(passkey.rpID) · \(passkey.userName)")
                        }
                    }
                    if summary.hasTOTP {
                        Toggle("Verification code setup", isOn: binding(summary.id, \.totp))
                    }
                }
                if summary.hasNotes {
                    Toggle("Notes", isOn: binding(summary.id, \.notes))
                }
            }
            .padding(.top, 4)
        } label: {
            if parts.isEmpty {
                Text(verbatim: summary.title).font(Theme.Font.rowTitle)
            } else {
                Toggle(sources: parts, isOn: \.self) {
                    Text(verbatim: summary.title).font(Theme.Font.rowTitle)
                }
            }
        }
    }

    /// One binding per part this export offers for `summary`.
    private func partBindings(_ summary: CredentialSummary) -> [Binding<Bool>] {
        var result: [Binding<Bool>] = []
        if summary.hasLogin {
            result.append(binding(summary.id, \.password))
        }
        if !csv {
            result += summary.passkeys.map { passkeyBinding(summary.id, $0.id) }
            if summary.hasTOTP {
                result.append(binding(summary.id, \.totp))
            }
        }
        if summary.hasNotes {
            result.append(binding(summary.id, \.notes))
        }
        return result
    }

    /// What the refresh did to the chosen credentials. Nothing is sent by it: the user reads this, checks the selection
    /// below, and clicks Export again.
    private func reviewNotice(_ review: CredentialExportReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The vault changed. Review your selection before exporting again.").fontWeight(.medium)
            if !review.changed.isEmpty {
                Text(verbatim: "\(String(localized: "Changed")): \(review.changed.joined(separator: ", "))")
            }
            if !review.deleted.isEmpty {
                Text(verbatim: "\(String(localized: "No longer in the vault")): \(review.deleted.joined(separator: ", "))")
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// The selection follows the vault: parts that are gone leave it, and what changed is named, so a later click sends
    /// exactly what the sheet shows.
    private func reconcile() {
        let fresh = model.summaries
        let freshStamps = model.exportStamps
        let result = CredentialExportReview.reconcile(
            selection: selection, shown: shown, fresh: fresh, shownStamps: shownStamps, freshStamps: freshStamps
        )
        selection = result.selection
        shown = fresh
        shownStamps = freshStamps ?? shownStamps
        if !result.isEmpty {
            review = result
        }
    }

    private func update(_ accountID: UUID, _ change: (inout CredentialExportSelection) -> Void) {
        var current = selection[accountID]
            ?? CredentialExportSelection(accountID: accountID, password: false, passkeyIDs: [], totp: false)
        change(&current)
        selection[accountID] = current
    }

    private func binding(_ accountID: UUID, _ keyPath: WritableKeyPath<CredentialExportSelection, Bool>) -> Binding<Bool> {
        Binding(
            get: { selection[accountID]?[keyPath: keyPath] ?? false },
            set: { value in update(accountID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func passkeyBinding(_ accountID: UUID, _ passkeyID: UUID) -> Binding<Bool> {
        Binding(
            get: { selection[accountID]?.passkeyIDs.contains(passkeyID) ?? false },
            set: { on in
                update(accountID) {
                    if on {
                        $0.passkeyIDs.insert(passkeyID)
                    } else {
                        $0.passkeyIDs.remove(passkeyID)
                    }
                }
            }
        )
    }
}

extension CredentialImportReview.Record.Kind {
    var label: String {
        switch self {
        case .password:
            String(localized: "Login")
        case .passkey:
            String(localized: "Passkey")
        case .totp:
            String(localized: "Verification code")
        case .note:
            String(localized: "Notes")
        case .secureItems:
            String(localized: "Cards and other items")
        }
    }
}
