// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - Exchange

/// What the export sheet was opened for. The epoch travels with the selection, so a lock or re-unlock makes the export
/// fail instead of sending a different vault than the user chose from; the model also refuses a selection whose accounts
/// changed since.
struct CredentialExportContext: Identifiable {
    let id = UUID()
    let epoch: UInt64
    let summaries: [CredentialSummary]
}

struct CredentialExportSheet: View {
    let model: CredentialSettingsModel
    let context: CredentialExportContext
    let export: ([CredentialExportSelection]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [UUID: CredentialExportSelection] = [:]

    private var chosen: [CredentialExportSelection] {
        context.summaries.compactMap { selection[$0.id] }.filter { $0.password || $0.totp || !$0.passkeyIDs.isEmpty }
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
            Text("Export Credentials").font(.headline)
            Text(verbatim: exportSource)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("""
                Choose what to send to another app. The system passes your selection to the app you pick next, and \
                that app can read it: any passwords, passkeys and verification code setups you select aren’t \
                encrypted by WSurf. WSurf doesn’t write a file, and your vault keeps its own copy.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(context.summaries) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: summary.title).font(Theme.Font.rowTitle)
                            if summary.hasLogin {
                                Toggle("Login", isOn: binding(summary.id, \.password))
                            }
                            ForEach(summary.passkeys) { passkey in
                                Toggle(isOn: passkeyBinding(summary.id, passkey.id)) {
                                    Text(verbatim: "\(String(localized: "Passkey")) · \(passkey.rpID) · \(passkey.userName)")
                                }
                            }
                            if summary.hasTOTP {
                                Toggle("Verification code setup", isOn: binding(summary.id, \.totp))
                            }
                        }
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
                Button("Export…") { export(chosen) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
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

struct CredentialImportReviewSheet: View {
    let model: CredentialSettingsModel
    let run: (@escaping () async throws -> Void) -> Void

    var body: some View {
        if let review = model.importReview {
            VStack(alignment: .leading, spacing: 18) {
                Text("Review Import").font(.headline)
                Text(verbatim: destination(review))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(review.candidates) { candidate in candidateView(candidate) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                if let outcome = review.outcome {
                    Text(verbatim: importSummary(outcome)).foregroundStyle(.secondary)
                } else {
                    Text("Choose what to do with each credential that already exists here.").foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.error = nil; model.cancelImport() }
                        .keyboardShortcut(.cancelAction)
                    Button("Import") { run { await model.commitImport() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!review.isResolved || (review.outcome.map { $0.added + $0.updated } ?? 0) == 0 || model.isBusy)
                }
            }
            .padding(24)
            .frame(width: 520)
        }
    }

    private func destination(_ review: CredentialImportReview) -> String {
        guard let vault = review.vaultName else {
            return String(localized: """
                Importing into the profile “\(review.profileName)”. Nothing is saved until you choose Import. \
                Imported passwords, passkeys and verification codes are encrypted in that profile’s vault.
                """)
        }
        return String(localized: """
            Importing into the vault “\(vault)” of the profile “\(review.profileName)”. Nothing is saved until you \
            choose Import. Imported passwords, passkeys and verification codes are encrypted in that vault.
            """)
    }

    private func importSummary(_ outcome: CredentialImportOutcome) -> String {
        var text = String(localized: "Adds \(outcome.added) and updates \(outcome.updated).")
        let unchanged = outcome.results.filter { $0.action == .unchanged }.count
        let skipped = outcome.results.filter { $0.action == .skipped }.count
        if unchanged > 0 {
            text += " " + String(localized: "\(unchanged) already saved.")
        }
        if skipped > 0 {
            text += " " + String(localized: "\(skipped) won’t be imported.")
        }
        return text
    }

    @ViewBuilder
    private func candidateView(_ candidate: CredentialImportReview.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: candidate.summary.title).font(Theme.Font.rowTitle)
            if !candidate.summary.origins.isEmpty {
                Text("The other app sent websites: \(candidate.summary.origins.joined(separator: ", "))")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if candidate.needsManualAssociation {
                Text("The other app sent no website for this.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(candidate.records) { record in recordView(record) }
        }
    }

    private func recordView(_ record: CredentialImportReview.Record) -> some View {
        let targets = model.mergeTargets(for: record.incoming)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(record.kind.label) · \(record.title)")
                    if let existing = record.existingTitle {
                        Text("Already saved as “\(existing)”").font(Theme.Font.label).foregroundStyle(.secondary)
                        if record.removesStoredPasswordOnReplace {
                            Text("Replace Saved removes the password saved for “\(existing)”. The other app’s login has none.")
                                .font(Theme.Font.label)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Skip") { model.chooseImport(.skip, for: record.incoming) }
                    if record.isConflict {
                        Button("Replace Saved") { model.chooseImport(.replace, for: record.incoming) }
                    }
                    if record.canAddSeparately {
                        Button("Add Separately") { model.chooseImport(.addSeparately, for: record.incoming) }
                    }
                    if !targets.isEmpty {
                        Menu("Merge Into…") {
                            ForEach(targets) { target in
                                Button(mergeMenuTitle(target, kind: record.kind)) {
                                    model.chooseImport(.merge(into: target.accountID), for: record.incoming)
                                }
                            }
                        }
                    }
                } label: {
                    Text(choiceLabel(record))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let line = destinationLine(record) {
                Text(verbatim: line)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A passkey keeps the website it was created for, so the target's websites don't describe it. Any other
    /// credential inherits them, and a target with none is said to have none rather than shown blank.
    private func mergeMenuTitle(_ target: CredentialImportReview.Target, kind: CredentialImportReview.Record.Kind) -> String {
        guard kind != .passkey else { return target.title }
        if target.allowedOrigins.isEmpty { return "\(target.title) — \(String(localized: "no approved website"))" }
        return "\(target.title) — \(target.allowedOrigins.joined(separator: ", "))"
    }

    /// Where the record will be saved and which websites it will work on, as the import itself will do it. A stored
    /// account keeps exactly its own websites; the other app's are only ever listed here to say they are not added.
    private func destinationLine(_ record: CredentialImportReview.Record) -> String? {
        guard let destination = record.destination else { return nil }
        let relyingParty = record.relyingParty ?? ""
        switch destination {
        case .skipped:
            return String(localized: "Won’t be imported.")
        case let .newAccount(origins):
            if record.kind == .passkey {
                return String(localized: "Saved as a new account. The passkey stays tied to \(relyingParty).")
            }
            if origins.isEmpty {
                return String(localized: "Saved as a new account with no approved website, so autofill won’t offer it until you add one.")
            }
            return String(localized: "Saved as a new account that works on \(origins.joined(separator: ", ")).")
        case let .existing(_, title, origins, ignored):
            if record.kind == .passkey {
                return String(localized: "Saved with “\(title)”. The passkey stays tied to \(relyingParty).")
            }
            var line = origins.isEmpty
                ? String(localized: "Saved into “\(title)”, which has no approved website, so autofill won’t offer it until you add one.")
                : String(localized: "Saved into “\(title)”, which works on \(origins.joined(separator: ", ")).")
            if !ignored.isEmpty {
                line += " " + String(localized: "The other app’s websites aren’t added: \(ignored.joined(separator: ", ")).")
            }
            return line
        }
    }

    private func choiceLabel(_ record: CredentialImportReview.Record) -> LocalizedStringResource {
        switch record.choice {
        case nil:
            record.isConflict ? "Choose…" : "Import"
        case .skip:
            "Skip"
        case .replace:
            "Replace Saved"
        case .addSeparately:
            "Add Separately"
        case .merge:
            "Merge"
        }
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
        }
    }
}
