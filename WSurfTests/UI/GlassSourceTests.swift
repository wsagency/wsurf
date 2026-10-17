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
}
