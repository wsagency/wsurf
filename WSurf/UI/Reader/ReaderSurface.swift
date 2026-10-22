// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

/// The address bar's Reader control. It appears while the page in front holds an article, and while Reader shows it.
struct ReaderBadge: View {
    let coordinator: AppCoordinator

    var body: some View {
        if let tab = coordinator.readerTab, tab.reader.isAvailable {
            let isActive = tab.reader.isActive
            let title: LocalizedStringResource = isActive ? "Hide Reader" : "Show Reader"
            let help: LocalizedStringResource = isActive ? "Hide Reader (⌥⌘R)" : "Show Reader (⌥⌘R)"
            ChromeIcon(
                symbol: isActive ? "doc.plaintext.fill" : "doc.plaintext",
                weight: .semibold,
                tint: isActive ? Theme.systemAccent : nil,
                help: String(localized: help)
            ) {
                tab.reader.toggle()
            }
            .disabled(tab.reader.isOpening)
            .accessibilityLabel(Text(title))
        }
    }
}

/// Raises the article over the page when the tab's Reader starts and lowers it when Reader ends.
struct ReaderPresenter: View {
    let tab: BrowserTab

    @State private var article: ReaderArticle?
    @State private var isRaised = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let article {
                    ReaderSurface(tab: tab, article: article)
                        .offset(y: isRaised ? 0 : proxy.size.height)
                }
            }
        }
        .clipped()
        .allowsHitTesting(article != nil)
        .onAppear {
            guard tab.reader.isActive else { return }
            article = tab.reader.article
            isRaised = true
        }
        .onChange(of: tab.reader.isActive) { _, isActive in
            isActive ? raise() : lower()
        }
    }

    private func raise() {
        guard let next = tab.reader.article else { return }
        article = next
        guard !reduceMotion else {
            isRaised = true
            return
        }
        isRaised = false
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.4)) {
                isRaised = true
            }
        }
    }

    private func lower() {
        guard article != nil else { return }
        guard !reduceMotion else {
            isRaised = false
            article = nil
            return
        }
        withAnimation(.smooth(duration: 0.32)) {
            isRaised = false
        } completion: {
            if !tab.reader.isActive {
                article = nil
            }
        }
    }
}

/// The article in the browser's own chrome, the same for a WebKit and a Chromium tab: the page is read out of either engine and
/// shown by one WebKit view.
struct ReaderSurface: View {
    let tab: BrowserTab
    let article: ReaderArticle

    @Environment(\.colorScheme) private var scheme

    private var settings: BrowserSettings {
        BrowserSettings.application
    }

    private var palette: ReaderAppearance.Palette {
        settings.readerPalette.resolved(isDark: scheme == .dark)
    }

    var body: some View {
        ReaderWebView(
            session: tab.reader,
            article: article,
            profile: tab.context,
            typeface: settings.readerTypeface,
            palette: settings.readerPalette,
            textSize: settings.readerTextSize,
            onOpenLink: { url, activate in tab.onOpenInNewTab?(url, activate) }
        )
        .background(Color(nsColor: palette.background))
        .overlay(alignment: .topTrailing) {
            ReaderToolbar(tab: tab, palette: palette)
                .padding(.top, tab.find.isActive ? 54 : 10)
                .padding(.trailing, 14)
                .animation(Theme.Motion.settle, value: tab.find.isActive)
        }
        .accessibilityAddTraits(.isModal)
    }
}
