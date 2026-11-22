// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfVault

struct CredentialVaultMergeRow: View {
    let model: CredentialSettingsModel
    let open: () -> Void

    var body: some View {
        if model.canMergeIntoSharedVault {
            RowSeparator()
            DetailRow(title: "Merge another vault", caption: "Review entries from a vault on this Mac and choose which ones to add to this shared vault.") {
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
        .onChange(of: model.selectedVaultID) { isPresented = false }
        .onChange(of: model.canMergeIntoSharedVault) {
            if !model.canMergeIntoSharedVault {
                isPresented = false
            }
        }
        .onDisappear { isPresented = false }
    }
}

private struct CredentialVaultMergeSheet: View {
    let model: CredentialSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var anchor = CredentialWindowAnchor()
    @State private var review: VaultMergeReview?
    @State private var receipt: (applied: Int, skipped: Int)?
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    @State private var committing = false

    private var expired: Bool {
        review.map { !model.isCurrentVaultMerge($0) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge into Shared Vault").font(Theme.Font.rowTitle)
            if let receipt {
                LabeledContent("Shared destination") { Text(verbatim: model.vaultMergeDestinationLabel) }
                if receipt.applied == 0 && receipt.skipped == 0 {
                    Text("The source vault has no current entries.")
                } else if receipt.applied == 0 {
                    Text("All entries were skipped. The shared vault was unchanged.")
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
                LabeledContent("Shared destination") { Text(verbatim: review.destinationLabel) }
                VaultMergeReviewContent(review: review, busy: committing, message: $message, back: { self.review = nil }, cancel: close) { selection in
                    confirm(review, selection: selection)
                }
            } else if committing {
                ProgressView("Finishing the merge…").controlSize(.small)
            } else {
                LabeledContent("Shared destination") { Text(verbatim: model.vaultMergeDestinationLabel) }
                if let message {
                    SettingsNotice(symbol: "exclamationmark.triangle", text: message)
                }
                VaultMergeSourcePicker(model: model, busy: work != nil, cancel: close, choose: preview)
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

    private func preview(_ source: VaultMergeSource) {
        guard work == nil else { return }
        guard let window = anchor.window, window.isVisible else {
            message = String(localized: "Couldn’t find this window to show the passkey prompt. Bring it to the front and try again.")
            return
        }
        message = nil
        work = Task {
            defer { work = nil }
            do {
                let prepared = try await model.reviewVaultMerge(from: source, in: window)
                try Task.checkCancellation()
                guard model.isCurrentVaultMerge(prepared) else { throw CredentialVaultError.unauthorized }
                review = prepared
            } catch {
                if !Task.isCancelled {
                    message = CredentialSettingsModel.message(for: error)
                }
            }
        }
    }

    private func confirm(_ review: VaultMergeReview, selection: VaultMergeSelection) {
        guard work == nil, selection.isComplete else { return }
        let skipped = selection.count(.skip)
        message = nil
        committing = true
        work = Task {
            defer {
                work = nil
                committing = false
            }
            do {
                let applied = try await model.confirmVaultMerge(review, choices: selection.choices)
                try Task.checkCancellation()
                receipt = (applied, skipped)
            } catch {
                if !Task.isCancelled {
                    if case CredentialVaultError.duplicateIdentifier = error, model.isCurrentVaultMerge(review) {
                        message = String(localized: "These entries can’t be saved together. Skip one of the matching entries and try again.")
                        return
                    }
                    if let reason = CredentialSettingsModel.message(for: error) {
                        message = reason
                    } else if model.isCurrentVaultMerge(review) {
                        // Cancelling the system prompt leaves the user's choices available for another try.
                        return
                    }
                }
            }
            self.review = nil
        }
    }
}

private struct VaultMergeSourcePicker: View {
    let model: CredentialSettingsModel
    let busy: Bool
    let cancel: () -> Void
    let choose: (VaultMergeSource) -> Void
    @State private var sources: [VaultMergeSource]?
    @State private var picked: VaultMergeSource.ID?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        if let sources, !sources.isEmpty {
            Picker("Source vault", selection: $picked) {
                Text("Choose a vault on this Mac").tag(VaultMergeSource.ID?.none)
                ForEach(sources) { source in
                    Text(verbatim: source.label).tag(Optional(source.id))
                }
            }
            .disabled(busy)
            Text("Choose a profile and vault. WSurf asks for the unlock passkey of each locked vault before showing its entries.")
                .font(Theme.Font.label).foregroundStyle(.secondary)
        } else if let error {
            SettingsNotice(symbol: "exclamationmark.triangle", text: error)
        } else if sources != nil {
            Text("There are no other credential vaults on this Mac.")
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
                let selected = sources?.first { $0.id == picked }
                Button("Review Entries") {
                    if let selected {
                        choose(selected)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || busy)
            }
        }
        .task(id: attempt) {
            error = nil
            do {
                let result = try await model.mergeSources()
                try Task.checkCancellation()
                sources = result
                picked = result.count == 1 ? result[0].id : nil
            } catch {
                if !Task.isCancelled {
                    self.error = CredentialSettingsModel.message(for: error)
                }
            }
        }
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
                return "Two entries would replace the same shared entry. Choose a different action for one of them."
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
                Text("Each replacement overwrites the entire matching entry in the shared vault.")
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
