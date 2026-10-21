// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AppearanceThemeSection: View {
    @Bindable var settings: BrowserSettings
    let scheme: ColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isEditing = false
    @State private var naming: ThemeNaming?
    @State private var deleting: ThemeDefinition?

    private var themes: [ThemeDefinition] {
        let selected = settings.previewedTheme
        return settings.allThemes.map { $0.id == selected.id ? selected : $0 }
    }

    private var adjustments: [String: ThemeAdjustment] {
        var values = settings.themeAdjustments
        values[settings.selectedTheme.id] = settings.themeAdjustment
        return values
    }

    private var materialCaption: LocalizedStringResource {
        GlassPolicy.fallsBack(reduceTransparency: reduceTransparency, contrast: contrast)
            ? "Reduce transparency or increase contrast is on in System Settings, so WSurf uses Plain."
            : "Glass shows your desktop through the window. It uses more GPU."
    }

    private var selectedThemeIsSaved: Bool {
        !ThemeCatalog.isBuiltIn(settings.selectedTheme.id)
    }

    private var saveCaption: LocalizedStringResource {
        settings.canSaveAnotherTheme
            ? "Keeps this theme’s colors, material, transparency, brightness and layout under a name you choose."
            : "You have saved \(BrowserSettings.userThemeLimit) themes, the most WSurf keeps. Delete one to save another."
    }

    private var deleteTitle: Text {
        Text("Delete “\(deleting?.name ?? "")”?")
    }

    private var confirmsDeletion: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    var body: some View {
        SettingsSection(title: "Theme", symbol: "paintpalette") {
            DetailRow(title: "Appearance") {
                SegmentedControl(
                    items: AppearanceMode.allCases.map { .init(value: $0, label: $0.label) },
                    selection: settings.colorMode,
                    onSelect: { settings.colorMode = $0 }
                )
            }
            .settingsAnchor("appearance.mode")
            RowSeparator()
            DetailRow(title: "Theme", layout: .stacked) {
                ThemeGallery(
                    themes: themes, selection: settings.selectedTheme.id,
                    mode: settings.colorMode, adjustments: adjustments,
                    onSelect: { settings.themeID = $0 },
                    canDuplicate: settings.canSaveAnotherTheme,
                    onDuplicate: { settings.duplicateTheme($0.id) },
                    onRename: { naming = .rename($0) },
                    onDelete: { deleting = $0 }
                )
            }
            .settingsAnchor("appearance.theme")
            RowSeparator()
            DetailRow(title: "Material", caption: materialCaption) {
                SegmentedControl(
                    items: [
                        .init(value: ThemeMaterial.plain, label: "Plain"),
                        .init(value: ThemeMaterial.glass, label: "Glass"),
                    ],
                    selection: settings.themeMaterial,
                    onSelect: { settings.themeMaterial = $0 }
                )
            }
            .settingsAnchor("appearance.material")
            if settings.themeMaterial == .glass {
                RowSeparator()
                DetailRow(title: "Transparency", layout: .stacked) {
                    LoomTransparencyControl(
                        opacity: adjustmentBinding(\.glassOpacity), onEditingChanged: editingChanged
                    )
                }
                .settingsAnchor("appearance.transparency")
            }
            RowSeparator()
            DetailRow(
                title: "Brightness",
                caption: scheme == .dark
                    ? "Makes this theme’s dark colors darker or lighter."
                    : "Makes this theme’s light colors darker or lighter."
            ) {
                HStack(spacing: 8) {
                    Slider(value: brightness, in: ThemeAdjustment.brightnessRange, onEditingChanged: editingChanged)
                        .frame(width: 140)
                        .accessibilityLabel("Theme brightness")
                        .accessibilityValue(Text(brightness.wrappedValue, format: .percent))
                    Text(brightness.wrappedValue, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            .settingsAnchor("appearance.brightness")
            RowSeparator()
            DetailRow(
                title: "Website tint",
                caption: "Use the current website’s color in the toolbar and sidebar. Off while a theme’s colors or brightness are changed."
            ) {
                SettingsToggle($settings.matchesWebsiteColor)
            }
            .settingsAnchor("appearance.websiteTint")
            RowSeparator()
            DetailRow(title: "Tint selected tab", caption: "Color tabs you select together using the website icon.") {
                SettingsToggle($settings.refractsTabColor)
            }
            .settingsAnchor("appearance.refraction")
            RowSeparator()
            DetailRow(title: "Save as Theme", caption: saveCaption) {
                SettingsButton(title: "Save as Theme…") {
                    settings.commitThemePreview()
                    naming = .save(name: String(localized: "\(settings.selectedTheme.name) copy"))
                }
                .disabled(!settings.canSaveAnotherTheme)
            }
            .settingsAnchor("appearance.savedThemes")
            if selectedThemeIsSaved {
                RowSeparator()
                DetailRow(title: "This theme", controlWidth: nil) {
                    HStack(spacing: 8) {
                        SettingsButton(title: "Rename…") { naming = .rename(settings.selectedTheme) }
                        SettingsButton(title: "Duplicate") { settings.duplicateTheme(settings.selectedTheme.id) }
                            .disabled(!settings.canSaveAnotherTheme)
                        SettingsButton(title: "Delete…", isDestructive: true) { deleting = settings.selectedTheme }
                    }
                }
                .settingsAnchor("appearance.manageTheme")
            }
        }
        .onDisappear { settings.commitThemePreview() }
        .onChange(of: scheme) { _, _ in
            settings.commitThemePreview()
            isEditing = false
        }
        .sheet(item: $naming) { request in
            ThemeNameSheet(naming: request) { name in
                switch request {
                case .save:
                    _ = settings.saveTheme(named: name)
                case .rename(let theme):
                    _ = settings.renameTheme(theme.id, to: name)
                }
            }
        }
        .confirmationDialog(
            deleteTitle, isPresented: confirmsDeletion, titleVisibility: .visible, presenting: deleting
        ) { theme in
            Button("Delete Theme", role: .destructive) { settings.deleteTheme(theme.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can’t undo this.")
        }
    }

    private var brightness: Binding<Double> {
        Binding(
            get: { settings.themeAdjustment.brightness(scheme) },
            set: { value in
                var adjustment = settings.themeAdjustment
                adjustment.setBrightness(value, for: scheme)
                store(adjustment)
            }
        )
    }

    private func adjustmentBinding(_ keyPath: WritableKeyPath<ThemeAdjustment, Double>) -> Binding<Double> {
        Binding(
            get: { settings.themeAdjustment[keyPath: keyPath] },
            set: { value in
                var adjustment = settings.themeAdjustment
                adjustment[keyPath: keyPath] = value
                store(adjustment)
            }
        )
    }

    private func store(_ adjustment: ThemeAdjustment) {
        if isEditing {
            settings.previewThemeAdjustment(adjustment)
        } else {
            settings.themeAdjustment = adjustment
        }
    }

    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        if editing {
            settings.beginThemePreview()
        } else {
            settings.commitThemePreview()
        }
    }
}
