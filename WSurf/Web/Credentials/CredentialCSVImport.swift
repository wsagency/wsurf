// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WSurfVault

/// What a CSV file holds beyond what will be imported, shown in the review BEFORE the user confirms. Line numbers and fixed
/// reasons only: no field, header text or password is ever kept here. These are counts of the file as read (staged); what was
/// actually saved is the committed outcome the import reports afterwards.
nonisolated struct CredentialCSVReport: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// The row is not imported.
        case unsupportedWebsite, missingPassword, passwordTooLong, wrongFieldCount, invalidRow
        /// An earlier row has the same website, username and password.
        case duplicateInFile(firstLine: Int)
        /// The row is staged, but this column of it is not imported: a CSV import carries passwords and notes.
        case oneTimeCodeNotImported
        /// Several saved logins have this website and username, so no Replace target is offered: Skip or Add Separately.
        case matchesSeveralSaved
        /// An earlier row has the same website and username with another password. Every such row needs a choice in the review.
        case conflictsWithEarlierRow(line: Int)

        var omitsRow: Bool {
            switch self {
            case .unsupportedWebsite, .missingPassword, .passwordTooLong, .wrongFieldCount, .invalidRow, .duplicateInFile:
                true
            case .oneTimeCodeNotImported, .conflictsWithEarlierRow, .matchesSeveralSaved:
                false
            }
        }

        /// The wording for an entry of the passwords saved before Credential Manager, which have entry numbers, not file lines.
        var entryText: String {
            switch self {
            case let .duplicateInFile(first):
                String(localized: "not imported: same as entry \(first).")
            case let .conflictsWithEarlierRow(entry):
                String(localized: "same website and username as entry \(entry) with another password. Choose what to do with each of them.")
            default:
                text
            }
        }

        /// Fixed wording: never a field of the file.
        var text: String {
            switch self {
            case .unsupportedWebsite:
                String(localized: "not imported: the website is missing or isn’t a secure https address.")
            case .missingPassword:
                String(localized: "not imported: there is no password.")
            case .passwordTooLong:
                String(localized: "not imported: the password is too long.")
            case .wrongFieldCount:
                String(localized: "not imported: the row doesn’t match the header.")
            case .invalidRow:
                String(localized: "not imported: the row can’t be saved.")
            case let .duplicateInFile(first):
                String(localized: "not imported: same as line \(first).")
            case .oneTimeCodeNotImported:
                String(localized: "this row has a verification code, which isn’t imported. Set it up again with the website.")
            case let .conflictsWithEarlierRow(line):
                String(localized: "same website and username as line \(line) with another password or note. Choose what to do with each of them.")
            case .matchesSeveralSaved:
                String(localized: "several saved logins have this website and username. Choose Skip or Add Separately.")
            }
        }
    }

    struct Issue: Sendable, Equatable {
        let line: Int
        let reason: Reason
    }

    /// Data rows in the file, not counting the header.
    var rowsRead = 0
    /// Rows whose website, username and password are already saved: left alone, nothing to do.
    var alreadySaved = 0
    /// 1-based positions of columns that were not recognised but hold data. The header text itself is never kept.
    var ignoredColumns: [Int] = []
    var issues: [Issue] = []

    var omittedRows: Int {
        issues.filter(\.reason.omitsRow).count
    }
}

