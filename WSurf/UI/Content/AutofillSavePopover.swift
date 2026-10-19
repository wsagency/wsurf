// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct AutofillSaveBadge: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    var body: some View {
        if !coordinator.isShowingSettings, let tab = browser.activeTab, tab.internalPage == nil {
            TabAutofillSaveBadge(session: tab.autofillSave, setUpVault: { coordinator.openSettings(.autofill) })
                .id(tab.id)
        }
    }
}

private struct TabAutofillSaveBadge: View {
    let session: AutofillSaveSession
    let setUpVault: () -> Void
    @State private var pendingReview: AutofillSaveSession.Offer?
    @State private var reviewing: AutofillSaveSession.Offer?

    var body: some View {
        @Bindable var session = session
        Group {
            if let offer = session.current {
                ChromeIcon(symbol: offer.symbol, weight: .semibold, tint: Theme.accent,
                           help: String(localized: offer.title)) {
                    session.isPopoverPresented.toggle()
                }
                .accessibilityLabel(Text(offer.title))
            } else if let offer = session.websiteOffer {
                ChromeIcon(symbol: "key", weight: .semibold, tint: Theme.accent, help: String(localized: offer.title)) {
                    session.isPopoverPresented.toggle()
                }
                .accessibilityLabel(Text(offer.title))
            }
        }
        .popover(isPresented: $session.isPopoverPresented, arrowEdge: .bottom) {
            if let offer = session.current {
                AutofillSavePopover(session: session, offer: offer, setUpVault: setUpVault) {
                    pendingReview = offer
                    session.isPopoverPresented = false
                }
                .id(offer.id)
                .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
                .onDisappear {
                    if let pendingReview, session.current?.id == pendingReview.id {
                        reviewing = pendingReview
                    }
                    pendingReview = nil
                }
            } else if let offer = session.websiteOffer {
                AutofillWebsitePopover(session: session, offer: offer)
                    .id(offer.id)
                    .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
            }
        }
        .sheet(item: $reviewing) { offer in
            AutofillSaveReview(session: session, offer: offer)
        }
        .onChange(of: session.current?.id) { _, id in
            if reviewing?.id != id {
                reviewing = nil
            }
            if pendingReview?.id != id {
                pendingReview = nil
            }
        }
        .onDisappear {
            session.isPopoverPresented = false
            pendingReview = nil
            reviewing = nil
        }
    }
}

private extension AutofillSaveSession.Offer {
    var title: LocalizedStringResource {
        guard !needsVault else { return "Save passwords in Credential Manager?" }
        return switch candidate.kind {
        case .password:
            isUpdate ? "Update password?" : "Save password?"
        case .card:
            isUpdate ? "Update card?" : "Save card?"
        case .contact:
            "Save address?"
        }
    }

    var symbol: String {
        switch candidate.kind {
        case .password:
            "key"
        case .card:
            "creditcard"
        case .contact:
            "person.crop.rectangle"
        }
    }

}

private extension AutofillSaveSession.WebsiteOffer {
    var title: LocalizedStringResource {
        "Add \(host) to “\(name)”?"
    }
}

/// The offer to add the page's website to a saved login of a sibling website. It names the login and holds no secret; only "Add
/// Website" writes, and it writes nothing but the website.
private struct AutofillWebsitePopover: View {
    let session: AutofillSaveSession
    let offer: AutofillSaveSession.WebsiteOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(offer.title).font(.headline)
                    Text("This saved login is then offered on \(offer.host) too. No copy is saved.")
                        .font(Theme.Font.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = session.error {
                Text(verbatim: error)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 8) {
                if session.isBusy {
                    Spinner(size: 14)
                }
                Spacer(minLength: 0)
                Button("Not Now") { session.dismissWebsite(offer) }
                Button("Add Website") { Task { await session.addWebsite(offer) } }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            .disabled(session.isBusy)
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Autofill save suggestion")
    }
}

private struct AutofillSavePopover: View {
    let session: AutofillSaveSession
    let offer: AutofillSaveSession.Offer
    let setUpVault: () -> Void
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AutofillSaveDescription(offer: offer)
            if let error = session.error {
                Text(verbatim: error)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offer.isGone {
                AutofillGoneOfferActions(session: session, offer: offer)
            } else if offer.needsVault {
                AutofillVaultSetupActions(session: session, offer: offer, setUpVault: setUpVault)
            } else {
                AutofillSaveActions(session: session, offer: offer, review: review)
            }
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Autofill save suggestion")
    }
}

private struct AutofillSaveDescription: View {
    let offer: AutofillSaveSession.Offer

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: offer.symbol)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(offer.title).font(.headline)
                Text(verbatim: offer.origin).font(Theme.Font.label).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                if offer.needsVault {
                    Text("""
                        WSurf saves passwords in an encrypted vault that you unlock with a passkey. There is no recovery: if you lose \
                        every passkey that unlocks the vault, its passwords can’t be recovered. This password isn’t saved now. After you \
                        set up the vault, sign in again to save it.
                        """)
                        .font(Theme.Font.label)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: offer.candidate.summary).font(Theme.Font.label)
                        .lineLimit(offer.candidate.kind == .contact ? 4 : 2)
                        .truncationMode(.middle)
                        .help(offer.candidate.summary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AutofillSaveActions: View {
    let session: AutofillSaveSession
    let offer: AutofillSaveSession.Offer
    let review: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Review Details…", action: review)
                Spacer(minLength: 8)
                Button("Never for This Site") { Task { await session.never(offer) } }
            }
            .buttonStyle(.link)
            .font(Theme.Font.label)
            Divider()
            HStack(spacing: 8) {
                if session.isBusy {
                    Spinner(size: 14)
                }
                Spacer(minLength: 0)
                Button("Not Now") { session.dismiss(offer) }
                Button(offer.isUpdate ? "Update" : "Save") { Task { await session.save(offer) } }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .disabled(session.isBusy)
    }
}

/// What is left of an offer whose page changed: the reason is shown above, and the only thing to do is to close it. Dismissing it
/// is not a refusal, so the same login is offered again from the page the user is on.
private struct AutofillGoneOfferActions: View {
    let session: AutofillSaveSession
    let offer: AutofillSaveSession.Offer

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button("OK") { session.dismiss(offer, rememberingChoice: false) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
    }
}

/// What the offer to set up the first vault allows. It saves nothing, so there is nothing to review, save or exclude: only the
/// way to the setup, which asks nothing of the page.
private struct AutofillVaultSetupActions: View {
    let session: AutofillSaveSession
    let offer: AutofillSaveSession.Offer
    let setUpVault: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Not Now") { session.dismiss(offer) }
            Button("Set Up Vault…") {
                session.dismiss(offer, rememberingChoice: false)
                setUpVault()
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
    }
}
