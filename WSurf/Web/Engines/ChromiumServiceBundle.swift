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
    static let frameworkName = "Chromium Embedded Framework.framework"

    static var url: URL {
        Bundle.main.bundleURL.appending(path: "Contents/XPCServices/WSurf Chromium.xpc", directoryHint: .isDirectory)
    }

    /// Whether the running app has the service: the gate of every test that needs it.
    ///
    /// Never in a Release build, whatever is on disk, until the owner's signing PR (D4-S) signs the service: the service is for
    /// DEBUG, test and staged builds only (staged builds are DEBUG), so Release keeps the framework and the helpers in
    /// `Contents/Frameworks` by construction.
    static var isPresent: Bool {
        #if DEBUG
        return FileManager.default.fileExists(atPath: url.appending(path: "Contents/Info.plist").path)
        #else
        return false
        #endif
    }

    /// The folder that holds the framework and the helpers in the service's one-copy layout, or nil in the default layout.
    static var frameworks: URL? {
        isPresent ? url.appending(path: "Contents/Frameworks", directoryHint: .isDirectory) : nil
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
