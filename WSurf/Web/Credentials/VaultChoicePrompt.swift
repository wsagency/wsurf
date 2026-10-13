// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices

/// The native question "which vault?" for an ambiguous or locked route. It shows names only for unlocked vaults; a locked vault
/// is its ordinal. `nil` is a cancel: nothing is written and nothing is unlocked.
@MainActor
enum VaultChoicePrompt {
    /// Tests answer a profile's question without a window; the real sheet is covered by the native tests. Keyed by profile so parallel
    /// tests never see each other's answer, and not task-local because a page's request reaches the adapter from the page's own
    /// message handler, outside the test's task.
    static var answersForTesting: [UUID: @MainActor ([VaultListing]) async -> UUID?] = [:]

    static func present(
        _ candidates: [VaultListing], reason: VaultChoiceReason, profileID: UUID, in anchor: ASPresentationAnchor
    ) async -> UUID? {
        guard !candidates.isEmpty else { return nil }
        if let answer = answersForTesting[profileID] {
            return await answer(candidates)
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Which vault?")
        alert.informativeText = switch reason {
        case .matchInSeveral:
            String(localized: "This login is saved in more than one unlocked vault.")
        case .noneMatchedLockedExists:
            String(localized: "No unlocked vault has this login, and another vault is locked and may hold it.")
        case .defaultLocked:
            String(localized: "The default vault is locked.")
        }
        for candidate in candidates {
            let title = candidate.name ?? String(localized: "Vault \(candidate.ordinal) (locked)")
            alert.addButton(withTitle: title)
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard case .response(let response) = await NativeSheet.present(alert, in: anchor, until: nil) else { return nil }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return candidates.indices.contains(index) ? candidates[index].vaultID : nil
    }
}
