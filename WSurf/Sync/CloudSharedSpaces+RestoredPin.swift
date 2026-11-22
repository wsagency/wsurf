// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
    /// The pin store can commit a Favorite before its window saves the tab's pin ID, or while that window is closed.
    func restoredPinPages(in browser: BrowserModel, missing pins: Set<UUID>) -> [UUID: (pin: UUID, space: UUID)] {
        let profile = browser.context.profile
        guard !pins.isEmpty, storageReadable, browser.windowKind == .standard, isEnabled(.pins, for: profile), isEnabled(.spaces, for: profile),
              let link = links[profile.id], let group = link.profile, let owner = catalog.state.user,
              permitsSharedInstance?(group, owner) != false else { return [:] }
        var pinsByTab: [UUID: [UUID]] = [:]
        for (local, shared) in link.pins where pins.contains(local) {
            guard link.skippedPins?.contains(shared) != true, let pin = catalog.item(shared, in: .pins),
                  pin.id == shared, pin.kind == .pin, pin.profileID == group, !pin.removed, let tab = pin.sharedTabID else { continue }
            pinsByTab[tab, default: []].append(local)
        }
        var pages: [UUID: (pin: UUID, space: UUID)] = [:]
        for (tab, slot) in link.slots where slot.window == browser.windowID {
            guard let candidates = pinsByTab[slot.cloudID],
                  let pin = slot.pinID ?? (candidates.count == 1 ? candidates.first : nil), candidates.contains(pin),
                  let space = savedSpace(of: .tab(tab), in: browser, pinID: pin) else { continue }
            pages[tab] = (pin, space)
        }
        return pages
    }
}
