// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Password CSV transfer through the real parser, the real coordinator and the real vault. The CSV layouts here are
// synthetic: a 6-column `Title,URL,Username,Password,Notes,OTPAuth` file and an older 4-column `Title,Url,Username,Password`
// one, which is what the public Safari/Passwords CSV importers of third-party tools read. That is compatibility evidence, not
// a statement of Apple's format: the importer is header-driven and these tests pin only the behaviour WSurf owns.
@MainActor
struct CredentialCSVTests {
    let base = CredentialExchangeCoordinatorTests()
    static let header = ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"]

    func row(_ username: String, _ password: String, url: String = "https://example.test/login", title: String = "Example") -> [String] {
        [title, url, username, password, "", ""]
    }

    func data(_ rows: [[String]]) -> Data {
        CredentialCSV.encode([Self.header] + rows)
    }

    func stage(_ f: CredentialExchangeCoordinatorTests.Fixture, _ rows: [[String]]) async throws {
        try await f.coordinator.beginCSVImport(data(rows), into: f.manager, owner: f.owner) { _ in }
    }

    /// Decides the review row that came from CSV line `line`.
    func decide(_ f: CredentialExchangeCoordinatorTests.Fixture, _ choice: CredentialImportChoice, line: Int) throws {
        let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
        let record = try #require(review.candidates.flatMap(\.records).first { $0.csvLine == line })
        try f.coordinator.choose(choice, for: record.incoming, owner: f.owner)
    }

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "csv-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Parser

    @Test func parserAcceptsBOMLineEndsAndQuotedFields() throws {
        let text = "\u{FEFF}a,b\r\n\"x,1\",\"line\nbreak \"\"q\"\"\"\n\nlast,\r"
        let rows = try CredentialCSV.parse(Data(text.utf8))
        #expect(rows.map(\.fields) == [["a", "b"], ["x,1", "line\nbreak \"q\""], ["last", ""]])
        #expect(rows.map(\.line) == [1, 2, 5])
    }

    @Test func parserRejectsUnclosedAndStrayQuotesWithALineNumberOnly() {
        #expect(throws: CredentialCSVError.unreadable(line: 2)) { try CredentialCSV.parse(Data("a,b\n\"never closed,x\n".utf8)) }
        #expect(throws: CredentialCSVError.unreadable(line: 1)) { try CredentialCSV.parse(Data("a,b\"c,d\n".utf8)) }
        #expect(throws: CredentialCSVError.notUTF8) { try CredentialCSV.parse(Data([0xFF, 0xFE, 0x41])) }
    }

    @Test func encodeThenParseRoundTripsAwkwardValues() throws {
        let rows = [Self.header, ["a,b", "https://example.test", " lead", "tail ", "q\"uote", "line\r\nbreak"]]
        #expect(try CredentialCSV.parse(CredentialCSV.encode(rows)).map(\.fields) == rows)
    }

    // MARK: - Staging

    @Test func headerDrivesColumnsForTheOldFourColumnLayoutAndTheSixColumnOne() throws {
        let empty = StoreSnapshot(vaultID: UUID(), revision: 0, accounts: [], blockedPasswordOrigins: [], stamps: [:])
        let old = Data("Title,Url,Username,Password\r\nExample,https://example.test/,ada,pw\r\n".utf8)
        let staged = try CredentialCSVImport.stage(old, against: empty)
        #expect(staged.preview.candidates.map(\.username) == ["ada"] && staged.preview.candidates.first?.password == "pw")
        #expect(staged.report.rowsRead == 1 && staged.report.issues.isEmpty && staged.report.ignoredColumns.isEmpty)

        // Columns in another order, with notes and a verification code that are reported and never imported.
        let shuffled = Data("Password,OTPAuth,Username,Notes,URL\r\npw,otpauth://totp/x?secret=ABC,ada,secret note,https://example.test\r\n".utf8)
        let report = try CredentialCSVImport.stage(shuffled, against: empty).report
        #expect(report.issues.map(\.reason) == [.notesNotImported, .oneTimeCodeNotImported] && report.omittedRows == 0)
        let candidate = try #require(try CredentialCSVImport.stage(shuffled, against: empty).preview.candidates.first)
        #expect(candidate.totp == nil && candidate.password == "pw")
    }

