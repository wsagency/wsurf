// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WSurfCore
import WSurfVault

/// The entries that changed on this Mac and on another device, differ with no common ground, or cannot be added here, one row each.
/// Nothing is applied or sent for a row until a choice is made, and the version not kept stays in that entry's History or Trash on the
/// Mac that had it. A row that is only information has one button, Dismiss, which changes nothing.
struct VaultSyncReviewSheet: View {
    let conflicts: [VaultSyncConflict]
    let isBusy: Bool
    let resolve: ([UUID], Bool) -> Void
    let done: () -> Void

    /// Rows that ask for a choice; the information-only kinds are dismissed one by one.
    private var actionable: [VaultSyncConflict] {
        conflicts.filter { Self.asksForChoice($0.kind) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Sync Changes").font(Theme.Font.row).fontWeight(.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(conflicts.enumerated()), id: \.element.id) { index, conflict in
                        if index > 0 {
                            RowSeparator(inset: 0)
                        }
                        row(conflict)
                    }
                }
            }
            .frame(maxHeight: 360)
            Text("The version you don’t keep stays in that entry’s History or Trash on the Mac that had it.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if isBusy {
                    Spinner(size: 14)
                }
                Spacer()
                Button("Keep All This Mac’s") { resolve(actionable.map(\.id), true) }
                    .disabled(isBusy || actionable.isEmpty)
                Button("Use All iCloud Versions") { resolve(actionable.map(\.id), false) }
                    .disabled(isBusy || actionable.isEmpty)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    static func asksForChoice(_ kind: SyncConflictKind) -> Bool {
        switch kind {
        case .bothChanged, .noCommonBase, .deletedThereChangedHere, .changedThereDeletedHere, .previouslyRemoved:
            true
        case .ambiguous, .refused:
            false
        }
    }

    private func row(_ conflict: VaultSyncConflict) -> some View {
        let title = (conflict.local ?? conflict.incoming).map { CredentialSummary($0).title } ?? String(localized: "Entry")
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(Theme.Font.row).fontWeight(.medium)
                Text(verbatim: caption(conflict)).font(Theme.Font.label).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if Self.asksForChoice(conflict.kind) {
                let labels = Self.labels(conflict.kind)
                HStack(spacing: 6) {
                    Button(labels.keep) { resolve([conflict.id], true) }.disabled(isBusy)
                    Button(labels.take) { resolve([conflict.id], false) }.disabled(isBusy)
                }
            } else {
                Button("Dismiss") { resolve([conflict.id], true) }.disabled(isBusy)
            }
        }
        .padding(.vertical, 8)
    }

    private func caption(_ conflict: VaultSyncConflict) -> String {
        switch conflict.kind {
        case .bothChanged:
            let names = conflict.parts.map(Self.name).joined(separator: ", ")
            return String(localized: "Changed here and on another device: \(names).")
        case .noCommonBase:
            return String(localized: "Different here and in iCloud.")
        case .deletedThereChangedHere:
            return String(localized: "Deleted on another device, changed here.")
        case .changedThereDeletedHere:
            return String(localized: "Changed on another device, deleted here.")
        case .previouslyRemoved:
            return String(localized: "In iCloud, but deleted here.")
        case .ambiguous:
            return String(localized: "Another entry here holds the same item from Passwords.")
        case .refused:
            return String(localized: "This vault can’t take this entry on this Mac.")
        }
    }

    static func name(_ part: SyncPart) -> String {
        switch part {
        case .password:
            String(localized: "Login")
        case .totp:
            String(localized: "Code")
        case .notes:
            String(localized: "Notes")
        case .secureItems:
            String(localized: "Items")
        case .metadata:
            String(localized: "Name and websites")
        }
    }

    /// The two buttons of a row: the first keeps what this Mac has, the second takes iCloud's.
    static func labels(_ kind: SyncConflictKind) -> (keep: LocalizedStringResource, take: LocalizedStringResource) {
        switch kind {
        case .deletedThereChangedHere:
            ("Keep This Mac’s", "Move to Trash")
        case .changedThereDeletedHere, .previouslyRemoved:
            ("Keep Deleted", "Restore")
        case .bothChanged, .noCommonBase, .ambiguous, .refused:
            ("Keep This Mac’s", "Use iCloud Version")
        }
    }
}
