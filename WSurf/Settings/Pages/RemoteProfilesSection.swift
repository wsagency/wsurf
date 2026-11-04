// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfCore

/// On the Profiles page: profiles whose vaults another Mac syncs through iCloud and that this Mac does not have. Adding one makes a
/// profile with the same ID, so its vaults open here. Present only while vault sync exists.
struct RemoteProfilesSection: View {
    let store: ProfileStore

    var body: some View {
        if let sync = CloudSync.shared?.vaults {
            // Read here, so the list follows the profiles this Mac has.
            let here = Set(store.profiles.map(\.id))
            let missing = sync.remoteProfiles().filter { !here.contains($0.id) }
            if !missing.isEmpty {
                SettingsSection(title: "On your other devices", symbol: "icloud") {
                    ForEach(Array(missing.enumerated()), id: \.element.id) { index, remote in
                        if index > 0 {
                            RowSeparator()
                        }
                        DetailRow(
                            verbatimTitle: remote.card.name,
                            verbatimCaption: String(localized: "Its vaults sync through iCloud. Add it to use them on this Mac.")
                        ) {
                            Button("Add to This Mac") {
                                store.adopt(
                                    id: remote.id, name: remote.card.name, symbol: remote.card.symbol,
                                    color: TabFolderColor(rawValue: remote.card.color) ?? .gray
                                )
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }
}
