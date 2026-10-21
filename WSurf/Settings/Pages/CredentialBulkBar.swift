// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Above the list while credentials are selected or the list is in selection mode: what the selection can do. Move to Trash needs no
/// confirmation (the Trash keeps everything, and the notice offers Undo); Merge… opens the merge sheet to review the choice first.
struct CredentialBulkBar: View {
    let model: CredentialSettingsModel
    let selection: CredentialSelection
    /// How many rows the list shows, for Select All.
    let visibleCount: Int
    let moveToTrash: ([UUID]) -> Void
    let merge: ([UUID]) -> Void

    @ViewBuilder
    var body: some View {
        // The list never reads the selection; this bar does, so only it follows a change.
        if selection.showsCheckboxes {
            bar(selection.selectedInOrder)
        }
    }

    private func bar(_ ids: [UUID]) -> some View {
        let canMerge = CredentialMerge.mayMerge(summaries(of: ids))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                count(ids.count)
                Spacer(minLength: 8)
                buttons(ids, canMerge: canMerge)
            }
            VStack(alignment: .leading, spacing: 8) {
                count(ids.count)
                HStack(spacing: 8) { buttons(ids, canMerge: canMerge) }
            }
        }
        .padding(.vertical, 2)
    }

    private func count(_ number: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(number.formatted()) selected")
                .accessibilityAddTraits(.isHeader)
            if number < 2 {
                Text("Select two or more to merge them.")
            }
        }
        .font(Theme.Font.label)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func buttons(_ ids: [UUID], canMerge: Bool) -> some View {
        Button("Move to Trash") { moveToTrash(ids) }
            .accessibilityLabel("Move \(ids.count) credentials to Trash")
            .disabled(model.isBusy || ids.isEmpty)
        Button("Merge…") { merge(ids) }
            .accessibilityLabel("Merge \(ids.count) credentials")
            .disabled(model.isBusy || !canMerge)
            .help(canMerge ? "" : mergeRefusal(ids.count))
        Button("Select All (\(visibleCount.formatted()))") { selection.selectAll() }
        // Both end selection mode and deselect everything; "Done" reads better once Select started the mode.
        Button(selection.isSelecting ? "Done" : "Deselect All") { selection.clear() }
    }

    /// Why Merge… is off, in the sentences the merge sheet uses.
    private func mergeRefusal(_ count: Int) -> String {
        if count < 2 || count > CredentialAccount.mergedFromLimit {
            return String(localized: "Choose between 2 and \(CredentialAccount.mergedFromLimit) credentials to merge.")
        }
        return CredentialMergeError.usernamesDiffer.text
    }

    private func summaries(of ids: [UUID]) -> [CredentialSummary] {
        let wanted = Set(ids)
        return model.summaries.filter { wanted.contains($0.id) }
    }
}
