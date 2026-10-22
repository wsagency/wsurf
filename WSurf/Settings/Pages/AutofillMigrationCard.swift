// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Observation
import Security
import SwiftUI
import WSurfVault

/// On the open Vault tab while the cards and addresses saved on this Mac have not moved into the vault (`AutofillVaultMigration`).
/// Showing it asks the Keychain whether the old lists exist and nothing more. Review reads them (Touch ID once, for the cards) and
/// lists titles only; Move to Vault writes the entries into the selected vault; Undo moves them to Trash; Erase Old Copies… erases the
/// old lists only after a confirmation that names the counts.
struct AutofillMigrationCard: View {
    let model: CredentialSettingsModel
    @State private var migration: AutofillMigrationModel

    /// How many titles the review lists by name; the counts cover the rest.
    private static let listedTitles = 50

    init(model: CredentialSettingsModel) {
        self.model = model
        _migration = State(initialValue: AutofillMigrationModel(migration: AutofillVaultMigration(profile: model.profile)))
    }

    var body: some View {
        Group {
            if let state = migration.state, state != .done {
                content(state)
            }
        }
        .task { await migration.refresh() }
        // What was read belongs to the unlock and the vault it was read for.
        .onChange(of: model.authorizationEpoch) { migration.end() }
        .onChange(of: model.selectedVaultID) { migration.end() }
        .onDisappear { migration.end() }
        .confirmationDialog(
            "Erase the Copies Saved on This Mac?",
            isPresented: Binding(get: { migration.pendingErase != nil }, set: { if !$0 { migration.pendingErase = nil } }),
            presenting: migration.pendingErase
        ) { report in
            Button("Erase Old Copies", role: .destructive) { Task { await migration.erase(report, in: model.manager) } }
            Button("Cancel", role: .cancel) {}
        } message: { report in
            Text(verbatim: AutofillMigrationModel.eraseText(report))
        }
    }

