// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// Today's resolved chrome colors for every appearance, preset and saved customization, recorded from the code
/// that existed before themes gained light and dark variants. The migration to themes has to reproduce each cell:
/// a person who upgrades sees the same colors, and a cell that changes is a color that was lost.
@MainActor
struct ThemeGoldenTests {
    /// The legacy settings of one install, as the old keys stored them.
    struct Scenario {
        let name: String
        var mode = "system"
        var preset: String?
        var customizations: [String: ThemeCustomization] = [:]
        var textStyles: [String: SidebarTextStyle] = [:]
    }

    static let scenarios: [Scenario] = {
        var result = ["system", "light", "dark", "lightCalm", "darkCalm"].map {
            Scenario(name: "mode-\($0)", mode: $0)
        }
        let presets: [String] = [
            "catppuccinLatte", "catppuccinMocha", "nord", "dracula", "gruvboxLight", "gruvboxDark", "rosePine",
            "rosePineDawn",
        ]
        result += presets.map { Scenario(name: "preset-\($0)", preset: $0) }
        result += [
            Scenario(name: "brightness-only", customizations: [
                "light": ThemeCustomization(brightness: 0.2),
                "dark": ThemeCustomization(brightness: -0.15),
            ]),
            Scenario(name: "palette-and-inks", customizations: [
                "light": ThemeCustomization(
                    hue: 0.1, primary: SidebarTextStyle(colorRGB: 0xCC3300),
                    controls: SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.4),
                    url: SidebarTextStyle(colorRGB: 0x33CC00, opacity: 0.7)
                ),
                "dark": ThemeCustomization(
                    primary: SidebarTextStyle(colorRGB: 0x3366FF),
                    controls: SidebarTextStyle(colorRGB: 0xFFAA00, opacity: 0.6),
                    url: SidebarTextStyle(colorRGB: 0x88DDFF, opacity: 0.8)
                ),
            ]),
            Scenario(name: "sidebar-text-styles", textStyles: [
                "light.loaded": SidebarTextStyle(colorRGB: 0xCC3300, opacity: 0.8),
                "light.unloaded": SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.3),
                "dark.loaded": SidebarTextStyle(colorRGB: 0x99FF99, opacity: 0.9),
                "dark.unloaded": SidebarTextStyle(colorRGB: 0xFFCC00, opacity: 0.5),
            ]),
            Scenario(name: "calm-customized", mode: "lightCalm", customizations: [
                "lightCalm": ThemeCustomization(
                    brightness: -0.1, primary: SidebarTextStyle(colorRGB: 0x884488),
                    controls: SidebarTextStyle(colorRGB: 0x224422, opacity: 0.9)
                ),
                "darkCalm": ThemeCustomization(hue: -0.2),
            ], textStyles: [
                "lightCalm.loaded": SidebarTextStyle(colorRGB: 0x553355, opacity: 0.95),
                "darkCalm.unloaded": SidebarTextStyle(colorRGB: 0xDDBBFF, opacity: 0.4),
            ]),
            Scenario(name: "mode-light-customized-both", mode: "light", customizations: [
                "light": ThemeCustomization(brightness: 0.1, url: SidebarTextStyle(colorRGB: 0x006600)),
                "dark": ThemeCustomization(brightness: -0.3),
            ]),
            Scenario(name: "preset-over-customizations", mode: "darkCalm", preset: "nord", customizations: [
                "darkCalm": ThemeCustomization(brightness: 0.2, primary: SidebarTextStyle(colorRGB: 0xFF0000)),
                "dark": ThemeCustomization(hue: 0.3),
            ], textStyles: ["darkCalm.loaded": SidebarTextStyle(colorRGB: 0xFF00FF, opacity: 0.5)]),
        ]
        return result
    }()

    private static let page = NSColor(srgbRed: 0, green: 0.35, blue: 1, alpha: 1)
    static let cellNames = [
        "window", "sidebar", "surface", "accent", "systemAccent", "control", "url", "loaded", "unloaded",
        "ambient", "floating", "page", "pageFloating",
    ]

    // MARK: - Installing a scenario

    /// Puts `scenario` on the application settings. This is the one place that knows how the settings are stored.
    private func install(_ scenario: Scenario) throws {
        let settings = BrowserSettings.application
        settings.forcesDarkAppearance = false
        settings.appearance = try #require(AppearanceMode(rawValue: scenario.mode))
        settings.themePreset = scenario.preset.flatMap(ThemePreset.init(rawValue:))
        settings.themeCustomizations = scenario.customizations
        settings.sidebarTextStyles = scenario.textStyles
    }

    private struct Snapshot {
        let mode: AppearanceMode
        let preset: ThemePreset?
        let customizations: [String: ThemeCustomization]
        let textStyles: [String: SidebarTextStyle]
        let forcesDark: Bool
        let native: NSAppearance?
    }

    private func snapshot() -> Snapshot {
        let settings = BrowserSettings.application
        return Snapshot(
            mode: settings.appearance, preset: settings.themePreset, customizations: settings.themeCustomizations,
            textStyles: settings.sidebarTextStyles, forcesDark: settings.forcesDarkAppearance, native: NSApp.appearance
        )
    }

    private func restore(_ saved: Snapshot) {
        let settings = BrowserSettings.application
        settings.themePreset = saved.preset
        settings.themeCustomizations = saved.customizations
        settings.sidebarTextStyles = saved.textStyles
        settings.appearance = saved.mode
        settings.forcesDarkAppearance = saved.forcesDark
        NSApp.appearance = saved.native
    }

    // MARK: - Measuring

    private func cell(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return "-" }
        func channel(_ value: CGFloat) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return channel(rgb.redComponent) + channel(rgb.greenComponent) + channel(rgb.blueComponent)
            + channel(rgb.alphaComponent)
    }

    /// A dynamic color resolves when it is converted, so the conversion happens in the appearance too.
    private func cell(_ color: Color?, in appearance: NSAppearance) -> String {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.flatMap { NSColor($0).usingColorSpace(.sRGB) }
        }
        return cell(resolved)
    }

    /// Every cell of one appearance, in `cellNames` order, read from the same calls the chrome makes.
    private func measure(_ appearance: NSAppearance, scheme: ColorScheme) -> [String] {
        let settings = BrowserSettings.application
        NSApp.appearance = appearance
        return [
            cell(Theme.windowBackground, in: appearance),
            cell(Theme.sidebarTint, in: appearance),
            cell(Theme.controlSurface, in: appearance),
            cell(Theme.accent, in: appearance),
            cell(Theme.systemAccent, in: appearance),
            cell(Theme.controlOverride, in: appearance),
            cell(Theme.urlOverride, in: appearance),
            cell(settings.sidebarTextColor(scheme: scheme), in: appearance),
            cell(settings.sidebarTextColor(isDeferred: true, scheme: scheme), in: appearance),
            cell(LoomChrome.sampledColor(nil, scheme: scheme)),
            cell(LoomChrome.sampledColor(nil, scheme: scheme, isFloating: true)),
            cell(LoomChrome.sampledColor(Self.page, scheme: scheme)),
            cell(LoomChrome.sampledColor(Self.page, scheme: scheme, isFloating: true)),
        ]
    }

    private static let appearances: [(name: String, appearance: NSAppearance.Name, scheme: ColorScheme)] = [
        ("aqua", .aqua, .light), ("darkAqua", .darkAqua, .dark),
    ]

    // MARK: - Verifying

    /// A cell is `RRGGBBAA`, `-` for no color, `~` for a color that follows the live system accent (not recorded),
    /// or `=blue` for the plain system blue.
    private func matches(_ expected: String, _ measured: String, appearance: NSAppearance) -> Bool {
        switch expected {
        case "~":
            return true
        case "=blue":
            return Self.agree(cell(Color.blue, in: appearance), measured)
        default:
            return Self.agree(expected, measured)
        }
    }

    /// Equal, or within 1/255 per channel: the Calm colors are stored as 8-bit values.
    private static func agree(_ first: String, _ second: String) -> Bool {
        guard first.count == 8, second.count == 8,
              let one = UInt32(first, radix: 16), let two = UInt32(second, radix: 16)
        else { return first == second }
        return (0..<4).allSatisfy { shift in
            abs(Int((one >> (shift * 8)) & 255) - Int((two >> (shift * 8)) & 255)) <= 1
        }
    }

    @Test func everyRecordedColorSurvivesTheMigration() throws {
        let saved = snapshot()
        defer { restore(saved) }
        var installed: String?
        var checked = 0
        for line in Self.table.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let scenario = try #require(Self.scenarios.first { $0.name == parts[0] }, "\(parts[0])")
            let row = try #require(Self.appearances.first { $0.name == parts[1] })
            if installed != scenario.name {
                try install(scenario)
                installed = scenario.name
            }
            let appearance = try #require(NSAppearance(named: row.appearance))
            let measured = measure(appearance, scheme: row.scheme)
            let expected = parts[2].split(separator: " ").map(String.init)
            #expect(expected.count == Self.cellNames.count && measured.count == expected.count)
            for (name, pair) in zip(Self.cellNames, zip(expected, measured)) {
                #expect(
                    matches(pair.0, pair.1, appearance: appearance),
                    "\(scenario.name) in \(row.name): \(name) was \(pair.0), is \(pair.1)"
                )
                checked += 1
            }
        }
        #expect(checked == Self.scenarios.count * Self.appearances.count * Self.cellNames.count)
    }

    // MARK: - The recorded colors

    /// Scenario, appearance and the cells in `cellNames` order, from the code before themes had variants.
    static let table = """
mode-system|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ - - 000000FF 0000008C F0F0F4FF F0F0F4FF 5578BBFF 5578BBFF
mode-system|darkAqua|17171CFF 0D0D11FF 575757FF =blue ~ - - FFFFFFFF FFFFFF8C 1B1B20FF 1B1B20FF 5578BBFF 5578BBFF
mode-light|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ - - 000000FF 0000008C F0F0F4FF F0F0F4FF 5578BBFF 5578BBFF
mode-light|darkAqua|17171CFF 0D0D11FF 575757FF =blue ~ - - FFFFFFFF FFFFFF8C 1B1B20FF 1B1B20FF 5578BBFF 5578BBFF
mode-dark|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ - - 000000FF 0000008C F0F0F4FF F0F0F4FF 5578BBFF 5578BBFF
mode-dark|darkAqua|17171CFF 0D0D11FF 575757FF =blue ~ - - FFFFFFFF FFFFFF8C 1B1B20FF 1B1B20FF 5578BBFF 5578BBFF
mode-lightCalm|aqua|DBCCC9FF C7B3BDFF E8D9D9FF AD638AFF AD638AFF - - 000000FF 0000008C DBCCC9FF DBCCC9FF CAC5D3FF CAC5D3FF
mode-lightCalm|darkAqua|201D2EFF 181624FF 3B334AFF D1A1C2FF D1A1C2FF - - FFFFFFFF FFFFFF8C 201D2EFF 201D2EFF 2D3451FF 2D3451FF
mode-darkCalm|aqua|DBCCC9FF C7B3BDFF E8D9D9FF AD638AFF AD638AFF - - 000000FF 0000008C DBCCC9FF DBCCC9FF CAC5D3FF CAC5D3FF
mode-darkCalm|darkAqua|201D2EFF 181624FF 3B334AFF D1A1C2FF D1A1C2FF - - FFFFFFFF FFFFFF8C 201D2EFF 201D2EFF 2D3451FF 2D3451FF
preset-catppuccinLatte|aqua|EFF1F5FF E6E9EFFF CCD0DAFF 8839EFFF 8839EFFF 4C4F69FF 4C4F69FF 4C4F69FF 4C4F69E0 EFF1F5FF E6E9EFFF EFF1F5FF E6E9EFFF
preset-catppuccinLatte|darkAqua|17171CFF 0D0D11FF 575757FF =blue ~ FFFFFFD8 FFFFFFD8 FFFFFFFF FFFFFF8C 17171CFF 0D0D11FF 17171CFF 0D0D11FF
preset-catppuccinMocha|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ 000000D8 000000D8 000000FF 0000008C FAFAFCFF E8E8EDFF FAFAFCFF E8E8EDFF
preset-catppuccinMocha|darkAqua|1E1E2EFF 181825FF 313244FF CBA6F7FF CBA6F7FF CDD6F4FF CDD6F4FF CDD6F4FF CDD6F4A6 1E1E2EFF 181825FF 1E1E2EFF 181825FF
preset-nord|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ 000000D8 000000D8 000000FF 0000008C FAFAFCFF E8E8EDFF FAFAFCFF E8E8EDFF
preset-nord|darkAqua|3B4252FF 2E3440FF 434C5EFF 88C0D0FF 88C0D0FF D8DEE9FF D8DEE9FF D8DEE9FF D8DEE9A6 3B4252FF 2E3440FF 3B4252FF 2E3440FF
preset-dracula|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ 000000D8 000000D8 000000FF 0000008C FAFAFCFF E8E8EDFF FAFAFCFF E8E8EDFF
preset-dracula|darkAqua|282A36FF 282A36FF 44475AFF BD93F9FF BD93F9FF F8F8F2FF F8F8F2FF F8F8F2FF F8F8F2A6 282A36FF 282A36FF 282A36FF 282A36FF
preset-gruvboxLight|aqua|FBF1C7FF F2E5BCFF EBDBB2FF 076678FF 076678FF 3C3836FF 3C3836FF 3C3836FF 3C3836E0 FBF1C7FF F2E5BCFF FBF1C7FF F2E5BCFF
preset-gruvboxLight|darkAqua|17171CFF 0D0D11FF 575757FF =blue ~ FFFFFFD8 FFFFFFD8 FFFFFFFF FFFFFF8C 17171CFF 0D0D11FF 17171CFF 0D0D11FF
preset-gruvboxDark|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ 000000D8 000000D8 000000FF 0000008C FAFAFCFF E8E8EDFF FAFAFCFF E8E8EDFF
preset-gruvboxDark|darkAqua|282828FF 1D2021FF 3C3836FF 83A598FF 83A598FF EBDBB2FF EBDBB2FF EBDBB2FF EBDBB2A6 282828FF 1D2021FF 282828FF 1D2021FF
preset-rosePine|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ 000000D8 000000D8 000000FF 0000008C FAFAFCFF E8E8EDFF FAFAFCFF E8E8EDFF
preset-rosePine|darkAqua|1F1D2EFF 191724FF 26233AFF C4A7E7FF C4A7E7FF E0DEF4FF E0DEF4FF E0DEF4FF E0DEF4A6 1F1D2EFF 191724FF 1F1D2EFF 191724FF
preset-rosePineDawn|aqua|FAF4EDFF F2E9E1FF FFFAF3FF 286983FF 286983FF 575279FF 575279FF 575279FF 575279E0 FAF4EDFF F2E9E1FF FAF4EDFF F2E9E1FF
preset-rosePineDawn|darkAqua|17171CFF 0D0D11FF 575757FF =blue ~ FFFFFFD8 FFFFFFD8 FFFFFFFF FFFFFF8C 17171CFF 0D0D11FF 17171CFF 0D0D11FF
brightness-only|aqua|FCFCFFFF FAFAFFFF FFFFFFFF ~ ~ - - 000000FF 0000008C FCFCFFFF FCFCFFFF FCFCFFFF FCFCFFFF
brightness-only|darkAqua|000000FF 000000FF 303030FF ~ ~ - - FFFFFFFF FFFFFF8C 000000FF 000000FF 000000FF 000000FF
palette-and-inks|aqua|FCEFA4FF EDE19AFF FFF2A6FF CCAD00FF CCAD00FF 0033CC66 33CC00B3 000000FF 0000008C FCEFA4FF FCEFA4FF FCEFA4FF FCEFA4FF
palette-and-inks|darkAqua|12151CFF 0B0C11FF 384057FF 3366FFFF 3366FFFF FFAA0099 88DDFFCC FFFFFFFF FFFFFF8C 12151CFF 12151CFF 12151CFF 12151CFF
sidebar-text-styles|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ - - CC3300CC 0033CC4D F0F0F4FF F0F0F4FF 5578BBFF 5578BBFF
sidebar-text-styles|darkAqua|17171CFF 0D0D11FF 575757FF =blue ~ - - 99FF99E6 FFCC0080 1B1B20FF 1B1B20FF 5578BBFF 5578BBFF
calm-customized|aqua|C27EC2FF AD71ADFF CF86CFFF 6F376FFF 6F376FFF 224422E6 - 553355F2 0000008C C27EC2FF C27EC2FF C27EC2FF C27EC2FF
calm-customized|darkAqua|140D14FF 0A070AFF 301F30FF 6F376FFF 6F376FFF 224422E6 - 553355F2 FFFFFF8C 140D14FF 140D14FF 140D14FF 140D14FF
mode-light-customized-both|aqua|FCFCFFFF FAFAFFFF FFFFFFFF ~ ~ - 006600FF 000000FF 0000008C FCFCFFFF FCFCFFFF FCFCFFFF FCFCFFFF
mode-light-customized-both|darkAqua|2C2C36FF 20202AFF 707070FF ~ ~ - 006600FF FFFFFFFF FFFFFF8C 2C2C36FF 2C2C36FF 2C2C36FF 2C2C36FF
preset-over-customizations|aqua|FAFAFCFF E8E8EDFF FFFFFFFF =blue ~ 000000D8 000000D8 000000FF 0000008C FAFAFCFF E8E8EDFF FAFAFCFF E8E8EDFF
preset-over-customizations|darkAqua|3B4252FF 2E3440FF 434C5EFF 88C0D0FF 88C0D0FF D8DEE9FF D8DEE9FF D8DEE9FF D8DEE9A6 3B4252FF 2E3440FF 3B4252FF 2E3440FF
"""
}
