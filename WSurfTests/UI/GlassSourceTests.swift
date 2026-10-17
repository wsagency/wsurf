// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// Source-level rules for the chrome's glass. A render test cannot see which glass a view asked the system
/// for, so these read the sources the way `ChromeWashTests` does.
struct GlassSourceTests {
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
    }

    /// Every app source file, as a path relative to the repository and its text.
    private func appSources() throws -> [(path: String, text: String)] {
        let app = Self.root.appending(path: "WSurf")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { (path: String($0.path.dropFirst(Self.root.path.count + 1)), text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Reduce Transparency and Increase Contrast are answered once. A raw `.glassEffect` elsewhere would keep
    /// sampling for people who asked for opaque chrome.
    @Test func glassIsRequestedOnlyThroughTheSharedPolicy() throws {
        let raw = try appSources().filter { $0.text.contains(".glassEffect(") }.map(\.path)

        #expect(raw == ["WSurf/UI/Chrome/GlassPolicy.swift"], "raw glass in \(raw)")
    }

    /// Glass cannot sample glass, and a window backdrop is not a floating control. The transparent style is one
    /// blurred backdrop under a tint, so it asks the system for a single effect instead of two.
    @Test func theTransparentBackdropHasNoGlassLayer() throws {
        let loom = try source("WSurf/UI/Chrome/LoomChrome.swift")
        let appKitGlass = try appSources().filter { $0.text.contains("NSGlassEffectView") }.map(\.path)

        #expect(loom.contains("VisualEffectView("))
        #expect(!loom.contains("GlassEffectView"))
        #expect(appKitGlass.isEmpty, "AppKit glass in \(appKitGlass)")
    }

    /// Clear glass needs its own dimming and reads differently beside Regular, so the chrome draws Regular only.
    @Test func noClearGlassRemains() throws {
        let clear = try appSources()
            .filter { $0.text.contains(".clear.tint(") || $0.text.contains("Glass.clear") || $0.text.contains("glassEffect(.clear") }
            .map(\.path)

        #expect(clear.isEmpty, "Clear glass in \(clear)")
    }

    /// Neighboring glass shares one sampling pass. These are the places where several glass elements sit side by
    /// side: marked sidebar rows, the cards pinned above the sidebar footer and the Settings navigation.
    @Test func neighboringGlassSharesOneContainer() throws {
        let groups = [
            "WSurf/UI/Sidebar/WorkspaceList.swift": 1,
            "WSurf/UI/Sidebar/Sidebar.swift": 1,
            "WSurf/Settings/SettingsNavigation.swift": 2,
        ]
        for (path, expected) in groups {
            let uses = try source(path).components(separatedBy: ".glassGroup(").count - 1
            #expect(uses == expected, "\(path) groups \(uses) places, expected \(expected)")
        }
        let containers = try appSources().filter { $0.text.contains("GlassEffectContainer(") }.map(\.path)

        #expect(containers == ["WSurf/UI/Chrome/GlassPolicy.swift"], "containers in \(containers)")
    }
}
