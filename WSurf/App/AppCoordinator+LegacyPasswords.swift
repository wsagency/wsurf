// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

extension AppCoordinator {
    /// Tells the user once, in each profile, that the passwords saved before Credential Manager are not filled until they are
    /// imported. Asking costs no password: the Keychain is only asked whether the old list exists, which reads no secret and never
    /// prompts. A private window, a profile without an old list, a finished move and a profile already asked say nothing, and a
    /// Keychain error is not a list.
    func offerLegacyPasswordImport() async {
        guard !AppDatabase.isRunningTests, !isClosed else { return }
        let profile = context.profile
        guard !profile.isPrivate else { return }
        let migration = LegacyPasswordMigration(profile: profile)
        guard await migration.hasListToMove() else { return }
        // The window and the profile may have changed while the Keychain answered. Asking is recorded first, so it happens once.
        guard !isClosed, context.profile.id == profile.id, let window = nativeWindow, window.isVisible, migration.claimPrompt() else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Move Your Saved Passwords")
        alert.informativeText = String(localized: """
            WSurf now keeps passwords only in Credential Manager, an encrypted vault you unlock with a passkey. Passwords saved in \
            the profile “\(profile.name)” aren’t filled until you import them. Nothing is deleted without your confirmation.
            """)
        alert.addButton(withTitle: String(localized: "Import…"))
        alert.addButton(withTitle: String(localized: "Later"))
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        if response == .alertFirstButtonReturn, !isClosed {
            openSettings(.autofill)
        }
    }
}
