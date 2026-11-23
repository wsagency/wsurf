// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfVault

struct CredentialVaultMergeRow: View {
    let model: CredentialSettingsModel
    var showsAllVaults = false
    let open: () -> Void

    var body: some View {
        if showsAllVaults || model.canMergeIntoSharedVault {
            RowSeparator()
            DetailRow(title: "Copy or merge vault entries", caption: "Choose a source and destination. Review what to copy, replace or skip. The source vault is kept.") {
                SettingsButton(title: "Merge Vaults…", action: open)
                    .disabled(model.isBusy)
            }
        }
    }
}

/// The Autofill page replaces its vault rows when a passkey unlocks the destination. A stable page host keeps the review open.
struct CredentialVaultMergePresentation: ViewModifier {
    let model: CredentialSettingsModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            CredentialVaultMergeSheet(model: model)
        }
        .onDisappear { isPresented = false }
    }
}

private struct CredentialVaultMergeSheet: View {
    let model: CredentialSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var anchor = CredentialWindowAnchor()
    @State private var destination: CredentialSettingsModel?
    @State private var pickedSource: VaultMergeOption.ID?
    @State private var pickedDestination: VaultMergeOption.ID?
    @State private var review: VaultMergeReview?
    @State private var receipt: (destination: VaultMergeOption, applied: Int, skipped: Int)?
    @State private var destinationChoice: VaultMergeOption?
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    @State private var committing = false

    private var expired: Bool {
        guard let review, let destination else { return false }
        return !destination.isCurrentVaultMerge(review)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy or Merge Vault Entries").font(Theme.Font.rowTitle)
            if let receipt {
                LabeledContent("Destination vault") { Text(verbatim: receipt.destination.label) }
                if receipt.applied == 0 && receipt.skipped == 0 {
                    Text("The source vault has no current entries.")
                } else if receipt.applied == 0 {
                    Text("All entries were skipped. The destination vault was unchanged.")
                } else {
                    LabeledContent("Entries merged", value: receipt.applied, format: .number)
                }
                LabeledContent("Entries skipped", value: receipt.skipped, format: .number)
                Text(Self.sourceKept).font(Theme.Font.label).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else if let review, !expired {
                LabeledContent("Source vault") { Text(verbatim: review.sourceLabel) }
                LabeledContent("Destination vault") { Text(verbatim: review.destinationLabel) }
                VaultMergeReviewContent(review: review, busy: committing, message: $message, back: { self.review = nil }, cancel: close) { selection in
                    confirm(review, selection: selection)
                }
            } else if committing {
                ProgressView("Finishing the merge…").controlSize(.small)
            } else {
                if let message {
                    SettingsNotice(symbol: "exclamationmark.triangle", text: message)
                }
                VaultMergePicker(model: model, busy: work != nil, sourceID: $pickedSource, destinationID: $pickedDestination, cancel: close, choose: preview)
            }
        }
        .font(Theme.Font.row)
        .padding(20)
        .frame(width: 560)
        .background(CredentialWindowAnchorView(anchor: anchor))
        .interactiveDismissDisabled(committing)
        .onChange(of: expired) {
            if expired {
                review = nil
                message = String(localized: "A vault was locked or changed. Review its entries again.")
            }
        }
        .onDisappear {
            work?.cancel()
            review = nil
        }
    }

    static let sourceKept: LocalizedStringResource = "Only current entries are merged. The source vault keeps its entries, History and Trash."

    private func close() {
        work?.cancel()
        dismiss()
    }

    private func preview(_ source: VaultMergeOption, into target: VaultMergeOption) {
        guard work == nil else { return }
        guard let window = anchor.window, window.isVisible else {
            message = String(localized: "Couldn’t find this window to show the passkey prompt. Bring it to the front and try again.")
            return
        }
        message = nil
        work = Task {
            defer { work = nil }
            do {
                let destination = model.mergeDestinationModel(for: target)
                let selection = try destination.mergeSource(source, into: target)
                let prepared = try await destination.reviewVaultMerge(from: selection, in: window)
                try Task.checkCancellation()
                guard destination.isCurrentVaultMerge(prepared) else { throw CredentialVaultError.unauthorized }
                self.destination = destination
                destinationChoice = target
                review = prepared
            } catch {
                if !Task.isCancelled {
                    message = CredentialSettingsModel.message(for: error)
                }
            }
        }
    }

