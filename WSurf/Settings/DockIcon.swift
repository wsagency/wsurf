// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// The icon the Dock shows while WSurf runs. It is a runtime override only: nothing is written to the app, so Finder,
/// Applications and the Dock of a closed app keep the icon in the bundle, and the choice is applied again at each launch.
enum DockIconChoice: String, CaseIterable {
    /// The icon in the bundle, drawn by the system in the style the Mac is set to.
    case standard
    case light
    case dark
    case mono

    var label: LocalizedStringResource {
        switch self {
        case .standard:
            return "Default"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .mono:
            return "Mono"
        }
    }

    /// The image set in the asset catalog; nil for the icon in the bundle.
    var assetName: String? {
        switch self {
        case .standard:
            return nil
        case .light:
            return "AlternateIconLight"
        case .dark:
            return "AlternateIconDark"
        case .mono:
            return "AlternateIconMono"
        }
    }

    /// The image the Dock shows. nil restores the icon in the bundle. The system draws it as it is, with no
    /// Liquid Glass, dark, clear or tinted style.
    var image: NSImage? {
        assetName.flatMap { NSImage(named: NSImage.Name($0)) }
    }

    /// Sets the Dock icon for this run.
    @MainActor
    static func show(_ image: NSImage?) {
        NSApp.applicationIconImage = image
    }
}

enum AppIcon {
    /// The icon in the app bundle. The Dock choice replaces `NSApp.applicationIconImage`, so About and onboarding
    /// read the bundle's icon instead.
    static var bundle: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        // The workspace icon is 32 points wide; a larger size lets SwiftUI draw its largest representation.
        icon.size = NSSize(width: 512, height: 512)
        return icon
    }
}