    @ViewBuilder
    private func content(_ state: AutofillVaultMigration.State) -> some View {
        switch migration.step {
        case .start:
            SettingsCard {
                DetailRow(title: "Cards and addresses saved on this Mac", caption: caption(state)) {
                    Button("Review…") { Task { await migration.review(in: model.manager) } }
                        .buttonStyle(.bordered)
                        .disabled(migration.isBusy)
                }
                status
            }
        case .review(let titles, let writes):
            SettingsSection(
                title: "Move to the Vault", symbol: "tray.and.arrow.down",
                footnote: "The copies saved on this Mac stay until you erase them."
            ) {
                ForEach(Array(titles.prefix(Self.listedTitles).enumerated()), id: \.offset) { _, title in
                    DetailRow(verbatimTitle: title) { EmptyView() }
                }
                DetailRow(caption: reviewCaption(total: titles.count, writes: writes)) {
                    HStack(spacing: 8) {
                        Button("Cancel") { migration.end() }
                        Button("Move to Vault") {
                            Task {
                                await migration.move(in: model.manager)
                                await reload()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .fixedSize()
                    .disabled(migration.isBusy)
                }
                status
            }
        case .moved(let report):
            SettingsCard {
                DetailRow(title: "Cards and addresses moved to the vault", caption: movedCaption(report)) {
                    HStack(spacing: 8) {
                        Button("Undo") {
                            Task {
                                await migration.undo(in: model.manager)
                                await reload()
                            }
                        }
                        Button("Erase Old Copies…") { migration.pendingErase = report }
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(migration.isBusy)
                }
                status
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if migration.isBusy {
            Spinner(size: 14).padding(.vertical, 8)
        }
        if let error = migration.error {
            Text(verbatim: error)
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
        }
    }

    private func caption(_ state: AutofillVaultMigration.State) -> LocalizedStringResource {
        state == .imported
            ? "They are in the vault. Review them, then erase the copies saved on this Mac."
            : "Move them into this vault, where autofill fills them from. Nothing is read until you choose Review."
    }

    private func reviewCaption(total: Int, writes: Int) -> LocalizedStringResource {
        "\(writes) of \(total) will be added to the vault. The others are already in it."
    }

    private func movedCaption(_ report: AutofillVaultMigration.Report) -> LocalizedStringResource {
        report.missing == 0
            ? "\(report.moved) moved, \(report.alreadyThere) already in the vault. Undo moves the new entries to Trash."
            : "\(report.moved) moved, \(report.alreadyThere) already in the vault, \(report.missing) not in the vault."
    }

    /// The page's list shows what the move or the undo wrote.
    private func reload() async {
        guard let epoch = model.authorizationEpoch else { return }
        _ = try? await model.reloadAfterWrite(epoch: epoch)
    }
}

/// The card's steps over `AutofillVaultMigration`, for the vault the page has unlocked. What was read is kept for one review only and
/// dropped on any lock, vault switch or when the page closes.
@MainActor
@Observable
final class AutofillMigrationModel {
    enum Step: Equatable {
        case start
        /// The old copies were read: their titles, and how many entries the move writes.
        case review(titles: [String], writes: Int)
        case moved(AutofillVaultMigration.Report)
    }

    private(set) var state: AutofillVaultMigration.State?
    private(set) var step = Step.start
    private(set) var isBusy = false
    private(set) var error: String?
    var pendingErase: AutofillVaultMigration.Report?

    @ObservationIgnored private let migration: AutofillVaultMigration
    @ObservationIgnored private var sources: AutofillVaultMigration.Sources?
    @ObservationIgnored private var session: AutofillAuthenticationSession?
    @ObservationIgnored private var epoch: UInt64?

    init(migration: AutofillVaultMigration) {
        self.migration = migration
    }

    func refresh() async {
        state = await migration.state()
    }

    /// Reads the old copies for the vault of `manager` under its current unlock. When the vault already holds every one, the review
    /// goes straight to the report.
    func review(in manager: CredentialManager?) async {
        guard let manager, let epoch = manager.authorizationEpoch else { return }
        end()
        await run {
            let session = try await self.migration.makeSession()
            self.session = session
            let sources = try await self.migration.sources(using: session)
            let snapshot = try await manager.snapshot()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            self.sources = sources
            self.epoch = epoch
            let writes = AutofillVaultMigration.entries(for: sources, in: snapshot.accounts).count
            if writes == 0 {
                self.step = .moved(try await self.migration.move(sources, into: manager, epoch: epoch))
            } else {
                self.step = .review(titles: sources.cards.map(\.summary.label) + sources.contacts.map(\.title), writes: writes)
            }
        }
    }

    func move(in manager: CredentialManager?) async {
        await run {
            guard let manager, let sources, let epoch, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            self.step = .moved(try await self.migration.move(sources, into: manager, epoch: epoch))
        }
    }

    func undo(in manager: CredentialManager?) async {
        await run {
            guard let manager, let epoch, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            try await self.migration.undo(in: manager, epoch: epoch)
            self.end()
        }
    }

    func erase(_ report: AutofillVaultMigration.Report, in manager: CredentialManager?) async {
        pendingErase = nil
        await run {
            guard let manager, let session, let epoch, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            try await self.migration.erase(using: session, confirmed: report, in: manager, epoch: epoch)
            self.end()
        }
    }

    /// Drops what was read, and the authentication it was read under.
    func end() {
        session?.invalidate()
        session = nil
        sources = nil
        epoch = nil
        step = .start
        pendingErase = nil
    }

    private func run(_ work: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            self.error = Self.message(for: error)
            if case AutofillVaultMigration.Failure.changed = error {
                end()
            }
        }
        state = await migration.state()
    }

    static func message(for error: any Error) -> String? {
        switch error {
        case AutofillVaultError.keychain(let status) where status == errSecUserCanceled:
            nil
        case AutofillVaultMigration.Failure.changed:
            String(localized: "The cards and addresses or the vault changed. Nothing was erased. Review them again.")
        case AutofillVaultMigration.Failure.notErased:
            String(localized: "Some copies are still saved on this Mac. Try again.")
        case CredentialVaultError.unauthorized, CredentialVaultError.expired:
            String(localized: "The vault locked. Unlock it and review again.")
        default:
            String(localized: "Couldn’t move the cards and addresses. Nothing was erased.")
        }
    }

    /// What the erase confirmation says: the counts, and every card or address the vault does not hold.
    static func eraseText(_ report: AutofillVaultMigration.Report) -> String {
        var text = String(localized: "\(report.moved) moved into the vault and \(report.alreadyThere) were already in it.")
        if report.missing > 0 {
            text += " " + String(localized: "\(report.missing) of \(report.total) aren’t in the vault, so erasing deletes them permanently.")
        }
        return text + " " + String(localized: """
            WSurf then erases the cards and addresses saved on this Mac, and the list it suggested them from. Autofill fills them from \
            the vault. This can’t be undone.
            """)
    }
}
