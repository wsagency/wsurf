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
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect)
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

/// The "…" of a row: a drawn glyph and chevron that look like the borderless menu, and a menu made when it is clicked.
struct CredentialRowMoreButton: View {
    let model: CredentialSettingsModel
    let summary: CredentialSummary
    let selection: CredentialSelection
    let actions: CredentialRowActions

    var body: some View {
        Button(action: present) {
            HStack(spacing: 1.5) {
                Image(systemName: "ellipsis.circle")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
            }
            .padding(.trailing, 5)
            .foregroundStyle(Color(nsColor: .labelColor))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions for \(summary.title)")
    }

    /// The menu for what the model shows right now, built on the click.
    private func menu() -> NSMenu {
        let revealed = CredentialRowMoreItem.Revealed(
            password: model.revealedPassword?.accountID == summary.id, username: model.revealedUsername?.accountID == summary.id,
            code: model.shownTOTPAccountID == summary.id, details: model.revealedItems?.accountID == summary.id
        )
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in CredentialRowMoreItem.items(for: summary, revealed: revealed) {
            if item == .divider {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: #selector(RowMenuAction.fire), keyEquivalent: "")
            let action = RowMenuAction { perform(item) }
            entry.target = action
            entry.representedObject = action
            entry.isEnabled = item != .merge || !model.isBusy
            menu.addItem(entry)
        }
        return menu
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

    private func present() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        let event = NSApp.currentEvent
        let point = event?.window === window ? event?.locationInWindow : nil
        menu().popUp(positioning: nil, at: content.convert(point ?? window.mouseLocationOutsideOfEventStream, from: nil), in: content)
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
