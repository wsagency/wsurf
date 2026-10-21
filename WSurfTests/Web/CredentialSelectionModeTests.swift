// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Selection mode (Select in a row's menu) and the row's right-click menu. Pure: rows in, a selection and menu entries out.
@MainActor
struct CredentialSelectionModeTests {
    private let ids = (0..<5).map { _ in UUID() }

    private func makeSelection() -> CredentialSelection {
        let selection = CredentialSelection()
        selection.show(ids)
        return selection
    }

    private func summary(_ id: UUID, username: String? = "ada", password: String? = "pw", website: Bool = true) -> CredentialSummary {
        var account = VaultFixtures.account(id: id, username: username ?? "", password: password, origin: "https://example.test")
        if !website {
            account.origins = []
            account.loginURLs = []
        }
        return CredentialSummary(account)
    }

    @Test func selectStartsTheModeWithTheRowSelectedAndClicksToggle() {
        let selection = makeSelection()
        #expect(!selection.showsCheckboxes)
        selection.beginSelecting(with: ids[1])
        #expect(selection.isSelecting && selection.showsCheckboxes && selection.ownsKeyboard)
        #expect(selection.selected == [ids[1]])

        selection.click(ids[3])
        #expect(selection.selected == [ids[1], ids[3]], "a plain click toggles a row while selecting")
        selection.click(ids[1])
        #expect(selection.selected == [ids[3]])
        selection.click(ids[3])
        #expect(selection.selected.isEmpty && selection.isSelecting, "deselecting the last row keeps the mode")
        #expect(selection.selectedInOrder.isEmpty, "the bar acts on nothing, never on the cursor row")
        #expect(selection.targets == [ids[3]], "the keyboard's X still acts on the cursor row")
    }

    @Test func doneEscapeAndAnotherVaultEndTheMode() {
        let selection = makeSelection()
        selection.beginSelecting(with: ids[0])
        selection.clear()
        #expect(!selection.isSelecting && selection.selected.isEmpty && !selection.showsCheckboxes)

        selection.beginSelecting(with: nil)
        #expect(selection.showsCheckboxes, "Escape is offered while selecting, even with nothing selected")
        #expect(CredentialListKeys.command(for: CredentialKeyInput(key: .escape), in: .init(hasSelection: selection.showsCheckboxes)) == .clear)
        selection.reset()
        #expect(!selection.isSelecting)
    }

    @Test func outsideTheModeAPlainClickStillSelectsNothing() {
        let selection = makeSelection()
        selection.toggle(ids[2])
        #expect(selection.showsCheckboxes, "a selected row shows the checkboxes")
        selection.click(ids[4])
        #expect(selection.selected == [ids[2]] && selection.cursor == ids[4])
    }

    @Test func theMenuActsOnTheSelectionTheRowBelongsTo() {
        let selection = makeSelection()
        selection.toggle(ids[3])
        selection.toggle(ids[1])
        #expect(selection.menuTargets(for: ids[3]) == [ids[1], ids[3]], "in list order")
        #expect(selection.menuTargets(for: ids[0]) == [ids[0]], "a row outside the selection acts alone")
        selection.toggle(ids[3])
        #expect(selection.menuTargets(for: ids[1]) == [ids[1]], "one selected row is the row alone")
    }

    @Test func theMenuOffersOnlyWhatTheCredentialHas() throws {
        let selection = makeSelection()
        let full = summary(ids[0])
        let website = try #require(full.website)
        #expect(selection.menu(for: full) == [
            .openWebsite(website), .copyUsername, .copyPassword, .edit, .merge([ids[0]]), .moveToTrash([ids[0]]), .select,
        ])
        let bare = summary(ids[1], username: nil, password: nil, website: false)
        #expect(selection.menu(for: bare) == [.edit, .merge([ids[1]]), .moveToTrash([ids[1]]), .select])

        selection.toggle(ids[0])
        selection.toggle(ids[1])
        #expect(selection.menu(for: bare).suffix(3) == [.merge([ids[0], ids[1]]), .moveToTrash([ids[0], ids[1]]), .deselect])
    }
}
