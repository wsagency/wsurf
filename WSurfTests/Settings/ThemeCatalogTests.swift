// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

struct ThemeCatalogTests {
    @Test func builtInThemesHaveDistinctIdsAndTheDefaultIsOneOfThem() {
        let ids = ThemeCatalog.builtIn.map(\.id)

        #expect(Set(ids).count == ids.count)
        #expect(ids == ["wsurf", "standard", "calm", "catppuccin", "gruvbox", "rosePine", "nord", "dracula"])
        #expect(ThemeCatalog.isBuiltIn(ThemeCatalog.defaultID))
        #expect(ThemeCatalog.fallback.id == ThemeCatalog.defaultID)
        #expect(ThemeCatalog.builtIn("nothing") == nil)
    }

    @Test func standardAndCalmKeepTheMaterialsTheyAlwaysDrew() throws {
        let standard = try #require(ThemeCatalog.builtIn("standard"))
        let calm = try #require(ThemeCatalog.builtIn("calm"))

        #expect(standard.ground == .pageTinted && standard.light == ThemeVariant() && standard.dark == ThemeVariant())
        #expect(calm.ground == .softTinted)
        #expect([calm.light, calm.dark].allSatisfy { $0.window != nil && $0.accent != nil && $0.text == nil })
        #expect(ThemeCatalog.builtIn.filter { $0.ground == .solid }.count == 6)
    }

    /// A solid theme replaces the whole chrome palette, so every text and accent color it ships has to stay
    /// legible on the surfaces it is drawn on, in both of its variants.
    @Test func everyBuiltInVariantKeepsItsTextAndAccentLegible() throws {
        func luminance(_ rgb: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let value = Double((rgb >> shift) & 255) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        func contrast(_ first: UInt32, _ second: UInt32) -> Double {
            let (one, two) = (luminance(first), luminance(second))
            return (max(one, two) + 0.05) / (min(one, two) + 0.05)
        }
        var checked = 0
        for theme in ThemeCatalog.builtIn where theme.ground == .solid {
            for (name, variant) in [("light", theme.light), ("dark", theme.dark)] {
                let window = try #require(variant.window)
                let sidebar = try #require(variant.sidebar)
                let surface = try #require(variant.surface)
                let text = try #require(variant.text)
                let accent = try #require(variant.accent)
                for ground in [window, sidebar, surface] {
                    #expect(contrast(text, ground) >= 4.5, "\(theme.id) \(name) text")
                }
                for ground in [window, sidebar] {
                    #expect(contrast(accent, ground) >= 3, "\(theme.id) \(name) accent")
                }
                // Unloaded sidebar text is the text at reduced opacity over the sidebar.
                let alpha = variant.unloadedText.opacity
                let blended = [16, 8, 0].reduce(UInt32(0)) { result, shift in
                    let ink = Double((text >> shift) & 255)
                    let ground = Double((sidebar >> shift) & 255)
                    return result | UInt32((alpha * ink + (1 - alpha) * ground).rounded()) << shift
                }
                #expect(contrast(blended, sidebar) >= 4.5, "\(theme.id) \(name) unloaded text")
                checked += 1
            }
        }
        #expect(checked == 12, "six solid themes in two appearances")
    }

    @Test func aVariantDecodesWhateverItsFileHolds() throws {
        let json = #"""
        {"id": "keep", "name": "Kept", "ground": "solid", "light": {"window": 16777215, "hue": "loud"},
         "dark": {"accent": 255, "extra": true, "unloadedText": {"opacity": 0.3}}, "futureField": 1}
        """#
        let theme = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))

        #expect(theme.light.window == 0xFFFFFF && theme.light.hue == 0)
        #expect(theme.dark.accent == 0xFF && theme.dark.unloadedText == SidebarTextStyle(opacity: 0.3))
        #expect(theme.dark.sidebarText == SidebarTextStyle(), "a missing field takes its default")
        #expect(theme.basedOn == nil)

        let odd = try JSONDecoder().decode(ThemeDefinition.self, from: Data(#"{"id":"odd","ground":"holographic"}"#.utf8))
        #expect(odd.ground == .pageTinted && odd.name.isEmpty)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ThemeDefinition.self, from: Data(#"{"name":"no id"}"#.utf8))
        }
    }

    @Test func aThemeSurvivesAnEncodeAndDecode() throws {
        let theme = ThemeDefinition(
            id: "copy", name: "Mine", basedOn: "nord", ground: .solid,
            light: ThemeVariant(window: 0x112233, text: 0x445566, primary: 0xCC3300, hue: 0.2,
                                icons: SidebarTextStyle(colorRGB: 0x0033CC, opacity: 0.4)),
            dark: ThemeVariant(assistant: 0x2FE0B2, unloadedText: SidebarTextStyle(opacity: 0.8))
        )
        let adjustment = ThemeAdjustment(
            material: .glass, glassOpacity: 0.7, lightBrightness: 0.1, darkBrightness: -0.2,
            pageFrame: .hairline, rowFrame: FrameStyle.none, cornerScale: 0.5, loadedFavicons: .color
        )

        let themeBack = try JSONDecoder().decode(ThemeDefinition.self, from: JSONEncoder().encode(theme))
        let adjustmentBack = try JSONDecoder().decode(ThemeAdjustment.self, from: JSONEncoder().encode(adjustment))

        #expect(themeBack == theme)
        #expect(adjustmentBack == adjustment)
    }

    @Test func boundedKeepsEveryColorAndKnobInRange() {
        let variant = ThemeVariant(
            window: 0x1_000_000, sidebar: 0xFFFF_FFFF, accent: 0xABCDEF, hue: .infinity,
            sidebarText: SidebarTextStyle(colorRGB: 0xFFFF_FFFF, opacity: -3),
            unloadedText: SidebarTextStyle(opacity: .nan)
        ).bounded()
        let adjustment = ThemeAdjustment(
            glassOpacity: 7, lightBrightness: .nan, darkBrightness: -9, cornerScale: 9
        ).bounded()

        #expect(variant.window == nil && variant.sidebar == nil && variant.accent == 0xABCDEF)
        #expect(variant.hue == 0)
        #expect(variant.sidebarText == SidebarTextStyle(opacity: 0))
        #expect(variant.unloadedText.opacity == ThemeVariant.unloadedOpacity)
        #expect(adjustment.glassOpacity == 1 && adjustment.lightBrightness == 0 && adjustment.darkBrightness == -1)
        #expect(adjustment.cornerScale == 1.5)

        let theme = ThemeDefinition(id: "x", name: "  " + String(repeating: "n", count: 90) + "  ", ground: .solid).bounded()
        #expect(theme.name.count == ThemeDefinition.nameLimit)
    }
}