/// An Apple Passwords CSV as an import: header-driven (URL, Username and Password columns, any order), password logins with their
/// notes. A row's note is one note of that login.
/// Its candidates are built here rather than through the exchange codec so they carry no exchange identifiers, no exporter
/// metadata and no timestamps: the file says nothing about when anything was created or changed, and nothing may be invented.
nonisolated enum CredentialCSVImport {
    struct Staged: Sendable {
        let preview: CredentialImportPreview
        let classes: [CredentialIdentity: CredentialImportClass]
        let report: CredentialCSVReport
        /// Rows that must be decided in the review before Import is possible, besides the conflicts in `preview`: a row that
        /// shares its website and username with another row of the file, or with several saved logins, while having a
        /// different password. Skip or Add Separately is the user's call; nothing is imported or dropped by default.
        let needsChoice: Set<CredentialIdentity>
        /// The file line each staged row came from, so a review row can be told from another with the same title.
        let lines: [CredentialIdentity: Int]
        /// What each staged row brought, for the vault to remember (`ImportTrace`), by candidate. Empty without `Memory`.
        var traces: [UUID: RowTrace] = [:]
        /// The saved credential each row that was merged away into it before now stands beside, by candidate.
        var mergedInto: [UUID: UUID] = [:]
    }

    /// What the vault remembers of earlier imports, for a file staged against it: its import memory key and what it removed (with the
    /// traces of the removed accounts).
    struct Memory: Sendable {
        let key: ImportMemoryKey
        let removed: RemovedIdentifiers
    }

    /// What one row brought, as keyed digests, and where it is remembered once imported: in the saved credential `target` it matched
    /// (in that credential's link to `link` when the row is an entry merged into it), else in the new credential the row becomes.
    struct RowTrace: Sendable, Equatable {
        let trace: ImportTrace
        let target: UUID?
        let link: UUID?
    }

    /// Why a row with no saved login is not new: the entry it stands for was merged into `survivor` (the merged entry's id, and what it
    /// stood for), or deleted (`entryID` in the Trash, or a tombstone).
    private enum Remembered {
        case merged(survivor: CredentialAccount, absorbed: UUID, trace: ImportTrace?, entryID: UUID?)
        case removed(entryID: UUID, isTombstone: Bool)
    }

    /// What the vault remembers about one row: what the row brings, the entry it stands for when no saved login has its website and
    /// username, and the last import's trace of the saved login it is compared with (its own, or its link's to an entry merged into it).
    private struct Recall {
        let trace: ImportTrace
        var earlier: Remembered?
        var base: ImportTrace?
        /// For a row of an entry merged away and changed since: the credential it went into, which the row is compared with, and the
        /// entry's id.
        var survivor: CredentialAccount?
        var link: UUID?
    }

    private typealias Relation = (conflicts: [CredentialImportConflict], classes: [CredentialIdentity: CredentialImportClass])

    /// Text compared and hashed as its exact UTF-8 bytes. Swift's `String ==` also equates canonically equivalent spellings
    /// ("é" and "e" + U+0301), which a server can treat as two different usernames or passwords.
    private struct ExactText: Hashable {
        let value: String

        init(_ value: String) {
            self.value = value
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.value.utf8.elementsEqual(rhs.value.utf8)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(value.utf8.count)
            for byte in value.utf8 {
                hasher.combine(byte)
            }
        }
    }

    /// The same login: the same website and exactly the same username. A structured key, so no value can run into another.
    private struct LoginKey: Hashable {
        let origin: String
        let username: ExactText
    }

    private struct LoginAndPassword: Hashable {
        let login: LoginKey
        let password: ExactText
        /// Rows that differ only in their note are two rows: dropping one would drop its note.
        let note: ExactText
    }

    /// Where the recognised columns are. A header that names one twice has no single right column to read, so the file is
    /// refused rather than the first one picked.
    private struct Columns {
        let url: Int
        let username: Int
        let password: Int
        let title: Int?
        let notes: Int?
        let code: Int?
        /// Every recognised position; the other columns are reported, by position only, when they hold data.
        let known: Set<Int>

        init(names: [String]) throws {
            func column(_ options: Set<String>) throws -> Int? {
                let found = names.indices.filter { options.contains(names[$0]) }
                guard found.count <= 1 else { throw CredentialCSVError.ambiguousColumns }
                return found.first
            }
            let foundURL = try column(["url"]), foundUsername = try column(["username"]), foundPassword = try column(["password"])
            title = try column(["title", "name"])
            notes = try column(["notes", "note"])
            code = try column(["otpauth"])
            guard let foundURL, let foundUsername, let foundPassword else { throw CredentialCSVError.missingColumns }
            url = foundURL
            username = foundUsername
            password = foundPassword
            known = Set([foundURL, foundUsername, foundPassword] + [title, notes, code].compactMap { $0 })
        }
    }

    static func stage(_ data: Data, against base: StoreSnapshot, memory: Memory? = nil) throws -> Staged {
        try stage(rows: CredentialCSV.parse(data), against: base, memory: memory)
    }

    /// The passwords saved before Credential Manager, staged by the same rules as a CSV of them: each entry is one row, numbered
    /// from 1 in list order, so the review can tell two entries of one website apart. Nothing about the list is kept in the report
    /// beyond counts and these numbers.
    static func stage(legacy records: [SavedPassword], against base: StoreSnapshot, memory: Memory? = nil) throws -> Staged {
        let header = CredentialCSV.Row(line: 0, fields: ["URL", "Username", "Password"])
        let entries = records.enumerated().map {
            CredentialCSV.Row(line: $0.offset + 1, fields: [$0.element.origin, $0.element.username, $0.element.password])
        }
        return try stage(rows: [header] + entries, against: base, memory: memory)
    }

    /// With `memory`, a row is compared with what the last import brought too (`ImportTrace`): a saved login it changed only in the
    /// other app is an update, one changed only here is kept, and one changed in both waits for the user; a row whose entry was merged
    /// into a saved credential is that credential's, and one whose entry was deleted is left out unless the user brings it back.
    static func stage(rows: [CredentialCSV.Row], against base: StoreSnapshot, memory: Memory? = nil) throws -> Staged {
        guard let header = rows.first else { throw CredentialCSVError.missingColumns }
        let names = header.fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let columns = try Columns(names: names)

        let saved = savedLogins(base.accounts)
        var report = CredentialCSVReport()
        var ignored = Set<Int>()
        var candidates: [CredentialAccount] = []
        var conflicts: [CredentialImportConflict] = []
        var classes: [CredentialIdentity: CredentialImportClass] = [:]
        var lines: [CredentialIdentity: Int] = [:]
        var seen: [LoginAndPassword: Int] = [:]
        var firstLine: [LoginKey: Int] = [:]
        var staged: [(identity: CredentialIdentity, key: LoginKey)] = []
        var rowsPerLogin: [LoginKey: Int] = [:]
        var traces: [UUID: RowTrace] = [:]
        var mergedInto: [UUID: UUID] = [:]
        let remembered = memory.map { Self.remembered(in: base.accounts, removed: $0.removed) } ?? [:]

        for row in rows.dropFirst() {
            report.rowsRead += 1
            func note(_ reason: CredentialCSVReport.Reason) {
                report.issues.append(.init(line: row.line, reason: reason))
            }
            guard row.fields.count == names.count else { note(.wrongFieldCount); continue }
            let fields = row.fields
            for (index, value) in fields.enumerated() where !columns.known.contains(index) && !value.isEmpty {
                ignored.insert(index + 1)
            }
            guard let login = website(fields[columns.url]), let origin = CredentialAccount.origin(for: login) else {
                note(.unsupportedWebsite)
                continue
            }
            let username = fields[columns.username]
            let password = fields[columns.password]
            guard !password.isEmpty else { note(.missingPassword); continue }
            guard password.utf8.count <= 4_096 else { note(.passwordTooLong); continue }
            let noteText = columns.notes.map { fields[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            if let code = columns.code, !fields[code].isEmpty {
                note(.oneTimeCodeNotImported)
            }

            let key = LoginKey(origin: origin, username: ExactText(username))
            let exact = LoginAndPassword(login: key, password: ExactText(password), note: ExactText(noteText ?? ""))
            if let first = seen[exact] {
                note(.duplicateInFile(firstLine: first))
                continue
            }
            seen[exact] = row.line
            let matches = saved[key] ?? []
            if matches.contains(where: { Self.holds($0, password: password, note: noteText) }) {
                report.alreadySaved += 1
                continue
            }

            let title = columns.title.map { fields[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            // Replace names ONE stored login. With several saved logins for this website and username none is more right than
            // another, so none is offered: the review asks for Skip or Add Separately.
            let recall = memory.map {
                Self.recall(origin: origin, username: username, password: password, note: noteText, matches: matches, memory: $0, remembered: remembered)
            }
            let existing = recall?.survivor ?? (matches.count == 1 ? matches.first : nil)
            var candidate = CredentialAccount(
                id: UUID(),
                // Replacing a merged credential's login keeps its username: the merge dropped the copy number an export adds.
                username: recall?.link == nil ? username : existing?.username ?? username,
                displayName: title?.isEmpty == false ? title : nil,
                origins: [origin],
                loginURLs: login.path.isEmpty || login.path == "/" ? [] : [login],
                password: password,
                passkeys: [],
                totp: nil,
                exchangeAccountID: nil,
                exchangeItemID: nil,
                // Replacing keeps the stored login's field descriptors: only the password value changes.
                basicAuthenticationMetadata: existing.flatMap(descriptors)
            )
            candidate.notes = noteText.map { [CredentialNote(text: $0, field: nil)] }
            do {
                try candidate.validate()
            } catch {
                note(.invalidRow)
                continue
            }
            let identity = CredentialIdentity.password(accountID: candidate.id)
            if let first = firstLine[key] {
                note(.conflictsWithEarlierRow(line: first))
            } else {
                firstLine[key] = row.line
            }
            if matches.count > 1 {
                note(.matchesSeveralSaved)
            }
            var relation = Self.relation(of: candidate, to: existing, savedMatches: matches.count)
            if let memory, let recall {
                let recalled = Self.remembering(recall, relation, of: candidate, to: existing, memory: memory)
                relation = recalled.0
                mergedInto[candidate.id] = recalled.1
                traces[candidate.id] = RowTrace(trace: recall.trace, target: existing?.id, link: recall.link)
            }
            conflicts += relation.conflicts
            classes.merge(relation.classes) { _, new in new }
            for incoming in CredentialExchangeCodec.identities(in: candidate) {
                lines[incoming] = row.line
            }
            rowsPerLogin[key, default: 0] += 1
            staged.append((identity, key))
            candidates.append(candidate)
        }
        report.ignoredColumns = ignored.sorted()
        // A row that is not a conflict with exactly one saved login but still clashes with other logins (several saved ones,
        // or another row of this file) is the user's decision.
        let needsChoice = Set(staged.filter { row in
            let savedCount = saved[row.key]?.count ?? 0
            return savedCount > 1 || (savedCount == 0 && (rowsPerLogin[row.key] ?? 0) > 1)
        }.map(\.identity))
        // Each saved login can be replaced by one row, so the file adds at most every row but one per saved login it matches.
        let replaced = Set(conflicts.map(\.existing)).count
        guard base.accounts.count + candidates.count - replaced <= CredentialVaultLimits.accounts else {
            throw CredentialCSVError.tooManyAccounts
        }
        return Staged(
            preview: CredentialImportPreview(base: base, candidates: candidates, conflicts: conflicts),
            classes: classes,
            report: report,
            needsChoice: needsChoice,
            lines: lines,
            traces: traces,
            mergedInto: mergedInto
        )
    }

    /// The items of a system import that nothing in the vault holds by the other app's ids (every part `.new`) but whose login (a website
    /// and the exact username) is one the vault remembers: an entry imported earlier from a file, say, then deleted or merged away. They
    /// are left out unless the user brings them back (`previouslyRemoved`), never re-added unasked. Returns the saved credential each item
    /// that was merged away into it stands beside, by candidate.
    static func remember(
        _ candidates: [CredentialAccount], in accounts: [CredentialAccount], memory: Memory,
        classes: inout [CredentialIdentity: CredentialImportClass]
    ) -> [UUID: UUID] {
        // Only what no item of another app named: an entry that had one is found by its ids, and another item with the same login is
        // another entry.
        let remembered = remembered(in: accounts, removed: memory.removed, withoutExporterItem: true)
        guard !remembered.isEmpty else { return [:] }
        var mergedInto: [UUID: UUID] = [:]
        for candidate in candidates where !candidate.username.isEmpty {
            let identities = CredentialExchangeCodec.identities(in: candidate)
            guard !identities.isEmpty, identities.allSatisfy({ classes[$0] == .new }),
                  let earlier = candidate.origins.lazy.compactMap({ remembered[memory.key.login(origin: $0, username: candidate.username)] }).first
            else { continue }
            let removed: CredentialImportClass
            switch earlier {
            case let .merged(survivor, _, _, entryID):
                removed = .previouslyRemoved(entryID: entryID ?? survivor.id, isTombstone: false)
                mergedInto[candidate.id] = survivor.id
            case let .removed(entryID, isTombstone):
                removed = .previouslyRemoved(entryID: entryID, isTombstone: isTombstone)
            }
            for identity in identities {
                classes[identity] = removed
            }
        }
        return mergedInto
    }

    /// What the vault remembers by login (`ImportMemoryKey.login`): an entry merged into a saved credential (its link's trace, or, for a
    /// merge made before links kept one, the merged entry's Trash entry), else a deleted entry (a Trash entry before a tombstone).
    private static func remembered(
        in accounts: [CredentialAccount], removed: RemovedIdentifiers, withoutExporterItem: Bool = false
    ) -> [Data: Remembered] {
        var found: [Data: Remembered] = [:]
        var survivors: [UUID: CredentialAccount] = [:]
        for account in accounts {
            for link in account.mergedFrom ?? [] {
                survivors[link.accountID] = account
            }
        }
        for item in removed.items.sorted(by: { $0.isTombstone && !$1.isTombstone }) where !withoutExporterItem || item.hasNoExporterItem {
            for login in item.trace?.logins ?? [] {
                if let survivor = survivors[item.accountID] {
                    found[login] = .merged(survivor: survivor, absorbed: item.accountID, trace: item.trace, entryID: item.entryID)
                } else {
                    found[login] = .removed(entryID: item.entryID, isTombstone: item.isTombstone)
                }
            }
        }
        for account in accounts {
            for link in account.mergedFrom ?? [] where !withoutExporterItem || link.hasNoExporterItem {
                for login in link.trace?.logins ?? [] {
                    found[login] = .merged(survivor: account, absorbed: link.accountID, trace: link.trace, entryID: nil)
                }
            }
        }
        return found
    }

    /// Stored logins an incoming row can be the same login as, by website and exact username.
    private static func savedLogins(_ accounts: [CredentialAccount]) -> [LoginKey: [CredentialAccount]] {
        var saved: [LoginKey: [CredentialAccount]] = [:]
        for account in accounts where CredentialExchangeCodec.hasBasicAuthentication(account) {
            for origin in Set(account.origins) {
                saved[LoginKey(origin: origin, username: ExactText(account.username)), default: []].append(account)
            }
        }
        return saved
    }

    private static func recall(
        origin: String, username: String, password: String, note: String?, matches: [CredentialAccount], memory: Memory,
        remembered: [Data: Remembered]
    ) -> Recall {
        let key = memory.key
        let trace = ImportTrace(logins: [key.login(origin: origin, username: username)], password: key.password(password), note: note.map(key.note))
        let login = trace.logins[0]
        let existing = matches.count == 1 ? matches.first : nil
        var recall = Recall(
            trace: trace, earlier: matches.isEmpty ? remembered[login] : nil,
            base: existing?.importTrace.flatMap { $0.logins.contains(login) ? $0 : nil }
        )
        if case let .merged(survivor, absorbed, mergedTrace, _)? = recall.earlier,
           !isUnchanged(password: password, note: note, since: mergedTrace, in: survivor, memory: memory) {
            // Changed since it was merged: compared with the credential it was merged into, never added beside it unasked.
            recall.survivor = survivor
            recall.link = absorbed
            recall.base = mergedTrace
        }
        return recall
    }

    /// `relation` as what the vault remembers changes it: compared part by part with the last import's trace, left out for an entry
    /// deleted or merged away unchanged, and the credential such an entry was merged into, if it was.
    private static func remembering(
        _ recall: Recall, _ relation: Relation, of candidate: CredentialAccount, to existing: CredentialAccount?, memory: Memory
    ) -> (Relation, UUID?) {
        var result = relation
        if let existing, let base = recall.base {
            result = Self.relation(of: candidate, to: existing, since: base, memory: memory)
        }
        switch recall.earlier {
        case let .merged(survivor, _, _, entryID)? where recall.link == nil:
            result.classes = result.classes.mapValues { _ in .previouslyRemoved(entryID: entryID ?? survivor.id, isTombstone: false) }
            return (result, survivor.id)
        case let .removed(entryID, isTombstone)?:
            result.classes = result.classes.mapValues { _ in .previouslyRemoved(entryID: entryID, isTombstone: isTombstone) }
            return (result, nil)
        case .merged?:
            return (result, existing?.id)
        case nil:
            return (result, nil)
        }
    }

    /// Whether a row is what an entry merged into `survivor` brought when it was merged: the same password, and a note it had or that the
    /// survivor holds.
    private static func isUnchanged(
        password: String, note: String?, since trace: ImportTrace?, in survivor: CredentialAccount, memory: Memory?
    ) -> Bool {
        guard let key = memory?.key, let trace, trace.password == key.password(password) else { return false }
        return note.map { trace.note == key.note($0) || holdsNote(survivor, $0) } ?? true
    }

    /// How a row relates to the saved login `existing` when the vault remembers what the last import brought for it (`base`): each part
    /// is unchanged, changed in the other app only (an update), changed here only (kept) or changed in both (the user's decision), as
    /// `CredentialSyncMerge.classify` tells from the three digests. A note the login does not hold is always a conflict with its notes,
    /// so it is decided with them and never follows a login that is kept.
    private static func relation(
        of candidate: CredentialAccount, to existing: CredentialAccount, since base: ImportTrace, memory: Memory
    ) -> Relation {
        let key = memory.key
        let login = CredentialIdentity.password(accountID: candidate.id)
        let absent = Data()
        var conflicts = [CredentialImportConflict(incoming: login, existing: .password(accountID: existing.id))]
        var classes = [
            login: CredentialSyncMerge.classify(
                incoming: candidate.password.map(key.password) ?? absent, local: existing.password.map(key.password) ?? absent,
                base: base.password ?? absent
            ),
        ]
        if let text = candidate.notes?.first?.text {
            let note = CredentialIdentity.note(accountID: candidate.id)
            if holdsNote(existing, text) {
                classes[note] = .unchanged
            } else {
                // Several notes saved here are not one the other app sent: a change made here.
                let local = existing.notes.map { $0.count == 1 ? key.note($0[0].text) : Data([0]) } ?? absent
                classes[note] = CredentialSyncMerge.classify(incoming: key.note(text), local: local, base: base.note ?? absent)
                conflicts.append(CredentialImportConflict(incoming: note, existing: .note(accountID: existing.id)))
            }
        }
        return (conflicts, classes)
    }

    /// How a staged row relates to the saved login it can replace (`existing`, only when exactly one matches). A note the saved login
    /// already holds needs no decision, and a saved login without notes takes the note with the login.
    private static func relation(
        of candidate: CredentialAccount, to existing: CredentialAccount?, savedMatches: Int
    ) -> (conflicts: [CredentialImportConflict], classes: [CredentialIdentity: CredentialImportClass]) {
        let login = CredentialIdentity.password(accountID: candidate.id)
        // A row carries at most one note, its Notes cell.
        let text = candidate.notes?.first?.text
        let note = text == nil ? nil : CredentialIdentity.note(accountID: candidate.id)
        guard let existing else {
            let unmatched: CredentialImportClass = savedMatches > 1 ? .ambiguous : .new
            return ([], Dictionary(uniqueKeysWithValues: [login, note].compactMap { $0 }.map { ($0, unmatched) }))
        }
        var conflicts = [CredentialImportConflict(incoming: login, existing: .password(accountID: existing.id))]
        var classes: [CredentialIdentity: CredentialImportClass] = [login: .noCommonBase]
        if let note, let text {
            let differs = existing.notes != nil && !holdsNote(existing, text)
            if differs {
                conflicts.append(CredentialImportConflict(incoming: note, existing: .note(accountID: existing.id)))
            }
            classes[note] = differs ? .noCommonBase : existing.notes == nil ? .new : .unchanged
        }
        return (conflicts, classes)
    }

    /// Whether a saved login is this row: the same password, and the row's note among its notes when the row has one.
    private static func holds(_ saved: CredentialAccount, password: String, note: String?) -> Bool {
        guard saved.password?.utf8.elementsEqual(password.utf8) == true else { return false }
        return note.map { holdsNote(saved, $0) } ?? true
    }

    private static func holdsNote(_ saved: CredentialAccount, _ text: String) -> Bool {
        saved.notes?.contains { $0.text.utf8.elementsEqual(text.utf8) } == true
    }

    /// Only a plain https address is a website: no scheme is assumed, and the existing origin rules decide the rest.
    private static func website(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return try? CredentialAccount.sanitizedLoginURL(url)
    }

    /// The stored login's field descriptors, with a password descriptor when it had none (the vault requires one whenever
    /// there is a password).
    private static func descriptors(of account: CredentialAccount) -> CredentialBasicAuthenticationMetadata? {
        guard var metadata = account.basicAuthenticationMetadata else { return nil }
        if metadata.password == nil {
            metadata.password = CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)
        }
        return metadata
    }
}

/// Selected saved logins as an Apple Passwords CSV. Only a login with a password AND a website can be written; everything
/// else a vault holds (passkeys, verification codes) is never in the file, and the export sheet says so before it starts. Notes are
/// written only for a login whose selection includes them, as one cell: several notes are joined by a blank line.
nonisolated enum CredentialCSVExport {
    static let header = ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"]

    struct Exported: Sendable {
        let data: Data
        /// CSV rows: one per website of each exported login.
        let rows: Int
    }

    static func isExportable(_ summary: CredentialSummary) -> Bool {
        summary.hasPassword && !summary.origins.isEmpty
    }

    static func encode(_ snapshot: StoreSnapshot, selection: [CredentialExportSelection]) throws -> Exported {
        let chosen = Set(selection.filter(\.password).map(\.accountID))
        let withNotes = Set(selection.filter { $0.password && $0.notes }.map(\.accountID))
        var lines = [header]
        for account in snapshot.accounts where chosen.contains(account.id) {
            guard let password = account.password else { continue }
            let notes = withNotes.contains(account.id) ? (account.notes ?? []).map(\.text).joined(separator: "\n\n") : ""
            for origin in account.origins {
                let address = account.loginURLs.first { CredentialAccount.origin(for: $0) == origin }?.absoluteString ?? origin
                let title = account.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: origin)?.host ?? origin
                lines.append([title, address, account.username, password, notes, ""])
            }
        }
        guard lines.count > 1 else { throw CredentialExchangeCoordinatorError.emptySelection }
        return Exported(data: CredentialCSV.encode(lines), rows: lines.count - 1)
    }
}
