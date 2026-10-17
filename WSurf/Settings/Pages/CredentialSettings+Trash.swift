// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

extension RecordSubject {
    var label: LocalizedStringResource {
        switch self {
        case .account:
            "Credential"
        case .password:
            "Password"
        case .totp:
            "Verification code"
        case .passkey:
            "Passkey"
        case .metadata:
            "Details"
        case .note:
            "Notes"
        }
    }
}

extension TrashItem {
    /// What was removed and how much history is kept with it: the earlier versions listed under this exact entry.
    var detail: String {
        var kind = String(localized: "Credential")
        if scope == .credential, let subject {
            kind = String(localized: subject.label)
        }
        guard revisionCount > 0 else { return kind }
        return String(localized: "\(kind) · \(revisionCount) earlier versions kept")
    }
}

extension UndeleteBlock {
    var explanation: LocalizedStringResource {
        switch self {
        case .ownerMissing:
            "The credential this belongs to is no longer in the vault."
        case .idCollision, .exchangeIDCollision:
            "A credential with the same identity is already in the vault."
        case .originUsernameOverlap:
            "A saved credential already uses this username on the same website."
        case .passkeyCollision, .passkeyIdentityConflict:
            "A saved passkey for the same website and account already exists."
        case .slotOccupied:
            "The credential already has one of these, and restoring would replace it."
        }
    }
}

extension CredentialSettings {
    /// Both lists in one place: Saved credentials and Trash switch here, so Trash never trails the live accounts.
    var listSwitch: some View {
        SegmentedControl(
            items: [.init(value: false, label: "Active"), .init(value: true, label: "Trash")],
            selection: showsTrash,
            onSelect: { next in
                showsTrash = next
                if next {
                    run { try await model.loadTrash() }
                }
            }
        )
        .fixedSize()
    }

    /// One vault's Trash, as the model lists it. A permanent delete is confirmed here and then needs a fresh passkey
    /// assertion, which the model requests.
    var trashSection: some View {
        SettingsSection(
            title: "Trash",
            symbol: "trash",
            footnote: "Removed credentials stay here, encrypted, with their earlier versions, until you delete them permanently.",
            isLongList: true,
            accessory: {
                HStack(spacing: 10) {
                    listSwitch
                    ToolbarChip(symbol: "trash.slash", label: "Empty Trash", isDestructive: true) {
                        model.requestPurge(entryIDs: [], emptyAll: true)
                    }
                    .disabled(model.isBusy || (model.trashTotal ?? 0) == 0)
                    ToolbarChip(symbol: "lock", label: "Lock") { model.lock() }
                }
            },
            content: {
                if model.trashTotal == 0 {
                    SettingsEmptyState(symbol: "trash", title: "Trash is empty", caption: "Credentials you remove can be restored from here.")
                }
                ForEach(model.trashItems) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        DetailRow(verbatimTitle: item.label, verbatimCaption: item.detail) {
                            HStack(spacing: 8) {
                                Button("Restore") { run { await model.restore(entryID: item.id) } }
                                    .accessibilityLabel("Restore \(item.label)")
                                Button("Delete…", role: .destructive) { model.requestPurge(entryIDs: [item.id], emptyAll: false) }
                                    .accessibilityLabel("Delete \(item.label) permanently")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy)
                        }
                        if let blocked = model.restoreBlocked, blocked.entryID == item.id {
                            restoreBlockedRow(blocked)
                        }
                    }
                    RowSeparator()
                }
                if model.trashHasMore {
                    DetailRow(
                        verbatimTitle: String(localized: "More in Trash"),
                        verbatimCaption: String(localized: "Showing \(model.trashItems.count) of \(model.trashTotal ?? model.trashItems.count)")
                    ) {
                        Button("Show More") { run { try await model.loadMoreTrash() } }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy)
                    }
                }
                AutofillPageStatus(isBusy: model.isBusy, error: model.error, kind: .password)
            }
        )
        .confirmationDialog(
            "Delete Permanently?",
            isPresented: Binding(get: { model.pendingPurge != nil && !model.isBusy }, set: { _ in }),
            presenting: model.pendingPurge
        ) { pending in
            Button(pending.emptyAll ? "Empty Trash" : "Delete Permanently", role: .destructive) {
                withWindow { window in await model.confirmPurge(in: window) }
            }
            Button("Cancel", role: .cancel) { model.cancelPurge() }
        } message: { pending in
            purgeMessage(pending)
        }
    }

    /// The only two things a blocked restore offers, in the model's own order. Neither can restore under another id or
    /// replace what is in the vault.
    private func restoreBlockedRow(_ blocked: RestoreBlocked) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                verbatim: String(localized: "This can’t be restored right now.") + " " + String(localized: blocked.block.explanation)
                    + " " + String(localized: "Nothing was changed.")
            )
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(blocked.actions, id: \.self) { action in
                    switch action {
                    case .dismiss:
                        Button("Dismiss") { model.dismissRestoreBlock() }
                    case .retrySameCopy:
                        Button("Try Again") { run { await model.restore(entryID: blocked.entryID) } }
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)
        }
    }

    private func purgeMessage(_ pending: PendingPurge) -> Text {
        var parts = [
            pending.emptyAll
                ? String(localized: """
                    This permanently deletes everything in Trash, including anything added to it before you confirm \
                    (\(pending.count) items right now), and all their earlier versions.
                    """)
                : String(localized: "This permanently deletes \(pending.count) item(s) from Trash, including their earlier versions."),
            String(localized: "It can’t be undone, and you’ll confirm with an unlock passkey."),
        ]
        if pending.warning.logicalOnly {
            parts.append(String(localized: "This removes the items from the vault only. It can’t reach copies of the vault saved elsewhere, such as backups."))
        }
        if let backup = pending.warning.preMigrationBackup {
            parts.append(String(localized: "A copy from before the vault was upgraded still exists at \(backup.path) and still holds them; delete it yourself if you want it gone."))
        }
        return Text(verbatim: parts.joined(separator: " "))
    }
}
