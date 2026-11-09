// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI

struct CommandPalette: View {
    let containerSize: CGSize

    @State private var model: CommandPaletteModel
    @State private var shortcutMonitor: Any?
    @State private var focused = false
    @State private var optionHeld = false

    init(
        browser: BrowserModel,
        coordinator: AppCoordinator,
        containerSize: CGSize,
        dismiss: @escaping () -> Void
    ) {
        self.containerSize = containerSize
        _model = State(initialValue: CommandPaletteModel(
            browser: browser,
            coordinator: coordinator,
            dismiss: dismiss
        ))
    }

    var body: some View {
        @Bindable var model = model
        let layout = CommandPaletteLayout(containerSize: containerSize)

        VStack(spacing: 0) {
            CommandPaletteField(
                placeholder: model.placeholder,
                query: $model.interaction.query,
                chips: model.mentionChips,
                focused: $focused,
                onSubmit: model.submit,
                onCommandSubmit: model.askWhateverIsTyped,
                onMoveSelection: model.moveSelection,
                onMoveSection: model.moveSection,
                onChipsChange: model.mentionsDidChange,
                onDismiss: model.dismiss,
                searchSite: model.searchSite,
                showsArchive: model.showsArchive,
                scopeHint: model.scopeHint,
                onActivateSite: model.activateSiteSearch,
                onRemoveSite: model.removeSearchSite
            )
            .frame(height: CommandPaletteLayout.fieldHeight)

            CommandPaletteResultsView(
                sections: model.sections,
                settings: model.coordinator.context.settings,
                query: model.resultQuery,
                selection: model.interaction.selection,
                optionHeld: optionHeld,
                maxHeight: layout.maxListHeight,
                onSelect: model.hoverSuggestion,
                onRun: model.run,
                onRunAlternate: model.runAlternate,
                onRemove: model.remove(at:)
            )

            AskContextStrip(pages: model.contextPages)
        }
        .frame(width: layout.panelWidth)
        .background {
            CommandPaletteGlass(referenceHeight: CommandPaletteLayout.fieldHeight + layout.maxListHeight)
        }
        .shadow(color: .black.opacity(0.4), radius: 44, y: 18)
        .padding(.top, layout.topInset)
        .onAppear {
            optionHeld = CommandPaletteShortcutPolicy.showsCurrentTab(modifiers: NSEvent.modifierFlags)
            model.prepare()
            watchForShortcuts(model: model)
        }
        .task {
            focused = true
        }
        .onDisappear {
            if let shortcutMonitor {
                NSEvent.removeMonitor(shortcutMonitor)
                self.shortcutMonitor = nil
            }
        }
        .modifier(CommandPaletteSuggestionSync(
            suggestions: model.suggestions,
            onChange: model.suggestionsDidChange
        ))
        .onKeyPress(.escape) {
            model.dismiss()
            return .handled
        }
    }

    private func watchForShortcuts(model: CommandPaletteModel) {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let consumed = MainActor.assumeIsolated {
                let window = model.coordinator.nativeWindow
                return CommandPaletteShortcutPolicy.consumes(
                    event, paletteWindow: window, isKey: window?.isKeyWindow ?? false,
                    setOptionHeld: { optionHeld = $0 }, submitInCurrentTab: { model.submitInCurrentTab() }, dismiss: { model.dismiss() }
                )
            }
            return consumed ? nil : event
        }
    }
}
