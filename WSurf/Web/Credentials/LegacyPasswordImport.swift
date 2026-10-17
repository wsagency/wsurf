// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// What the Credential Manager page shows and holds while the passwords saved before Credential Manager move into a vault: the
/// stored state, the removal confirmation, and the one authentication session that reading the old list needs.
///
/// The list itself is never kept here. Each step reads it with `session`, uses it and drops it, so a lock, a page change or an error
/// leaves no password behind.
@MainActor
@Observable
final class LegacyPasswordImport {
    /// Test seam: the rules over the old list, which the page drives.
    @ObservationIgnored var migration: LegacyPasswordMigration
    /// `nil` until `refresh` has read it. A private profile, and a profile without a list, are `done`.
    private(set) var state: LegacyPasswordMigration.State?
    /// The counts the removal confirmation states, while it is shown. `erase` reads them again before it deletes anything.
    private(set) var removal: LegacyPasswordMigration.Tally?
    /// The list was removed on this page, which says so until the page is left.
    private(set) var didRemove = false
    @ObservationIgnored private var session: AutofillAuthenticationSession?

    init(profile: Profile) {
        migration = LegacyPasswordMigration(profile: profile)
    }

    /// Reads where the move stands. Asks the Keychain whether the list exists, which never prompts and reads no secret.
    func refresh() async {
        state = await migration.state()
    }

    func markImported() {
        migration.markImported()
        if state != .done {
            state = .imported
        }
    }

    func offerRemoval(_ tally: LegacyPasswordMigration.Tally) {
        removal = tally
    }

    func dismissRemoval() {
        removal = nil
    }

    func finishRemoval() {
        removal = nil
        state = .done
        didRemove = true
    }

    /// Runs `work` with the page's authentication session. The first call makes the system ask the user to authenticate; later
    /// calls reuse the answer until the page drops the session. A failure to read the list drops it, so the next try asks again.
    func withSession<Output>(_ work: (AutofillAuthenticationSession) async throws -> Output) async throws -> Output {
        let session: AutofillAuthenticationSession
        if let existing = self.session {
            session = existing
        } else {
            session = await migration.makeSession()
            self.session = session
        }
        do {
            return try await work(session)
        } catch let failure as AutofillVaultError {
            endSession()
            throw failure
        }
    }

    /// The page left, or the vault locked or opened again: the next read asks the user to authenticate again.
    func endSession() {
        session?.invalidate()
        session = nil
        removal = nil
        didRemove = false
    }
}
