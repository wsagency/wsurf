// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - Wording

extension CredentialImportReview.Group {
    var title: LocalizedStringResource {
        switch self {
        case .decide:
            "Needs your decision"
        case .merge:
            "Suggested merges"
        case .new:
            "New"
        case .update:
            "Changed in the other app"
        case .saved:
            "Already saved"
        case .skipped:
            "Skipped"
        }
    }

    /// What the group's menu can do to every item of the group at once.
    var bulkActions: [(action: CredentialImportReview.ItemAction, title: LocalizedStringResource)] {
        switch self {
        case .decide:
            [(.keepSaved, "Keep All Saved"), (.skip, "Skip All")]
        case .new:
            [(.importNew, "Import All New"), (.skip, "Skip All")]
        case .update:
            [(.useIncoming, "Use All Incoming"), (.keepSaved, "Keep All Saved")]
        case .saved:
            [(.keepSaved, "Keep All Unchanged")]
        case .merge:
            [(.mergeIntoSaved, "Merge All Suggested"), (.importNew, "Import All as New"), (.skip, "Skip All")]
        case .skipped:
            []
        }
    }
}

extension CredentialImportReview.Duplicate.Addition {
    /// What a merge adds, as one phrase of the row's sentence.
    var text: String {
        switch self {
        case let .websites(count):
            if count == 1 {
                return String(localized: "a website")
            }
            return String(localized: "\(count) websites")
        case let .passkeys(count):
            if count == 1 {
                return String(localized: "a passkey")
            }
            return String(localized: "\(count) passkeys")
        case .code:
            return String(localized: "a verification code")
        case let .notes(count):
            if count == 1 {
                return String(localized: "a note")
            }
            return String(localized: "\(count) notes")
        }
    }
}

extension CredentialImportReview.Candidate {
    /// What the action is called on this item's menu.
    func title(of action: CredentialImportReview.ItemAction) -> LocalizedStringResource {
        switch action {
        case .mergeIntoSaved:
            "Merge into “\(duplicate?.title ?? "")”"
        case .importNew where duplicate != nil:
            "Import as New"
        case .importNew:
            switch group {
            case .decide:
                "Add Separately"
            case .skipped:
                "Import Anyway"
            default:
                "Import"
            }
        case .keepSaved:
            "Keep Saved"
        case .useIncoming:
            "Use Incoming"
        case .keepBoth:
            "Keep Both"
        case .skip:
            "Skip"
        }
    }

    /// What the item does now, as the label of its menu.
    var currentTitle: LocalizedStringResource {
        switch effect {
        case .undecided:
            "Choose…"
        case .new:
            "Import"
        case .update:
            "Use Incoming"
        case .merge:
            "Merge"
        case .unchanged, .linked:
            "Keep Saved"
        case .skipped:
            "Skip"
        }
    }

