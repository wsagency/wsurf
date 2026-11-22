// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Observation
import WSurfCore
import WSurfVault

extension Profile {
    func vaultPickerLabel(among profiles: [Profile]) -> String {
        func name(_ profile: Profile) -> String {
            if case let .published(source) = profile.publicationOrigin, let mac = source?.macName {
                return "\(profile.name) · \(mac)"
            }
            return profile.name
        }
        let label = name(profiles.first { $0.id == id } ?? self)
        let peers = profiles.filter { name($0) == label }
        guard peers.count > 1 else { return label }
        return "\(label) (\(id.shortestUniquePrefix(in: peers.map(\.id))))"
    }
}

@MainActor
final class SpaceVaultPicker: NSPopUpButton {
    struct Option {
        let profile: Profile
        let profileLabel: String
        let listing: VaultListing
        let epoch: UInt64?

        var id: SpaceVaultReference {
            .init(profileID: profile.id, vaultID: listing.vaultID)
        }

        var title: String {
            let manager = CredentialManager.unlockedManagers(for: profile).first { $0.vaultID == id.vaultID }
            let name: String
            if let manager {
                name = manager.authorizationEpoch == epoch && epoch != nil ? listing.label : listing.numberedName
            } else {
                name = String(localized: "Vault \(listing.ordinal) (locked)")
            }
            return "\(profileLabel) · \(name)"
        }
    }

    struct Choices {
        var options: [Option] = []
        var hasUnreadableProfile = false

        static func load(from profiles: [Profile]) async -> Self {
            var choices = Self()
            for profile in profiles where !profile.isPrivate {
                let changes = VaultStateChanges.shared.count(for: profile.id)
                do {
                    let store = try CredentialManager.store(for: profile)
                    let state = await store.openState()
                    if state == .firstRun {
                        continue
                    }
                    guard state.isProvisional else {
                        choices.hasUnreadableProfile = true
                        continue
                    }
                    let listing = try await store.listing()
                    let open = CredentialManager.unlockedManagers(for: profile)
                    let label = profile.vaultPickerLabel(among: profiles)
                    for vault in listing {
                        let manager = open.first { $0.vaultID == vault.vaultID }
                        choices.options.append(Option(
                            profile: profile, profileLabel: label, listing: vault,
                            epoch: changes == VaultStateChanges.shared.count(for: profile.id) ? manager?.authorizationEpoch : nil
                        ))
                    }
                } catch {
                    choices.hasUnreadableProfile = true
                }
            }
            return choices
        }
    }

    private let options: [Option]

    init(_ choices: Choices, selected: SpaceVaultReference?) {
        options = choices.options
        super.init(frame: .zero, pullsDown: false)
        addItem(withTitle: String(localized: "Use the profile’s vault settings"))
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.id
            menu?.addItem(item)
        }
        if let selected {
            if let index = options.firstIndex(where: { $0.id == selected }) {
                selectItem(at: index + 1)
            } else {
                let missing = NSMenuItem(title: String(localized: "Selected vault unavailable"), action: nil, keyEquivalent: "")
                missing.representedObject = selected
                menu?.addItem(missing)
                select(missing)
            }
        }
        setAccessibilityLabel(String(localized: "Credential vault"))
        cell?.lineBreakMode = .byTruncatingTail
        widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        refreshLabels()
        sizeToFit()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    var vault: SpaceVaultReference? {
        selectedItem?.representedObject as? SpaceVaultReference
    }

    func selectedReference() throws -> SpaceVaultReference? {
        if indexOfSelectedItem == 0 {
            return nil
        }
        guard let vault else { throw SpaceEditorError.vaultUnavailable }
        return vault
    }

    private func refreshLabels() {
        withObservationTracking {
            for (index, option) in options.enumerated() {
                _ = VaultStateChanges.shared.count(for: option.id.profileID)
                item(at: index + 1)?.title = option.title
            }
            synchronizeTitleAndSelectedItem()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.refreshLabels() }
        }
    }
}
