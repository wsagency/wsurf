// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension AppCoordinator {
    func configureWindowAgentTransfer() {
        let previous = browser.onTabWillTransferOut
        browser.onTabWillTransferOut = { [weak self] tab in
            previous?(tab)
            guard let self else { return }
            let spaceID = browser.spaceID(of: tab.id)
            endVoiceConversation()
            voiceInput.cancel()
            agentTurns.detachTab(tab.id, inSpace: spaceID)
            tab.setAgentWorking(false)
            statusMessage = nil
            linkPeek.dismiss()
            if peek.belongs(to: tab.id) {
                closePeekImmediately()
            }
            playedPages[tab.id] = nil
            if media.controlledTabID == tab.id {
                media.releaseControl()
            }
            conversationLog.saveNow()
        }
    }
}