    @Test func missingColumnsNeverEchoesTheHeader() throws {
        let text = Data("Title,SECRET-HEADER-TEXT,Username\r\nx,y,z\r\n".utf8)
        let empty = StoreSnapshot(vaultID: UUID(), revision: 0, accounts: [], blockedPasswordOrigins: [], stamps: [:])
        #expect(throws: CredentialCSVError.missingColumns) { try CredentialCSVImport.stage(text, against: empty) }

        // An unrecognised column is reported by position only.
        let extra = Data("URL,Username,Password,SECRET-HEADER-TEXT\r\nhttps://example.test,ada,pw,value\r\n".utf8)
        let report = try CredentialCSVImport.stage(extra, against: empty).report
        #expect(report.ignoredColumns == [4])
        #expect(!String(describing: report).contains("SECRET-HEADER-TEXT") && !String(describing: report).contains("value"))
    }

    @Test func onlyAnHttpsWebsiteIsAcceptedAndNoSchemeIsInvented() throws {
        let empty = StoreSnapshot(vaultID: UUID(), revision: 0, accounts: [], blockedPasswordOrigins: [], stamps: [:])
        let text = data([
            row("a", "pw", url: "example.test"), row("b", "pw", url: "http://example.test"),
            row("c", "pw", url: "https://example.test"), row("d", "", url: "https://example.test"),
        ])
        let staged = try CredentialCSVImport.stage(text, against: empty)
        #expect(staged.preview.candidates.map(\.username) == ["c"])
        #expect(staged.report.issues.map(\.reason) == [.unsupportedWebsite, .unsupportedWebsite, .missingPassword])
        #expect(staged.report.issues.map(\.line) == [2, 3, 5])
    }

    // MARK: - Through the coordinator

