// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a CSV file holds beyond what will be imported, shown in the review BEFORE the user confirms. Line numbers and fixed
/// reasons only: no field, header text or password is ever kept here. These are counts of the file as read (staged); what was
/// actually saved is the committed outcome the import reports afterwards.
nonisolated struct CredentialCSVReport: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// The row is not imported.
        case unsupportedWebsite, missingPassword, passwordTooLong, wrongFieldCount, invalidRow
        /// An earlier row has the same website, username and password.
        case duplicateInFile(firstLine: Int)
        /// The row is staged, but this column of it is not imported: passwords are all a CSV import carries.
        case notesNotImported, oneTimeCodeNotImported
        /// Several saved logins have this website and username, so no Replace target is offered: Skip or Add Separately.
        case matchesSeveralSaved
        /// An earlier row has the same website and username with another password. Every such row needs a choice in the review.
        case conflictsWithEarlierRow(line: Int)

        var omitsRow: Bool {
            switch self {
            case .unsupportedWebsite, .missingPassword, .passwordTooLong, .wrongFieldCount, .invalidRow, .duplicateInFile:
                true
            case .notesNotImported, .oneTimeCodeNotImported, .conflictsWithEarlierRow, .matchesSeveralSaved:
                false
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
            case .notesNotImported:
                String(localized: "notes in this row aren’t imported.")
            case .oneTimeCodeNotImported:
                String(localized: "this row has a verification code, which isn’t imported. Set it up again with the website.")
            case let .conflictsWithEarlierRow(line):
                String(localized: "same website and username as line \(line) with another password. Choose what to do with each of them.")
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

/// An Apple Passwords CSV as an import: header-driven (URL, Username and Password columns, any order), password logins only.
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
    }

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

    static func stage(_ data: Data, against base: StoreSnapshot) throws -> Staged {
        let rows = try CredentialCSV.parse(data)
        guard let header = rows.first else { throw CredentialCSVError.missingColumns }
        let names = header.fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let columns = try Columns(names: names)

        // Stored logins an incoming row can be the same login as, by website and exact username.
        var saved: [LoginKey: [CredentialAccount]] = [:]
        for account in base.accounts where CredentialExchangeCodec.hasBasicAuthentication(account) {
            for origin in Set(account.origins) {
                saved[LoginKey(origin: origin, username: ExactText(account.username)), default: []].append(account)
            }
        }
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
            if let notes = columns.notes, !fields[notes].isEmpty {
                note(.notesNotImported)
            }
            if let code = columns.code, !fields[code].isEmpty {
                note(.oneTimeCodeNotImported)
            }

            let key = LoginKey(origin: origin, username: ExactText(username))
            let exact = LoginAndPassword(login: key, password: ExactText(password))
            if let first = seen[exact] {
                note(.duplicateInFile(firstLine: first))
                continue
            }
            seen[exact] = row.line
            let matches = saved[key] ?? []
            if matches.contains(where: { $0.password?.utf8.elementsEqual(password.utf8) == true }) {
                report.alreadySaved += 1
                continue
            }

            let title = columns.title.map { fields[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            // Replace names ONE stored login. With several saved logins for this website and username none is more right than
            // another, so none is offered: the review asks for Skip or Add Separately.
            let existing = matches.count == 1 ? matches.first : nil
            let candidate = CredentialAccount(
                id: UUID(),
                username: username,
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
            if let existing {
                conflicts.append(CredentialImportConflict(incoming: identity, existing: .password(accountID: existing.id)))
                classes[identity] = .noCommonBase
            } else {
                classes[identity] = matches.count > 1 ? .ambiguous : .new
            }
            lines[identity] = row.line
            rowsPerLogin[key, default: 0] += 1
            staged.append((identity, key))
            candidates.append(candidate)
        }
        report.ignoredColumns = ignored.sorted()
        // A row that is not a conflict with exactly one saved login but still clashes with other logins (several saved ones,
        // or another row of this file) is the user's decision.
        var needsChoice = Set<CredentialIdentity>()
        for row in staged {
            let savedCount = saved[row.key]?.count ?? 0
            let fileCount = rowsPerLogin[row.key] ?? 0
            if savedCount > 1 || (savedCount == 0 && fileCount > 1) {
                needsChoice.insert(row.identity)
            }
        }
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
            lines: lines
        )
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
/// else a vault holds (passkeys, verification codes, notes) is never in the file, and the export sheet says so before it starts.
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
        var lines = [header]
        for account in snapshot.accounts where chosen.contains(account.id) {
            guard let password = account.password else { continue }
            for origin in account.origins {
                let address = account.loginURLs.first { CredentialAccount.origin(for: $0) == origin }?.absoluteString ?? origin
                let title = account.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: origin)?.host ?? origin
                lines.append([title, address, account.username, password, "", ""])
            }
        }
        guard lines.count > 1 else { throw CredentialExchangeCoordinatorError.emptySelection }
        return Exported(data: CredentialCSV.encode(lines), rows: lines.count - 1)
    }
}
