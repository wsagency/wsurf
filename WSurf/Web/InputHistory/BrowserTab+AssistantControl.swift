// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension BrowserTab {
    /// True while the in-app assistant works in this tab's space, or a connected app is in the middle of a call on this tab: the
    /// state behind the tab's agent-working marker. Input History records only the person's own typing, so it records nothing
    /// in a tab under this control. Typing the person does in that tab meanwhile is not recorded either.
    ///
    /// Input History reads this state. Nothing in the assistant or the connected-app server refers to Input History.
    var isUnderAssistantControl: Bool {
        isAgentWorking || processState.isExternalAutomationWorking
    }

    /// The assistant works in this tab, or a connected app is in a call on it or holds it (the AI mark). Whatever an agent can read
    /// on the page must never be a filled secret, so nothing is offered for autofill then: no Pick Credential…
    /// (`allowsCredentialPicker`), no password, code, card or address suggestion and no save offer (`AutofillSaveSession.isAgentControlled`,
    /// asked again at every fill's dispatch). The one predicate for all of them.
    var isAgentControlled: Bool {
        isUnderAssistantControl || !processState.externalControllers.isEmpty
    }

    /// The tab's part of whether Pick Credential… is offered (`CredentialPicker.isOffered` adds the vault's): never in a private
    /// window, never while an agent controls the tab (`isAgentControlled`), and never on an internal page.
    var allowsCredentialPicker: Bool {
        !isPrivate && !isClosed && !isAgentControlled && internalPage == nil
    }

    /// Why `view`'s editable fields show Pick Credential… disabled instead of leaving it out (`CredentialPicker.refusal`); nil on a
    /// closed tab or an internal page, which never show it.
    func credentialPickerRefusal(in view: BrowserPage) -> CredentialPicker.Refusal? {
        guard !isClosed, internalPage == nil else { return nil }
        return CredentialPicker.refusal(in: view, agentControlled: isAgentControlled)
    }

    /// Control started: no offer of the tab stays on screen, and nothing staged before it is offered afterwards. Offers come back with
    /// the next focus once control ends. A Pick Credential… or Generate Password… sheet of the tab closes as a Cancel, so a generated
    /// password is never on screen while an agent works in the tab; other tabs' sheets stay.
    func agentControlChanged() {
        guard isAgentControlled else { return }
        autofillSave.clear()
        if let liveView {
            AutofillSuggestions.shared.dismiss(in: liveView)
            CredentialPickerSheet.dismiss(page: liveView)
        }
    }
}