    @Test func importAddsNewLoginsWithNothingInventedAndTheReportIsAttached() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(2))
            try await stage(f, [row("ada", "pw1"), row("grace", "pw2", url: "https://other.test")])
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.csvReport?.rowsRead == 2 && review.csvReport?.alreadySaved == 0)
            #expect(base.counts(review.outcome) == [2, 0])

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let added = try await f.stored().accounts.filter { $0.username == "ada" || $0.username == "grace" }
            #expect(added.count == 2)
            for account in added {
                #expect(account.exchangeAccountID == nil && account.exchangeItemID == nil && account.passkeys.isEmpty && account.totp == nil)
            }
            #expect(added.first { $0.username == "ada" }?.origins == ["https://example.test"])
        }
    }

    @Test func usernameMatchIsExactSoAliceAndAliceAreDistinctAccounts() async throws {
        try await base.withFixture { f in
            try await f.seed([base.account(username: "alice", password: "same")])
            try await stage(f, [row("Alice", "same")])
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.csvReport?.alreadySaved == 0 && review.conflicts.isEmpty)
            #expect(base.counts(review.outcome) == [1, 0])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.map(\.username).sorted() == ["Alice", "alice"])
        }
    }

    @Test func aRowIdenticalToASavedLoginIsAlreadySavedAndWritesNothing() async throws {
        try await base.withFixture { f in
            try await f.seed([base.account(username: "alice", password: "same")])
            let before = try f.diskBytes()
            try await stage(f, [row("alice", "same")])
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.csvReport?.alreadySaved == 1 && review.candidates.isEmpty)
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .nothingImported)
            #expect(try f.diskBytes() == before)
        }
    }

    @Test func everyRowThatDiffersFromTheSavedLoginOrFromAnotherRowIsDecidedAndSkipReallySkips() async throws {
        try await base.withFixture { f in
            try await f.seed([base.account(username: "ada", password: "stored")])
            let before = try f.diskBytes()
            // Lines: 2 ada p1, 3 ada p1 again, 4 ada p2, 5 grace g, 6 grace g2.
            try await stage(f, [row("ada", "p1"), row("ada", "p1"), row("ada", "p2"), row("grace", "g"), row("grace", "g2")])
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.csvReport?.issues.contains { $0.line == 3 && $0.reason == .duplicateInFile(firstLine: 2) } == true)
            let records = review.candidates.flatMap(\.records)
            // Four distinct logins; none is imported by default. Two differ from the saved login, two from each other.
            #expect(records.count == 4 && records.allSatisfy(\.needsChoice) && records.allSatisfy { $0.choice == nil })
            #expect(review.conflicts.count == 2)
            #expect(!review.isResolved && review.outcome == nil)

            await #expect(throws: CredentialExchangeCoordinatorError.unresolvedConflicts) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            try decide(f, .skip, line: 2)
            try decide(f, .replace, line: 4)
            try decide(f, .skip, line: 5)
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.isResolved == false)
            await #expect(throws: CredentialExchangeCoordinatorError.unresolvedConflicts) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(try f.diskBytes() == before)

            // One saved login takes one replacement, and a row with no saved login has nothing to replace.
            #expect(throws: CredentialExchangeCoordinatorError.replaceTaken) { try decide(f, .replace, line: 2) }
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) { try decide(f, .replace, line: 6) }
            try decide(f, .addSeparately, line: 6)

            let resolved = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(resolved.isResolved && base.counts(resolved.outcome) == [1, 1])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.compactMap(\.password).sorted() == ["g2", "p2"])
        }
    }

    @Test func replacingAStoredLoginChangesOnlyItsPasswordAndKeepsEverythingElse() async throws {
        try await base.withFixture { f in
            var target = base.account(username: "ada", password: "old", passkeys: [try base.passkey(3)], totp: base.generator())
            target.exchangeAccountID = Data([1, 2])
            target.exchangeItemID = Data([3, 4])
            target.exchangeMetadata = Data([5])
            target.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
                username: CredentialEditableFieldMetadata(id: Data([9]), label: "Login", fieldType: .string),
                password: CredentialEditableFieldMetadata(id: Data([8]), label: "Secret", fieldType: .concealedString)
            )
            target.passwordBase = ExchangeBase(contentHash: Data(repeating: 7, count: 32), itemID: Data([3, 4]))
            try await f.seed([target] + base.neighbours(3))
            let before = try #require(try await f.stored().accounts.first { $0.id == target.id })

            try await stage(f, [row("ada", "new")])
            let conflict = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.conflicts.first)
            try f.coordinator.choose(.replace, for: conflict.incoming, owner: f.owner)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            let after = try #require(try await f.stored().accounts.first { $0.id == target.id })
            #expect(after.password == "new" && after.username == "ada")
            #expect(after.passkeys == before.passkeys && after.totp == before.totp)
            #expect(after.exchangeAccountID == before.exchangeAccountID && after.exchangeItemID == before.exchangeItemID)
            #expect(after.exchangeMetadata == before.exchangeMetadata)
            #expect(after.basicAuthenticationMetadata == before.basicAuthenticationMetadata)
            #expect(after.passwordBase == before.passwordBase && after.createdAt == before.createdAt)
            #expect(after.origins == before.origins && after.displayName == before.displayName)
            #expect(try await f.stored().accounts.count == 4)
        }
    }

    @Test func anUnreadableFileSaysSoWithoutEchoingItAndLeavesNothingClaimed() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(2))
            let before = try f.diskBytes()
            let junk = Data("Title,SECRET-HEADER-TEXT\r\nx,y\r\n".utf8)
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                try await f.coordinator.beginCSVImport(junk, into: f.manager, owner: f.owner) { _ in }
            }
            #expect(failure?.message.kind == .csvUnreadable)
            #expect(failure?.message.text.contains("SECRET-HEADER-TEXT") == false)
            #expect(try f.diskBytes() == before)
            // The claim was released: the next file stages.
            try await stage(f, [row("ada", "pw")])
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    @Test func aSecondImportWhileOneIsOpenIsRefused() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await stage(f, [row("ada", "pw")])
            await #expect(throws: CredentialExchangeCoordinatorError.busy) { try await stage(f, [row("grace", "pw")]) }
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    @Test func rowsOfAFileThatDifferOnlyInPasswordNeedAChoiceEvenWithNothingSaved() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await stage(f, [row("ada", "p1"), row("ada", "p2")])
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.conflicts.isEmpty && !review.isResolved)
            try decide(f, .skip, line: 2)
            try decide(f, .skip, line: 3)
            #expect(base.counts(try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)).outcome) == [0, 0])
            try decide(f, .addSeparately, line: 3)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.compactMap(\.password) == ["p2"])
        }
    }

    @Test func severalSavedMatchesNeedASkipOrAddSeparatelyAndOfferNoReplace() async throws {
        try await base.withFixture { f in
            try await f.seed([base.account(username: "ada", password: "a"), base.account(username: "ada", password: "b")])
            let before = try f.diskBytes()
            try await stage(f, [row("ada", "c")])
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.conflicts.isEmpty && !review.isResolved)
            #expect(review.candidates.flatMap(\.records).allSatisfy { $0.needsChoice && !$0.isConflict })
            #expect(review.csvReport?.issues.map(\.reason) == [.matchesSeveralSaved])
            await #expect(throws: CredentialExchangeCoordinatorError.unresolvedConflicts) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) { try decide(f, .replace, line: 2) }

            try decide(f, .skip, line: 2)
            #expect(base.counts(try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)).outcome) == [0, 0])
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .nothingImported)
            #expect(try f.diskBytes() == before)

            try decide(f, .addSeparately, line: 2)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.compactMap(\.password).sorted() == ["a", "b", "c"])
        }
    }

    @Test func choicesDoNotSurviveACancelOrAChangedVault() async throws {
        try await base.withFixture { f in
            try await f.seed([base.account(username: "ada", password: "stored")])
            try await stage(f, [row("ada", "p1")])
            try decide(f, .replace, line: 2)
            #expect(f.coordinator.cancelImport(for: f.manager, owner: f.owner) == .reviewCancelled)
            #expect(try await f.stored().accounts.compactMap(\.password) == ["stored"])

            // A new import starts undecided, and the vault changing under a finished review stops the commit.
            try await stage(f, [row("ada", "p1")])
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.flatMap(\.records).allSatisfy { $0.choice == nil } == true)
            try decide(f, .replace, line: 2)
            let snapshot = try await f.stored()
            var changed = snapshot.accounts
            changed[0].password = "changed-elsewhere"
            _ = try await f.manager.commit(changed, expectedRevision: snapshot.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))
            await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(try await f.stored().accounts.compactMap(\.password) == ["changed-elsewhere"])
        }
    }

    @Test func rowsAreComparedByExactBytesNotByDelimitersOrUnicodeEquivalence() throws {
        let empty = StoreSnapshot(vaultID: UUID(), revision: 0, accounts: [], blockedPasswordOrigins: [], stamps: [:])
        // The same characters split differently between username and password are two logins, not a duplicate.
        let pair = try CredentialCSVImport.stage(data([row("a\u{0}b", "c"), row("a", "b\u{0}c")]), against: empty)
        #expect(pair.preview.candidates.count == 2 && pair.report.omittedRows == 0 && pair.needsChoice.isEmpty)

        // "é" as one scalar and as "e" + a combining accent are different usernames and different passwords.
        let saved = StoreSnapshot(
            vaultID: UUID(), revision: 0, accounts: [base.account(username: "\u{E9}", password: "p\u{E9}")],
            blockedPasswordOrigins: [], stamps: [:]
        )
        let username = try CredentialCSVImport.stage(data([row("e\u{301}", "p\u{E9}")]), against: saved)
        #expect(username.report.alreadySaved == 0 && username.preview.conflicts.isEmpty && username.preview.candidates.count == 1)
        let password = try CredentialCSVImport.stage(data([row("\u{E9}", "pe\u{301}")]), against: saved)
        #expect(password.report.alreadySaved == 0 && password.preview.conflicts.count == 1)
        let same = try CredentialCSVImport.stage(data([row("\u{E9}", "p\u{E9}")]), against: saved)
        #expect(same.report.alreadySaved == 1 && same.preview.candidates.isEmpty)
    }

    @Test func aHeaderNamingARecognisedColumnTwiceIsRefused() {
        let empty = StoreSnapshot(vaultID: UUID(), revision: 0, accounts: [], blockedPasswordOrigins: [], stamps: [:])
        for header in ["URL,Username,Password,password", "URL,Username,Username,Password", "Title,Name,URL,Username,Password"] {
            let text = Data("\(header)\r\n".utf8)
            #expect(throws: CredentialCSVError.ambiguousColumns) { try CredentialCSVImport.stage(text, against: empty) }
        }
    }

    @Test func aFileWithNothingToImportStillOpensTheReviewWithItsReport() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await stage(f, [row("ada", "pw", url: "example.test")])
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.candidates.isEmpty && review.csvReport?.omittedRows == 1)
            #expect(base.counts(review.outcome) == [0, 0])
        }
    }

    // MARK: - Export

    @Test func exportWritesOnlyLoginsWithAPasswordAndAWebsite() async throws {
        try await base.withFixture { f in
            var noSite = base.account(username: "nosite", password: "x")
            noSite.origins = []
            let passkeyOnly = base.account(username: "pk", password: nil, passkeys: [try base.passkey(4)])
            let login = base.account(username: "ada", password: "pw,\"1\"", totp: base.generator())
            try await f.seed([login, noSite, passkeyOnly])
            let snapshot = try await f.stored()
            let selection = snapshot.accounts.map {
                CredentialExportSelection(accountID: $0.id, password: $0.password != nil, passkeyIDs: Set($0.passkeys.map(\.id)), totp: $0.totp != nil)
            }
            let exported = try CredentialCSVExport.encode(snapshot, selection: selection)
            #expect(exported.rows == 1)
            let rows = try CredentialCSV.parse(exported.data).map(\.fields)
            #expect(rows == [Self.header, ["example.test", "https://example.test", "ada", "pw,\"1\"", "", ""]])
            #expect(!String(decoding: exported.data, as: UTF8.self).contains("otpauth"))
        }
    }

    @Test func exportThenImportReproducesTheLogins() async throws {
        try await base.withFixture { f in
            try await f.seed([base.account(username: "ada", password: "p1"), base.account(username: "grace", password: "p2")])
            let snapshot = try await f.stored()
            let selection = snapshot.accounts.map { CredentialExportSelection(accountID: $0.id, password: true, passkeyIDs: [], totp: false) }
            let exported = try CredentialCSVExport.encode(snapshot, selection: selection)
            let empty = StoreSnapshot(vaultID: UUID(), revision: 0, accounts: [], blockedPasswordOrigins: [], stamps: [:])
            let staged = try CredentialCSVImport.stage(exported.data, against: empty)
            #expect(Set(staged.preview.candidates.map { "\($0.username):\($0.password ?? "")" }) == ["ada:p1", "grace:p2"])
        }
    }

    @Test func staleSelectionAfterThePanelWritesNothing() async throws {
        try await base.withFixture { f in
            try await f.seed([base.account(username: "ada", password: "pw")] + base.neighbours(1))
            let snapshot = try await f.stored()
            let epoch = try #require(f.manager.authorizationEpoch)
            let selection = snapshot.accounts.map { CredentialExportSelection(accountID: $0.id, password: true, passkeyIDs: [], totp: false) }

            // The vault changes after the selection was read and before the file is written.
            var changed = snapshot.accounts
            changed[0].password = "changed-elsewhere"
            _ = try await f.manager.commit(changed, expectedRevision: snapshot.revision, authorizedEpoch: epoch)

            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appending(path: "out.csv")
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.exportCSV(
                    selection: selection, expectedStamps: snapshot.stamps, epoch: epoch, from: f.manager, to: destination
                )
            }
            #expect(failure?.message.kind == .exportSelectionChanged)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test func exportWritesAPrivateFileAndReportsTheRows() async throws {
        try await base.withFixture { f in
            try await f.seed([base.account(username: "ada", password: "pw")])
            let snapshot = try await f.stored()
            let epoch = try #require(f.manager.authorizationEpoch)
            let selection = snapshot.accounts.map { CredentialExportSelection(accountID: $0.id, password: true, passkeyIDs: [], totp: false) }
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appending(path: "out.csv")
            try Data("old".utf8).write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)

            let rows = try await f.coordinator.exportCSV(
                selection: selection, expectedStamps: snapshot.stamps, epoch: epoch, from: f.manager, to: destination
            )
            #expect(rows == 1)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try CredentialCSV.parse(Data(contentsOf: destination)).count == 2)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["out.csv"])
        }
    }

    @Test func aFailedSaveLeavesTheDestinationAndTheFolderAsTheyWere() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A non-empty folder cannot be replaced by a file: the rename fails after the private temporary was written.
        let destination = directory.appending(path: "taken")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appending(path: "inner.txt"))

        #expect(throws: CredentialCSVError.notWritten) { try CredentialCSV.save(Data("new".utf8), to: destination) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["taken"])
        #expect(try Data(contentsOf: destination.appending(path: "inner.txt")) == Data("keep".utf8))

        // An unwritable location fails the same way and leaves nothing behind.
        let missing = directory.appending(path: "no-such-folder").appending(path: "out.csv")
        #expect(throws: CredentialCSVError.notWritten) { try CredentialCSV.save(Data("new".utf8), to: missing) }
    }

    @Test func readRefusesAnOversizedFileBeforeLoadingIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "big.csv")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(CredentialVaultLimits.payloadBytes) + 1)
        try handle.close()
        #expect(throws: CredentialCSVError.tooLarge) { try CredentialCSV.read(file) }
        #expect(throws: CredentialCSVError.cannotRead) { try CredentialCSV.read(directory.appending(path: "absent.csv")) }
    }

    @Test func saveNeverRemovesAFileItDidNotCreate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "out.csv")
        try Data("old".utf8).write(to: destination)
        let foreign = directory.appending(path: ".taken.tmp")
        try Data("not ours".utf8).write(to: foreign)

        #expect(throws: CredentialCSVError.notWritten) {
            try CredentialCSV.save(Data("new".utf8), to: destination, temporaryName: ".taken.tmp")
        }
        #expect(try Data(contentsOf: foreign) == Data("not ours".utf8))
        #expect(try Data(contentsOf: destination) == Data("old".utf8))

        // A link at the temporary name is neither followed nor removed.
        let victim = directory.appending(path: "victim.txt")
        try Data("victim".utf8).write(to: victim)
        let link = directory.appending(path: ".link.tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        #expect(throws: CredentialCSVError.notWritten) {
            try CredentialCSV.save(Data("new".utf8), to: destination, temporaryName: ".link.tmp")
        }
        #expect(try Data(contentsOf: victim) == Data("victim".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == victim.path)
    }

    @Test func readTakesOnlyARegularFileUpToTheLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A pipe could block or never end.
        let pipe = directory.appending(path: "pipe.csv")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: CredentialCSVError.cannotRead) { try CredentialCSV.read(pipe) }

        let empty = directory.appending(path: "empty.csv")
        #expect(FileManager.default.createFile(atPath: empty.path, contents: nil))
        #expect(try CredentialCSV.read(empty).isEmpty)

        // Exactly the limit is accepted; one byte more is not.
        let exact = directory.appending(path: "exact.csv")
        #expect(FileManager.default.createFile(atPath: exact.path, contents: nil))
        let handle = try FileHandle(forWritingTo: exact)
        try handle.truncate(atOffset: UInt64(CredentialVaultLimits.payloadBytes))
        try handle.close()
        #expect(try CredentialCSV.read(exact).count == CredentialVaultLimits.payloadBytes)
        let over = try FileHandle(forWritingTo: exact)
        try over.truncate(atOffset: UInt64(CredentialVaultLimits.payloadBytes) + 1)
        try over.close()
        #expect(throws: CredentialCSVError.tooLarge) { try CredentialCSV.read(exact) }
    }
}
