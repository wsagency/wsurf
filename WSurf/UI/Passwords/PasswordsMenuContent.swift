// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation

/// What the popover's list draws and where its keyboard is: the query, the selection and the lists as last read. The lists are
/// computed in `refresh()`, outside the view body (the vault allows 25,000 credentials), so they are a copy that a lock does not
/// reach by itself. `sections` is therefore the one gate: it answers only while the model's session is backed by the manager's current
/// authorization, so a lock empties the popover at once, before any refresh.
@MainActor
@Observable
final class PasswordsMenuContent {
    let model: CredentialSettingsModel
    /// The origin of the front browser tab when the popover opened, for "Matching This Website".
    let origin: String?
    var query = ""
    var selection: UUID?
    private var read: (sections: PasswordsMenuList.Sections, epoch: UInt64)?

    init(model: CredentialSettingsModel, origin: String?) {
        self.model = model
        self.origin = origin
    }

    /// What may be drawn: the lists while the vault is unlocked and read, nil in every other state, and nil for lists read under an
    /// earlier unlock, which a quick lock and unlock would otherwise show for a moment before the next refresh.
    var sections: PasswordsMenuList.Sections? {
        guard model.menuPhase == .content, let read, read.epoch == model.authorizationEpoch else { return nil }
        return read.sections
    }

    var rows: [CredentialSummary] {
        sections?.rows ?? []
    }

    var selected: CredentialSummary? {
        rows.first { $0.id == selection }
    }

    /// Reads the lists again for the query and the vault as they are now, and keeps the selection on a row that is still listed.
    func refresh() {
        if let sections = model.menuSections(query: query, origin: origin), let epoch = model.authorizationEpoch {
            read = (sections, epoch)
        } else {
            read = nil
        }
        let rows = self.rows
        if !rows.contains(where: { $0.id == selection }) {
            selection = rows.first?.id
        }
    }

    /// Moves the selection by `step` rows, stopping at the ends. False when there is no row to move to.
    func move(_ step: Int) -> Bool {
        let rows = self.rows
        guard !rows.isEmpty else { return false }
        let current = rows.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : rows.count)
        selection = rows[min(max(current + step, 0), rows.count - 1)].id
        return true
    }
}