    /// The websites, username and parts of the item, in the order a person looks for them.
    var identityLine: String? {
        var parts: [String] = []
        if summary.usernameIsConcealed {
            parts.append(String(localized: "Username hidden"))
        } else if let username = summary.username {
            parts.append(username)
        }
        if let host = summary.origins.lazy.compactMap({ URL(string: $0)?.host }).first {
            let more = summary.origins.count - 1
            parts.append(more > 0 ? "\(host) " + String(localized: "+\(more) more") : host)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var partsLine: String {
        var parts: [String] = []
        if summary.hasLogin {
            parts.append(String(localized: "Login"))
        }
        switch summary.passkeys.count {
        case 0:
            break
        case 1:
            parts.append(String(localized: "Passkey"))
        case let count:
            parts.append(String(localized: "\(count) passkeys"))
        }
        if summary.hasTOTP {
            parts.append(String(localized: "Verification code"))
        }
        if summary.hasNotes {
            parts.append(String(localized: "Notes"))
        }
        return parts.joined(separator: " · ")
    }

    /// One sentence on why the item is where it is and what will happen to it.
    var statusLine: String {
        switch effect {
        case .undecided:
            guard let record = records.first(where: { $0.needsChoice && $0.choice == nil }) else { return "" }
            if record.classification == .bothChanged {
                return String(localized: "Changed here and in the other app since the last import.")
            }
            if let existing = record.existingTitle {
                if record.classification == .unchanged || record.classification == .localChanged {
                    return String(localized: "Already saved as “\(existing)”. Choose what to do with the rest of this item.")
                }
                return String(localized: "Already saved as “\(existing)”, with a different value.")
            }
            return String(localized: "Other logins have this website and username with a different password.")
        case .update:
            return String(localized: "Changed in the other app. Its version is used, and yours is kept as an earlier version.")
        case .new:
            if group == .skipped {
                return String(localized: "Will be imported anyway.")
            }
            if let duplicate {
                return String(localized: "Saved as a separate credential, although “\(duplicate.title)” already holds it.")
            }
            return linkedAccountID == nil
                ? String(localized: "Not saved yet.") : String(localized: "Adds to a credential that is already saved.")
        case .merge:
            guard let duplicate, duplicate.isApplied(by: records) else { return String(localized: "Merged into a saved credential.") }
            let added = duplicate.additions.map(\.text).formatted(.list(type: .and))
            let same = records.contains { $0.kind == .password }
                ? String(localized: "Same website, username and password as “\(duplicate.title)”.")
                : String(localized: "Same passkey as “\(duplicate.title)”.")
            return same + " " + String(localized: "Adds \(added).")
        case .linked:
            return String(localized: "Already saved as “\(duplicate?.title ?? "")”. Import links the two, so the next import finds it unchanged.")
        case .unchanged:
            if let duplicate {
                return String(localized: "Already saved as “\(duplicate.title)”. Nothing changes.")
            }
            if records.contains(where: { $0.classification == .localChanged }) {
                return String(localized: "Changed here since the last import. Your version stays.")
            }
            return String(localized: "Already saved. Nothing changes.")
        case .skipped:
            if records.contains(where: { $0.classification == .passkeyHardConflict }) {
                return String(localized: "A passkey with the same ID but another key is already saved, so it isn’t imported.")
            }
            if records.contains(where: { if case .previouslyRemoved = $0.classification { true } else { false } }) {
                return String(localized: "Removed from this vault before, so it isn’t imported unless you choose to.")
            }
            return String(localized: "Won’t be imported.")
        }
    }

    /// Whether the row has anything to show beyond its own line: several parts, or a saved credential to compare with.
    var hasDetails: Bool {
        records.count > 1 || hasConflict || records.contains { $0.csvLine != nil && $0.needsChoice }
    }
}

// MARK: - Sheet

/// Which items the list shows.
private enum ImportReviewFilter: Hashable {
    case all
    case group(CredentialImportReview.Group)
    case hasOmissions
}

/// The rows of one group that match the search and the filter.
private struct ImportReviewSection: Identifiable {
    let group: CredentialImportReview.Group
    let ids: [UUID]
    var id: Int {
        group.rawValue
    }
}

/// What the list was computed for: it is computed again only when one of these changes, never for a decision.
private struct ImportReviewListKey: Hashable {
    let query: String
    let filter: ImportReviewFilter
    let items: Int
}

/// A part whose destination the user is picking from the list of saved credentials.
private struct ImportMergeRequest: Identifiable {
    let id = UUID()
    let incoming: CredentialIdentity
    let kind: CredentialImportReview.Record.Kind
}

struct CredentialImportReviewSheet: View {
    let model: CredentialSettingsModel
    let run: (@escaping () async throws -> Void) -> Void
    @State private var query = ""
    @State private var filter = ImportReviewFilter.all
    @State private var shown: [ImportReviewSection] = []
    @State private var itemsWithOmissions = 0
    @State private var collapsed: Set<CredentialImportReview.Group> = []
    @State private var started = false
    @State private var mergeRequest: ImportMergeRequest?

    var body: some View {
        if let review = model.importReview {
            VStack(alignment: .leading, spacing: 14) {
                Text("Review Import").font(.headline)
                Text(verbatim: destination(review))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report = review.csvReport {
                    csvReportView(report, entries: review.origin == .legacyPasswords)
                }
                if !review.unattachedOmissions.isEmpty {
                    omittedView(review.unattachedOmissions)
                }
                if review.candidates.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    toolbar(review)
                    list(review.origin)
                }
                Text(verbatim: footer(review.tally)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.error {
                    Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                buttons(review)
            }
            .padding(24)
            .frame(minWidth: 720, idealWidth: 760, minHeight: 520, idealHeight: 640)
            .task(id: ImportReviewListKey(query: query, filter: filter, items: review.candidates.count)) {
                refresh(review)
            }
            .sheet(item: $mergeRequest) { request in
                CredentialImportMergeSheet(model: model, incoming: request.incoming, kind: request.kind)
            }
        }
    }

    // MARK: Search and filters

    private func toolbar(_ review: CredentialImportReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search by name, username or website", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", count: review.candidates.count, value: .all)
                    ForEach(CredentialImportReview.Group.allCases, id: \.self) { group in
                        if let count = review.sections[group]?.count, count > 0 {
                            chip(group.title, count: count, value: .group(group))
                        }
                    }
                    if itemsWithOmissions > 0 {
                        chip("Has parts not imported", count: itemsWithOmissions, value: .hasOmissions)
                    }
                }
            }
        }
    }

    private func chip(_ title: LocalizedStringResource, count: Int, value: ImportReviewFilter) -> some View {
        Toggle(isOn: Binding(get: { filter == value }, set: { _ in filter = value })) {
            Text(verbatim: "\(String(localized: title)) \(count)")
        }
        .toggleStyle(.button)
        .controlSize(.small)
    }

    /// Computes what the list shows. Runs when the search or the filter changes, not when a decision is made: a decision changes a
    /// row, and a row never moves.
    private func refresh(_ review: CredentialImportReview) {
        if !started {
            started = true
            // A long list of what needs nothing from the user starts closed.
            for group in [CredentialImportReview.Group.saved, .skipped] where (review.sections[group]?.count ?? 0) > 50 {
                collapsed.insert(group)
            }
        }
        itemsWithOmissions = review.candidates.reduce(0) { $0 + ($1.omissions.isEmpty ? 0 : 1) }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var result: [ImportReviewSection] = []
        for group in CredentialImportReview.Group.allCases {
            if case let .group(only) = filter, only != group {
                continue
            }
            var positions = review.sections[group] ?? []
            if filter == .hasOmissions {
                positions = positions.filter { !review.candidates[$0].omissions.isEmpty }
            }
            if !needle.isEmpty {
                positions = positions.filter { review.candidates[$0].searchKey.contains(needle) }
            }
            if !positions.isEmpty {
                result.append(ImportReviewSection(group: group, ids: positions.map { review.candidates[$0].id }))
            }
        }
        shown = result
    }

    // MARK: List

    private func list(_ origin: CredentialTransferMessage.Origin) -> some View {
        ScrollView {
            // Lazy: a real library is thousands of rows, and only the few on screen are built.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(shown) { section in
                    Section {
                        if !collapsed.contains(section.group) {
                            ForEach(section.ids, id: \.self) { id in
                                CredentialImportRow(model: model, id: id) { incoming, kind in
                                    mergeRequest = ImportMergeRequest(incoming: incoming, kind: kind)
                                }
                            }
                        }
                    } header: {
                        header(section)
                    }
                }
                if shown.isEmpty {
                    Text("Nothing matches.").foregroundStyle(.secondary).padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The overlay scroller draws over the right edge of the content; keeping the content clear of it keeps every control usable.
        .contentMargins(.trailing, 16, for: .scrollContent)
        .frame(maxHeight: .infinity)
    }

    private func header(_ section: ImportReviewSection) -> some View {
        let isCollapsed = collapsed.contains(section.group)
        return HStack(spacing: 8) {
            Button {
                if isCollapsed {
                    collapsed.remove(section.group)
                } else {
                    collapsed.insert(section.group)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(Theme.Font.badge)
                        .frame(width: 10)
                    Text(section.group.title).font(Theme.Font.title)
                    Text(verbatim: "\(section.ids.count)").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(section.group.title))
            .accessibilityValue(Text(verbatim: "\(section.ids.count)"))
            Spacer(minLength: 8)
            let bulk = section.group.bulkActions
            if !bulk.isEmpty {
                Menu {
                    ForEach(Array(bulk.enumerated()), id: \.offset) { _, entry in
                        Button(entry.title) { model.chooseImportGroup(entry.action, in: section.group) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(Text("Actions for all"))
            }
        }
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    // MARK: Footer and buttons

    private func footer(_ tally: CredentialImportReview.Tally) -> String {
        var text = String(localized: "Imports \(tally.new) new, updates \(tally.updates + tally.merges), leaves \(tally.unchanged + tally.linked) unchanged, skips \(tally.skipped).")
        if tally.undecided > 0 {
            text += " " + String(localized: "Needs your decision: \(tally.undecided).")
        }
        return text
    }

    private func buttons(_ review: CredentialImportReview) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.error = nil; model.cancelImport() }
                .keyboardShortcut(.cancelAction)
            if review.origin == .legacyPasswords, review.isResolved, review.tally.writes == 0 {
                // Every password of the old list was skipped or is already saved. Continuing is a decision about the removal that
                // follows, not an import.
                Button("Continue") { run { await model.continueLegacyImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            } else {
                Button("Import") { run { await model.commitImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!review.isResolved || review.tally.writes == 0 || model.isBusy)
            }
        }
    }

    // MARK: Header text

    /// What the file held beyond what will be imported, before anything is saved. Counts are of the file as read; the receipt
    /// after Import reports what was actually saved. Line numbers and fixed wording only: nothing from the file itself.
    private func csvReportView(_ report: CredentialCSVReport, entries: Bool) -> some View {
        let shown = report.issues.prefix(20)
        return VStack(alignment: .leading, spacing: 4) {
            if entries {
                Text("The old Passwords list has \(report.rowsRead) passwords. \(report.alreadySaved) already saved here, \(report.omittedRows) can’t be imported.")
            } else {
                Text("The file has \(report.rowsRead) rows. \(report.alreadySaved) already saved here, \(report.omittedRows) can’t be imported.")
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, issue in
                if entries {
                    Text(verbatim: "\(String(localized: "Entry")) \(issue.line): \(issue.reason.entryText)")
                } else {
                    Text(verbatim: "\(String(localized: "Line")) \(issue.line): \(issue.reason.text)")
                }
            }
            if report.issues.count > shown.count {
                if entries {
                    Text("and \(report.issues.count - shown.count) more entries with notes.")
                } else {
                    Text("and \(report.issues.count - shown.count) more lines with notes.")
                }
            }
            if !report.ignoredColumns.isEmpty {
                Text("Columns \(report.ignoredColumns.map(String.init).joined(separator: ", ")) hold data WSurf doesn’t import.")
            }
        }
        .font(Theme.Font.label)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What the transfer held that WSurf won't import and that belongs to no row, before anything is saved. The parts of an item are
    /// listed under its row. Fixed wording and item titles only: no values.
    private func omittedView(_ omitted: [CredentialImportOmission]) -> some View {
        let shown = omitted.prefix(20)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Not imported").fontWeight(.medium)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, omission in
                Text(verbatim: omission.text)
            }
            if omitted.count > shown.count {
                Text("and \(omitted.count - shown.count) more.")
            }
        }
        .font(Theme.Font.label)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func destination(_ review: CredentialImportReview) -> String {
        guard let vault = review.vaultName else {
            return String(localized: """
                Importing into the profile “\(review.profileName)”. Nothing is saved until you choose Import. \
                Imported passwords, passkeys, verification codes and notes are encrypted in that profile’s vault.
                """)
        }
        return String(localized: """
            Importing into the vault “\(vault)” of the profile “\(review.profileName)”. Nothing is saved until you \
            choose Import. Imported passwords, passkeys, verification codes and notes are encrypted in that vault.
            """)
    }
}

// MARK: - Row

/// One item of the import: one row with its login, passkeys, code, notes and websites together. It reads only its own item, so a
/// decision elsewhere in the list costs this row nothing.
private struct CredentialImportRow: View {
    let model: CredentialSettingsModel
    let id: UUID
    let pickTarget: (CredentialIdentity, CredentialImportReview.Record.Kind) -> Void
    @State private var showsDetails = false

    var body: some View {
        if let candidate = model.importCandidate(withID: id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: candidate.summary.title).font(Theme.Font.rowTitle)
                        if let line = candidate.identityLine {
                            Text(verbatim: line).font(Theme.Font.label).foregroundStyle(.secondary)
                        }
                        Text(verbatim: candidate.partsLine).font(Theme.Font.label).foregroundStyle(.secondary)
                        let status = candidate.statusLine
                        if !status.isEmpty {
                            Text(verbatim: status)
                                .font(Theme.Font.label)
                                .foregroundStyle(candidate.effect == .undecided ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if candidate.needsManualAssociation {
                            Text("The other app sent no website for this.")
                                .font(Theme.Font.label)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(candidate.omissions.enumerated()), id: \.offset) { _, omission in
                            Text(verbatim: omission.text)
                                .font(Theme.Font.label)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    control(candidate)
                }
                if candidate.hasDetails {
                    DisclosureGroup("Details", isExpanded: $showsDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(candidate.records) { record in partView(record, candidate: candidate) }
                        }
                        .padding(.top, 4)
                    }
                    .font(Theme.Font.label)
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            Divider()
        }
    }

    // MARK: Item control

    @ViewBuilder
    private func control(_ candidate: CredentialImportReview.Candidate) -> some View {
        if candidate.group == .decide {
            // No preselection: the user has to look at it.
            Picker("", selection: Binding<CredentialImportReview.ItemAction?>(
                get: { candidate.action },
                set: { action in
                    if let action {
                        model.chooseImportItem(action, for: candidate.id)
                    }
                }
            )) {
                ForEach(candidate.availableActions, id: \.self) { action in
                    Text(candidate.title(of: action)).tag(Optional(action))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } else {
            Menu {
                ForEach(candidate.availableActions, id: \.self) { action in
                    Button(candidate.title(of: action)) { model.chooseImportItem(action, for: candidate.id) }
                }
                if let single = singlePart(candidate) {
                    Divider()
                    Button("Merge Into…") { pickTarget(single.incoming, single.kind) }
                }
            } label: {
                Text(candidate.currentTitle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// An item with a single part besides its notes can be merged into a saved credential as a whole; a bigger one is merged part by
    /// part, in its details.
    private func singlePart(_ candidate: CredentialImportReview.Candidate) -> CredentialImportReview.Record? {
        let parts = candidate.records.filter { $0.kind != .note }
        return parts.count == 1 ? parts.first : nil
    }

    // MARK: Details

    private func partView(_ record: CredentialImportReview.Record, candidate: CredentialImportReview.Candidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.kind.label).font(Theme.Font.label).fontWeight(.medium)
                if let existing = record.existingTitle {
                    Text("Already saved as “\(existing)”").font(Theme.Font.label).foregroundStyle(.secondary)
                    if record.removesStoredPasswordOnReplace {
                        Text("Replace Saved removes the password saved for “\(existing)”. The other app’s login has none.")
                            .font(Theme.Font.label)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if record.needsChoice, record.existingTitle == nil {
                    Text("Other logins have this website and username with a different password. Choose Skip or Add Separately for each.")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if record.needsChoice, let line = record.csvLine {
                    if model.importReview?.origin == .legacyPasswords {
                        Text("Entry \(line) of the old list").font(Theme.Font.label).foregroundStyle(.secondary)
                    } else {
                        Text("Line \(line) of the file").font(Theme.Font.label).foregroundStyle(.secondary)
                    }
                }
                if let line = destinationLine(record) {
                    Text(verbatim: line)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if record.needsChoice {
                Menu {
                    Button("Skip") { model.chooseImport(.skip, for: record.incoming) }
                    if record.isConflict {
                        Button("Replace Saved") { model.chooseImport(.replace, for: record.incoming) }
                    }
                    if record.canAddSeparately {
                        Button("Add Separately") { model.chooseImport(.addSeparately, for: record.incoming) }
                    }
                    Button("Merge Into…") { pickTarget(record.incoming, record.kind) }
                } label: {
                    Text(choiceLabel(record))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    /// Where the part will be saved and which websites it will work on, as the import itself will do it. A stored account
    /// keeps exactly its own websites; the other app's are only ever listed here to say they are not added.
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
            "Choose…"
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

// MARK: - Merge target

/// The saved credentials a part can be merged into, listed and searched. The list is built once, when the sheet opens: finding the
/// accounts that can take a part means looking at the whole vault, so no row does it for itself.
private struct CredentialImportMergeSheet: View {
    let model: CredentialSettingsModel
    let incoming: CredentialIdentity
    let kind: CredentialImportReview.Record.Kind
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [CredentialImportReview.Target]?
    @State private var query = ""

    private var matches: [CredentialImportReview.Target] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return targets ?? [] }
        return (targets ?? []).filter {
            ([$0.title] + $0.allowedOrigins).joined(separator: "\n")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Into…").font(.headline)
            if targets == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else if targets?.isEmpty == true {
                Text("No saved credential can take this.").foregroundStyle(.secondary)
            } else {
                TextField("Search saved credentials", text: $query).textFieldStyle(.roundedBorder)
                List(matches) { target in
                    Button {
                        model.chooseImport(.merge(into: target.accountID), for: incoming)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: target.title)
                            if kind != .passkey {
                                Text(verbatim: websites(of: target))
                                    .font(Theme.Font.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
        .task {
            if targets == nil {
                targets = model.mergeTargets(for: incoming)
            }
        }
    }

    /// A merged credential works on the websites of the saved one it joins, and the sheet says which they are.
    private func websites(of target: CredentialImportReview.Target) -> String {
        target.allowedOrigins.isEmpty
            ? String(localized: "No approved website")
            : target.allowedOrigins.joined(separator: ", ")
    }
}
