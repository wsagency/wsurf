// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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
}