    private func confirm(_ review: VaultMergeReview, selection: VaultMergeSelection) {
        guard let destination, let destinationChoice, work == nil, selection.isComplete else { return }
        let skipped = selection.count(.skip)
        message = nil
        committing = true
        work = Task {
            defer {
                work = nil
                committing = false
            }
            do {
                let applied = try await destination.confirmVaultMerge(review, choices: selection.choices)
                try Task.checkCancellation()
                receipt = (destinationChoice, applied, skipped)
            } catch {
                if !Task.isCancelled {
                    if case CredentialVaultError.duplicateIdentifier = error, destination.isCurrentVaultMerge(review) {
                        message = String(localized: "These entries can’t be saved together. Skip one of the matching entries and try again.")
                        return
                    }
                    if let reason = CredentialSettingsModel.message(for: error) {
                        message = reason
                    } else if destination.isCurrentVaultMerge(review) {
                        // Cancelling the system prompt leaves the user's choices available for another try.
                        return
                    }
                }
            }
            self.review = nil
        }
    }
}

private struct VaultMergePicker: View {
    let model: CredentialSettingsModel
    let busy: Bool
    @Binding var sourceID: VaultMergeOption.ID?
    @Binding var destinationID: VaultMergeOption.ID?
    let cancel: () -> Void
    let choose: (VaultMergeOption, VaultMergeOption) -> Void
    @State private var vaults: [VaultMergeOption]?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        if let vaults, vaults.count >= 2 {
            picker("Source vault", selection: $sourceID, from: vaults.filter { $0.id != destinationID })
            picker("Destination vault", selection: $destinationID, from: vaults.filter { $0.id != sourceID && $0.destination.canBeDestination })
            Text("Add a shared vault to this Mac before copying its entries. WSurf asks you to unlock each locked vault before the review.")
                .font(Theme.Font.label).foregroundStyle(.secondary)
        } else if let error {
            SettingsNotice(symbol: "exclamationmark.triangle", text: error)
        } else if vaults != nil {
            Text("You need at least two credential vaults on this Mac.")
        } else {
            ProgressView("Finding vaults…").controlSize(.small)
        }
        HStack {
            if busy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
            if error != nil {
                Button("Try Again") { attempt += 1 }
            } else {
                let source = vaults?.first { $0.id == sourceID }
                let destination = vaults?.first { $0.id == destinationID && $0.destination.canBeDestination }
                Button("Review Entries") {
                    if let source, let destination, source.id != destination.id {
                        choose(source, destination)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || destination == nil || sourceID == destinationID || busy)
            }
        }
        .task(id: attempt) {
            error = nil
            do {
                let result = try await model.mergeOptions()
                try Task.checkCancellation()
                vaults = result
                if destinationID == nil, let id = model.selectedVaultID {
                    let current = VaultMergeOption.ID(profileID: model.profile.id, vaultID: id)
                    if sourceID != current, result.contains(where: { $0.id == current && $0.destination.canBeDestination }) {
                        destinationID = current
                    }
                }
                if sourceID == nil, let destinationID, result.count == 2 {
                    sourceID = result.first { $0.id != destinationID }?.id
                }
            } catch {
                if !Task.isCancelled {
                    self.error = CredentialSettingsModel.message(for: error)
                }
            }
        }
    }

    private func picker(_ title: LocalizedStringResource, selection: Binding<VaultMergeOption.ID?>, from vaults: [VaultMergeOption]) -> some View {
        Picker(selection: selection) {
            Text("Choose a vault").tag(VaultMergeOption.ID?.none)
            ForEach(vaults) { vault in
                Text("\(vault.label) — \(String(localized: vault.destination.label))")
                    .tag(Optional(vault.id))
            }
        } label: {
            Text(title)
        }
        .disabled(busy)
    }
}

/// Only the sheet's safe row metadata and the actions the user picked. Even a conflict whose only possible choice is Skip needs a click.
struct VaultMergeSelection {
    typealias Row = CredentialVaultMergePlan.Row
    typealias Choice = CredentialVaultMergePlan.Choice
    let rows: [Row]
    private let titlePeers: [String: [UUID]]
    var choices: [UUID: Choice] = [:]

    init(rows: [Row]) {
        self.rows = rows
        titlePeers = Dictionary(grouping: rows, by: \.title).mapValues { $0.map(\.id) }
        for row in rows {
            switch row.kind {
            case .new:
                choices[row.id] = .copy
            case .duplicate:
                choices[row.id] = .skip
            case .conflict:
                break
            }
        }
    }

    func title(of row: Row) -> String {
        guard let peers = titlePeers[row.title], peers.count > 1 else { return row.title }
        return "\(row.title) (\(row.id.shortestUniquePrefix(in: peers)))"
    }

