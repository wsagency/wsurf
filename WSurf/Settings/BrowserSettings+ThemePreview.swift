// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

struct ThemePreview: Equatable {
    let themeID: String
    var adjustment: ThemeAdjustment
    var colors: ThemeVariant?
    var scheme: ColorScheme?

    func applying(to theme: ThemeDefinition) -> ThemeDefinition {
        guard themeID == theme.id, let colors, let scheme else { return theme }
        var theme = theme
        theme.setVariant(colors, for: scheme)
        return theme
    }
}

/// Resting rows observe only their ink, not a slider's changing ground or material.
struct ThemeSidebarInk: Equatable {
    var lightLoaded: Color = .black
    var lightUnloaded: Color = .black.opacity(ThemeVariant.unloadedOpacity)
    var darkLoaded: Color = .white
    var darkUnloaded: Color = .white.opacity(ThemeVariant.unloadedOpacity)
    var lightFloatingLoaded: Color = .black
    var lightFloatingUnloaded: Color = .black.opacity(ThemeVariant.unloadedOpacity)
    var darkFloatingLoaded: Color = .white
    var darkFloatingUnloaded: Color = .white.opacity(ThemeVariant.unloadedOpacity)

    init() {}

    init(_ theme: ResolvedTheme) {
        lightLoaded = theme.light.loadedInk
        lightUnloaded = theme.light.unloadedInk
        darkLoaded = theme.dark.loadedInk
        darkUnloaded = theme.dark.unloadedInk
        lightFloatingLoaded = theme.light.floatingLoadedInk
        lightFloatingUnloaded = theme.light.floatingUnloadedInk
        darkFloatingLoaded = theme.dark.floatingLoadedInk
        darkFloatingUnloaded = theme.dark.floatingUnloadedInk
    }

    func color(isDeferred: Bool, scheme: ColorScheme, isFloating: Bool) -> Color {
        if scheme == .dark {
            if isFloating {
                return isDeferred ? darkFloatingUnloaded : darkFloatingLoaded
            }
            return isDeferred ? darkUnloaded : darkLoaded
        }
        if isFloating {
            return isDeferred ? lightFloatingUnloaded : lightFloatingLoaded
        }
        return isDeferred ? lightUnloaded : lightLoaded
    }
}

extension BrowserSettings {
    /// While a slider or colour well drags, the window takes a new preview at most this often. The gallery card
    /// reads `themePreview` itself and stays live.
    static let themePreviewInterval = Duration.milliseconds(100)

    func refreshTheme() {
        pendingThemeApply?.cancel()
        pendingThemeApply = nil
        appliedThemePreview = themePreview
        themeRevision &+= 1
        themeCache = nil
        let theme = resolvedTheme
        let ink = ThemeSidebarInk(theme)
        if sidebarInk != ink {
            sidebarInk = ink
        }
        let shape = ThemeShape(theme.adjustment)
        if chromeShape != shape {
            chromeShape = shape
        }
    }

    func beginThemePreview() {
        let settings = globalSettings
        guard settings.themePreview == nil else { return }
        settings.themePreview = ThemePreview(themeID: selectedTheme.id, adjustment: themeAdjustment)
    }

    /// No JSON encoding or defaults write until the drag ends. Keyboard and accessibility changes can persist
    /// directly, since they do not begin a drag.
    func previewThemeAdjustment(_ adjustment: ThemeAdjustment) {
        let settings = globalSettings
        var preview = settings.themePreview ?? ThemePreview(themeID: selectedTheme.id, adjustment: themeAdjustment)
        preview.adjustment = adjustment.bounded()
        guard settings.themePreview != preview else { return }
        settings.themePreview = preview
        settings.applyThemePreviewSoon()
    }

    /// Applies the preview to the window now if the last apply is at least `themePreviewInterval` old; otherwise
    /// once the interval is up, with whatever the preview is by then. The last value of a drag always lands.
    func applyThemePreviewSoon() {
        let settings = globalSettings
        let now = settings.themeApplyClock()
        guard let last = settings.lastThemeApply, now - last < Self.themePreviewInterval else {
            settings.lastThemeApply = now
            settings.refreshTheme()
            return
        }
        guard settings.pendingThemeApply == nil else { return }
        let wait = Self.themePreviewInterval - (now - last)
        settings.pendingThemeApply = Task { @MainActor [weak settings] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let settings else { return }
            settings.pendingThemeApply = nil
            settings.lastThemeApply = settings.themeApplyClock()
            settings.refreshTheme()
        }
    }

    var previewedTheme: ThemeDefinition {
        let theme = selectedTheme
        return globalSettings.themePreview?.applying(to: theme) ?? theme
    }

    /// The variant as the controls show it right now: the live preview, not the one the window applied at most every
    /// `themePreviewInterval`. A readability note compares the chosen ink with this, so it never disagrees with its own slider.
    func liveResolvedVariant(_ scheme: ColorScheme) -> ResolvedVariant {
        let theme = previewedTheme
        return ResolvedVariant(
            theme.variant(scheme), isDark: scheme == .dark,
            brightness: themeAdjustment.brightness(scheme), ground: theme.drawnGround
        )
    }

    /// What the window backdrop draws from: the ground, the material and the glass opacity of the applied theme. All
    /// three come from `resolvedTheme`, so a drag moves them at most every `themePreviewInterval`.
    var windowBackdrop: (ground: ThemeGround, material: ThemeMaterial, glassOpacity: Double) {
        let theme = resolvedTheme
        return (theme.ground, theme.adjustment.material, theme.adjustment.glassOpacity)
    }

    func previewThemeColors(scheme: ColorScheme, _ edit: (inout ThemeVariant) -> Void) {
        guard !ThemeCatalog.isBuiltIn(selectedTheme.id) || userThemes.count < Self.userThemeLimit else { return }
        beginThemePreview()
        guard var preview = globalSettings.themePreview else { return }
        var colors = previewedTheme.variant(scheme)
        edit(&colors)
        preview.colors = colors
        preview.scheme = scheme
        guard globalSettings.themePreview != preview else { return }
        globalSettings.themePreview = preview
        applyThemePreviewSoon()
    }

    func commitThemePreview() {
        let settings = globalSettings
        guard let preview = settings.themePreview else { return }
        settings.themePreview = nil
        settings.lastThemeApply = nil
        if preview.themeID == selectedTheme.id {
            if let colors = preview.colors, let scheme = preview.scheme, colors != selectedTheme.variant(scheme) {
                editColors(scheme: scheme) { $0 = colors }
            }
            themeAdjustment = preview.adjustment
        }
        settings.refreshTheme()
    }

    func cancelThemePreview() {
        let settings = globalSettings
        guard settings.themePreview != nil else { return }
        settings.themePreview = nil
        settings.lastThemeApply = nil
        settings.refreshTheme()
    }
}
