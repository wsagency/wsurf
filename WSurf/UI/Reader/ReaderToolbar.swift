// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

/// The floating controls over the article: its text appearance and the way out. It takes the colors of the article's page, not of
/// the window, so it stays readable on a dark page in a light window and the other way round.
struct ReaderToolbar: View {
    let tab: BrowserTab
    let palette: ReaderAppearance.Palette

    @State private var showsAppearance = false
    @Environment(\.colorScheme) private var windowScheme

    private var scheme: ColorScheme {
        palette == .dark ? .dark : .light
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                showsAppearance.toggle()
            } label: {
                Image(systemName: "textformat.size")
                    .font(Theme.Font.control)
            }
            .help("Text appearance")
            .popover(isPresented: $showsAppearance, arrowEdge: .bottom) {
                // The popover is a window of its own and keeps the window's appearance.
                ReaderAppearancePopover()
                    .environment(\.colorScheme, windowScheme)
            }

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 4)

            Button("Done") { tab.reader.close() }
                .font(Theme.Font.body)
                .help("Hide Reader (⌥⌘R)")
        }
        .buttonStyle(ReaderToolbarButtonStyle())
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
        .frame(height: 36)
        .glassSurface(in: shape)
        .environment(\.colorScheme, scheme)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

private struct ReaderToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ReaderToolbarButton(configuration: configuration)
    }
}

private struct ReaderToolbarButton: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var fill: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed {
            return Theme.Wash.strong
        }
        return hovering ? Theme.Wash.hover : .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.tight + 2, style: .continuous)
        configuration.label
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 28)
            .background(fill, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
    }
}

private struct ReaderAppearancePopover: View {
    private var settings: BrowserSettings {
        BrowserSettings.application
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                sizeButton(glyphSize: 10, help: "Make text smaller", enabled: settings.readerTextSize > ReaderAppearance.textSizeRange.lowerBound) {
                    settings.readerTextSize = ReaderAppearance.smaller(than: settings.readerTextSize)
                }
                sizeButton(glyphSize: 20, help: "Make text bigger", enabled: settings.readerTextSize < ReaderAppearance.textSizeRange.upperBound) {
                    settings.readerTextSize = ReaderAppearance.larger(than: settings.readerTextSize)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Theme")
                HStack(spacing: 12) {
                    ForEach(ReaderAppearance.Palette.allCases) { palette in
                        PaletteSwatch(palette: palette, isSelected: settings.readerPalette == palette) {
                            settings.readerPalette = palette
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Font")
                VStack(spacing: 0) {
                    ForEach(ReaderAppearance.Typeface.allCases) { typeface in
                        fontRow(typeface)
                    }
                }
                .padding(.horizontal, -8)
            }

            Divider()

            Button {
                settings.resetReaderAppearance()
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, -8)
            .disabled(settings.isReaderAppearanceDefault)
        }
        .buttonStyle(ReaderToolbarButtonStyle())
        .foregroundStyle(.primary)
        .padding(16)
        .frame(width: 220)
    }

    private func sectionTitle(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func sizeButton(
        glyphSize: CGFloat,
        help: LocalizedStringResource,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(verbatim: "A")
                .font(.system(size: glyphSize, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
        }
        .background(Theme.Wash.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.tight + 2, style: .continuous))
        .disabled(!enabled)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }

    private func fontRow(_ typeface: ReaderAppearance.Typeface) -> some View {
        checkRow(isSelected: settings.readerTypeface == typeface) {
            settings.readerTypeface = typeface
        } label: {
            Text(verbatim: typeface.name)
                .font(typeface.font(size: 15))
        }
    }

    private func checkRow<Label: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                label()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PaletteSwatch: View {
    let palette: ReaderAppearance.Palette
    let isSelected: Bool
    let action: () -> Void

    private static let side: CGFloat = 36

    private var fill: AnyShapeStyle {
        guard palette == .automatic else {
            return AnyShapeStyle(Color(nsColor: palette.background))
        }
        let light = Color(nsColor: ReaderAppearance.Palette.light.background)
        let dark = Color(nsColor: ReaderAppearance.Palette.dark.background)
        return AnyShapeStyle(LinearGradient(
            stops: [.init(color: light, location: 0.5), .init(color: dark, location: 0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }

    private var checkColor: Color {
        palette == .dark ? .white : .black
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                Circle()
                    .strokeBorder(isSelected ? Theme.systemAccent : Theme.chrome(0.2), lineWidth: isSelected ? 2 : 0.5)
                if isSelected, palette != .automatic {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(checkColor)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(palette.title))
        .accessibilityLabel(Text(palette.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