    var problem: LocalizedStringResource? {
        var replaced = Set<UUID>()
        for row in rows {
            guard let choice = choices[row.id], row.choices.contains(choice) else {
                return "Choose what to do with every conflict first."
            }
            if choice == .replace, let target = row.targetID, !replaced.insert(target).inserted {
                return "Two entries would replace the same destination entry. Choose a different action for one of them."
            }
        }
        return nil
    }

    var isComplete: Bool {
        problem == nil
    }

    func count(_ choice: Choice) -> Int {
        choices.values.count { $0 == choice }
    }
}

private struct VaultMergeReviewContent: View {
    let review: VaultMergeReview
    let busy: Bool
    @Binding var message: String?
    let back: () -> Void
    let cancel: () -> Void
    let confirm: (VaultMergeSelection) -> Void
    @State private var selection: VaultMergeSelection
    @State private var confirming = false

    init(
        review: VaultMergeReview, busy: Bool, message: Binding<String?>,
        back: @escaping () -> Void, cancel: @escaping () -> Void, confirm: @escaping (VaultMergeSelection) -> Void
    ) {
        self.review = review
        self.busy = busy
        _message = message
        self.back = back
        self.cancel = cancel
        self.confirm = confirm
        _selection = State(initialValue: VaultMergeSelection(rows: review.rows))
    }

    var body: some View {
        Divider()
        if confirming {
            LabeledContent("Entries to copy", value: selection.count(.copy), format: .number)
            LabeledContent("Entries to replace", value: selection.count(.replace), format: .number)
            LabeledContent("Entries to skip", value: selection.count(.skip), format: .number)
            if selection.count(.replace) > 0 {
                Text("Each replacement overwrites the entire matching entry in the destination vault.")
            }
            Text(CredentialVaultMergeSheet.sourceKept)
                .font(Theme.Font.label).foregroundStyle(.secondary)
        } else {
            let rows = review.rows
            Text("New entries \(rows.count { $0.kind == .new }) · Duplicates \(rows.count { $0.kind == .duplicate }) · Conflicts \(rows.count { $0.kind == .conflict })")
                .font(Theme.Font.rowTitle)
            if rows.isEmpty {
                Text("The source vault has no current entries.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(rows, id: \.id) { row in
                            rowView(row)
                            Divider()
                        }
                    }
                }
                .frame(height: min(320, CGFloat(rows.count) * 88))
            }
            if let problem = selection.problem {
                Text(problem).font(Theme.Font.label)
            } else if let message {
                SettingsNotice(symbol: "exclamationmark.triangle", text: message)
            }
        }
        HStack {
            Button("Back") {
                if confirming {
                    confirming = false
                } else {
                    back()
                }
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            }
            Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
            if confirming {
                if selection.count(.skip) == review.rows.count {
                    Button("Finish Without Changes") { confirm(selection) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Confirm Merge") { confirm(selection) }.keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Continue") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!selection.isComplete)
            }
        }
        .disabled(busy)
        .onChange(of: message) {
            if message != nil {
                confirming = false
            }
        }
        .onChange(of: selection.choices) { message = nil }
    }

    private func rowView(_ row: VaultMergeSelection.Row) -> some View {
        let title = selection.title(of: row)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(Theme.Font.rowTitle)
                switch row.kind {
                case .new:
                    Text("New entry")
                case .duplicate:
                    Text("Exact duplicate")
                case .conflict:
                    Text("Conflict")
                }
                if !row.matches.isEmpty {
                    Text("Matches \(row.matches.formatted(.list(type: .and)))")
                }
                if !row.differences.isEmpty {
                    Text("Differences in \(row.differences.formatted(.list(type: .and)))")
                }
                if let reason = row.reason {
                    Text(verbatim: reason)
                }
            }
            .font(Theme.Font.label)
            Spacer(minLength: 8)
            if row.kind == .duplicate {
                Text("Skip").foregroundStyle(.secondary)
            } else {
                Picker("Action for \(title)", selection: $selection.choices[row.id]) {
                    if row.kind == .conflict {
                        Text("Choose an action").tag(VaultMergeSelection.Choice?.none)
                    }
                    ForEach(row.choices, id: \.self) { choice in
                        Text(label(choice, for: row)).tag(Optional(choice))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func label(_ choice: VaultMergeSelection.Choice, for row: VaultMergeSelection.Row) -> LocalizedStringResource {
        switch choice {
        case .copy:
            row.kind == .new ? "Copy" : "Copy as New Entry"
        case .skip:
            "Skip"
        case .replace:
            "Replace Entire Destination Entry"
        }
    }
}
