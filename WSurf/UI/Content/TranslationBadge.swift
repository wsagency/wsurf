// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// The address bar's translate control. It appears when the page is in a language the person does not read, or while the page is
/// translated, and tells VoiceOver when the shown page's translation changes.
struct TranslationBadge: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    private var tab: BrowserTab? {
        guard let tab = browser.activeTab, tab.isMaterialised, !tab.isShowingSystemPage,
              tab.translation.isActive || !tab.translation.targets.isEmpty
        else { return nil }
        return tab
    }

    var body: some View {
        Group {
            if let tab {
                TranslationMenu(tab: tab, coordinator: coordinator)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: tab?.id)
        .onChange(of: TranslationAnnouncement.State(tab: browser.activeTab)) { old, new in
            guard let text = TranslationAnnouncement.text(from: old, to: new) else { return }
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// What VoiceOver hears about the shown page's translation.
enum TranslationAnnouncement {
    struct State: Equatable {
        let tabID: UUID?
        let phase: PageTranslation.Phase
        let target: Locale.Language?

        init(tabID: UUID?, phase: PageTranslation.Phase, target: Locale.Language?) {
            self.tabID = tabID
            self.phase = phase
            self.target = target
        }

        init(tab: BrowserTab?) {
            self.init(tabID: tab?.id, phase: tab?.translation.phase ?? .original, target: tab?.translation.target)
        }
    }

    /// The announcement for a change of the same tab's translation: when its text has been replaced and when the original is
    /// back. Bringing another tab to the front announces nothing.
    static func text(from old: State, to new: State) -> String? {
        guard old.tabID == new.tabID, old != new else { return nil }
        switch new.phase {
        case .translated:
            guard let target = new.target else { return nil }
            return String(localized: "Page translated to \(TranslationLanguage.name(target))")
        case .original:
            return old.phase == .original ? nil : String(localized: "Showing the original page")
        case .translating:
            return nil
        }
    }

    /// The control's accessibility value.
    static func value(for translation: PageTranslation) -> String {
        guard let target = translation.target else { return String(localized: "Not translated") }
        let name = TranslationLanguage.name(target)
        switch translation.phase {
        case .translating:
            return String(localized: "Translating to \(name)")
        case .translated:
            return String(localized: "Translated to \(name)")
        case .original:
            return String(localized: "Not translated")
        }
    }
}

private struct TranslationMenu: View {
    let tab: BrowserTab
    let coordinator: AppCoordinator

    @State private var hovering = false
    @Environment(\.chromeIsLight) private var chromeIsLight
    @Environment(\.chromeIconExtent) private var extent
    @Environment(\.windowColorScheme) private var windowColorScheme

    private var translation: PageTranslation {
        tab.translation
    }

    private var style: AnyShapeStyle {
        if translation.isActive, Theme.controlOverride(in: windowColorScheme) == nil {
            return AnyShapeStyle(chromeIsLight ? Theme.systemAccent.deepened(by: 0.28) : Theme.systemAccent)
        }
        return ChromeInk.glyph(onLight: chromeIsLight, windowScheme: windowColorScheme, hovering: hovering)
    }

    private func isShowing(_ language: Locale.Language) -> Bool {
        guard translation.isActive, let target = translation.target else { return false }
        return TranslationLanguage.matches(target, language)
    }

    var body: some View {
        Menu {
            ForEach(translation.targets, id: \.self) { language in
                Button("Translate to \(TranslationLanguage.name(language))") {
                    coordinator.translatePage(tab, to: language)
                }
                .disabled(isShowing(language))
            }

            Button("Preferred Languages…") {
                coordinator.openPreferredLanguages()
            }

            Divider()

            Button("Show Original") {
                coordinator.showOriginal(tab)
            }
            .disabled(!translation.isActive)

            if !tab.isPrivate, let source = translation.detectedLanguage {
                Toggle(isOn: Binding(
                    get: { tab.context.settings.alwaysTranslates(source) },
                    set: { coordinator.setAlwaysTranslates($0, source, in: tab) }
                )) {
                    Text("Always Translate \(TranslationLanguage.name(source))")
                }
            }
        } label: {
            Image(systemName: "translate")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(style)
                .frame(width: extent, height: extent)
                .hoverBackground(isActive: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Translate Page")
        .accessibilityLabel(Text("Translate Page"))
        .accessibilityValue(Text(verbatim: TranslationAnnouncement.value(for: translation)))
    }
}
