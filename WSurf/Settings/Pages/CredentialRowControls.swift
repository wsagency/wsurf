// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

// The trailing controls of a credential row, drawn instead of built from AppKit controls. A list of thousands scrolls, and every row
// that comes into view used to create a pop-up button and three bordered buttons, which was most of what a row cost to build (the
// same reason the selection checkbox is drawn). These look the same as the system's bordered button and borderless menu; the menu
// itself is built when it is clicked, not for every row.

/// The system's bordered push button at the regular size, drawn: a flat rounded bezel, 24 pt high (22 pt for an icon alone).
struct CredentialRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// An image with no title is 22 pt high; one with a title is 24.
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 12)
            .frame(height: iconOnly ? 22 : 24)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.16 : 0.092))
            }
            .opacity(isEnabled ? 1 : 0.47)
            // The hit area and the system's keyboard focus ring (Full Keyboard Access) follow the bezel.
            .contentShape([.interaction, .focusEffect], RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// What a credential row's "…" menu offers, in order. Pure, so which entries a row offers is tested without a view.
enum CredentialRowMoreItem: Equatable {
    case copyUsername
    case copyPassword
    case copyWebsite
    case copyCode
    case copyHidden(SecureFieldReference)
    case showPassword
    case hidePassword
    case showUsername
    case hideUsername
    case showCode
    case hideCode
    case showDetails
    case hideDetails
    case divider
    case history
    case merge

    /// What the model shows of this credential right now, which decides Show or Hide.
    struct Revealed: Equatable {
        var password = false
        var username = false
        var code = false
        var details = false
    }

    static func items(for summary: CredentialSummary, revealed: Revealed) -> [Self] {
        var items: [Self] = []
        if summary.usernameIsConcealed || summary.username != nil {
            items.append(.copyUsername)
        }
        if summary.hasPassword {
            items.append(.copyPassword)
        }
        if !summary.origins.isEmpty {
            items.append(.copyWebsite)
        }
        if summary.hasTOTP {
            items.append(.copyCode)
        }
        // A card's or an ID document's hidden value asks for Touch ID before it is copied.
        items += summary.hiddenItemFields.map(Self.copyHidden)
        if summary.hasPassword {
            items.append(revealed.password ? .hidePassword : .showPassword)
        }
        if summary.usernameIsConcealed {
            items.append(revealed.username ? .hideUsername : .showUsername)
        }
        if summary.hasTOTP {
            items.append(revealed.code ? .hideCode : .showCode)
        }
        if !summary.itemKinds.isEmpty {
            items.append(revealed.details ? .hideDetails : .showDetails)
        }
        return items + [.divider, .history, .merge]
    }

    var title: String {
        switch self {
        case .copyUsername:
            String(localized: "Copy Username")
        case .copyPassword:
            String(localized: "Copy Password")
        case .copyWebsite:
            String(localized: "Copy Website")
        case .copyCode:
            String(localized: "Copy Verification Code")
        case .copyHidden(let reference):
            String(localized: "Copy \(reference.label)")
        case .showPassword:
            String(localized: "Show Password")
        case .hidePassword:
            String(localized: "Hide Password")
        case .showUsername:
            String(localized: "Show Username")
        case .hideUsername:
            String(localized: "Hide Username")
        case .showCode:
            String(localized: "Show Verification Code")
        case .hideCode:
            String(localized: "Hide Verification Code")
        case .showDetails:
            String(localized: "Show Details")
        case .hideDetails:
            String(localized: "Hide Details")
        case .divider:
            ""
        case .history:
            String(localized: "History…")
        case .merge:
            String(localized: "Merge…")
        }
    }
}

/// The "…" of a row: a pull-down pop-up button, as the borderless `Menu` was (same role for VoiceOver, the menu anchored under it, the
/// system focus ring), with an empty menu that is filled when it opens (`menuNeedsUpdate`), so a row that is never opened builds no entries.
struct CredentialRowMoreButton: NSViewRepresentable {
    let model: CredentialSettingsModel
    let summary: CredentialSummary
    let selection: CredentialSelection
    let actions: CredentialRowActions

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.imagePosition = .imageOnly
        let title = NSMenuItem()
        title.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        button.menu?.addItem(title)
        button.menu?.autoenablesItems = false
        button.menu?.delegate = context.coordinator
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setAccessibilityLabel(String(localized: "More actions for \(summary.title)"))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.row = self
        button.setAccessibilityLabel(String(localized: "More actions for \(summary.title)"))
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var row: CredentialRowMoreButton

        init(_ row: CredentialRowMoreButton) {
            self.row = row
        }

        /// The entries for what the model shows right now, made when the menu opens.
        func menuNeedsUpdate(_ menu: NSMenu) {
            while menu.numberOfItems > 1 {
                menu.removeItem(at: 1)
            }
            let row = row
            let revealed = CredentialRowMoreItem.Revealed(
                password: row.model.revealedPassword?.accountID == row.summary.id,
                username: row.model.revealedUsername?.accountID == row.summary.id,
                code: row.model.shownTOTPAccountID == row.summary.id, details: row.model.revealedItems?.accountID == row.summary.id
            )
            for item in CredentialRowMoreItem.items(for: row.summary, revealed: revealed) {
                if item == .divider {
                    menu.addItem(.separator())
                    continue
                }
                let entry = NSMenuItem(title: item.title, action: #selector(RowMenuAction.fire), keyEquivalent: "")
                let action = RowMenuAction { row.perform(item) }
                entry.target = action
                entry.representedObject = action
                entry.isEnabled = item != .merge || !row.model.isBusy
                menu.addItem(entry)
            }
        }
    }

    func perform(_ item: CredentialRowMoreItem) {
        let id = summary.id
        let model = model
        switch item {
        case .copyUsername:
            actions.run { try await model.copy(.username, of: .stored(id)) }
        case .copyPassword:
            actions.run { try await model.copyPassword(accountID: id) }
        case .copyWebsite:
            actions.run { try await model.copy(.website(0), of: .stored(id)) }
        case .copyCode:
            actions.run { try await model.copyTOTP(accountID: id) }
        case .copyHidden(let reference):
            actions.run { try await model.copy(.secureField(item: reference.item, field: reference.field), of: .stored(id)) }
        case .showPassword:
            actions.run { try await model.revealPassword(accountID: id) }
        case .showUsername:
            actions.run { try await model.revealUsername(accountID: id) }
        case .showCode:
            actions.run { try await model.showTOTP(accountID: id) }
        case .showDetails:
            actions.run { try await model.revealSecureItems(accountID: id) }
        case .hidePassword, .hideUsername, .hideCode, .hideDetails:
            model.hideSecrets()
        case .history:
            actions.history(id)
        case .merge:
            actions.merge(selection.menuTargets(for: id))
        case .divider:
            break
        }
    }
}

/// What a menu entry does. The entry keeps it (`representedObject`) for as long as the menu is open.
private final class RowMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}
