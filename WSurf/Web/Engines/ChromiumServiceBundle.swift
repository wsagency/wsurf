// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Where the out-of-process Chromium service lives in the app bundle (D4, `Packages/CefSwift/WSURF-PATCHES.md` patch 3).
///
/// `Tools/embed-chromium.sh` builds `Contents/XPCServices/WSurf Chromium.xpc` only for a build with
/// `WSURF_CHROMIUM_OOP_BUILD=YES`. That build has one copy of CEF's framework and helpers, inside the service, because
/// Chromium's helper sandbox reads only inside its browser process's main bundle. The default build has no service and keeps
/// them in `Contents/Frameworks`. The layout decides, so no switch is read here.
nonisolated enum ChromiumServiceBundle {
    static let name = "WSurf Chromium.xpc"
    static let frameworkName = "Chromium Embedded Framework.framework"
    /// The five helper apps, in the order `Tools/embed-chromium.sh` writes them.
    static let helperNames = ["WSurf Helper", "WSurf Helper (Alerts)", "WSurf Helper (GPU)", "WSurf Helper (Plugin)", "WSurf Helper (Renderer)"]

    static func url(in app: URL) -> URL {
        app.appending(path: "Contents/XPCServices/\(name)", directoryHint: .isDirectory)
    }

    /// Whether this app bundle has the service.
    static func isPresent(in app: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: app).appending(path: "Contents/Info.plist").path)
    }

    /// Whether the running app has the service: the gate of every test that needs it.
    static var isPresent: Bool {
        isPresent(in: Bundle.main.bundleURL)
    }

    /// The folder that holds the framework and the helpers in the service's one-copy layout, or nil in the default layout.
    static func frameworks(in app: URL) -> URL? {
        guard isPresent(in: app) else { return nil }
        return url(in: app).appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
    }

    static var frameworks: URL? {
        frameworks(in: Bundle.main.bundleURL)
    }

    /// The app's own CEF framework folder, from the service's copy when the app has one.
    static var frameworkDirectory: URL? {
        frameworks?.appending(path: frameworkName, directoryHint: .isDirectory)
    }

    /// The main helper's executable, from the service's copy when the app has one.
    static var helperExecutable: URL? {
        frameworks?.appending(path: "WSurf Helper.app/Contents/MacOS/WSurf Helper", directoryHint: .notDirectory)
    }
}
