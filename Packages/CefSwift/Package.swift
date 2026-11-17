// swift-tools-version: 6.0
import Foundation
import PackageDescription

// WSurf patch 3 (D4-20): the service's debug ops (see the service target) exist only when Tools/embed-chromium.sh says YES, which it
// does for the OOP test lane and for staged DEBUG ad hoc builds, never for Release or a real signing identity.
let serviceDebugOps = ProcessInfo.processInfo.environment["WSURF_SERVICE_DEBUG_OPS"] == "YES"

let package = Package(
    name: "CefSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CefKit", targets: ["CefKit"]),
        .library(name: "CefSwiftUI", targets: ["CefSwiftUI"]),
        .executable(name: "cef-helper", targets: ["cef-helper"]),
        // WSurf patch 3 (D4): the out-of-process Chromium service. Tools/embed-chromium.sh assembles it into WSurf Chromium.xpc,
        // and only for a build with WSURF_CHROMIUM_OOP_BUILD=YES.
        .executable(name: "wsurf-chromium-service", targets: ["wsurf-chromium-service"]),
        .plugin(name: "CefPlugin", targets: ["CefPlugin"]),
    ],
    targets: [
        // Vendored CEF C API headers + runtime dlopen/dlsym loader.
        .target(
            name: "CCef",
            exclude: [
                "LICENSE.CEF.txt",
                "include/include/base/internal/cef_color_id_macros.inc",
                "include/include/base/internal/README-TRANSFER.txt",
            ],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        // NSApplication subclass conforming to CEF's CrAppControlProtocol.
        .target(
            name: "CCefAppKit",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Core Swift wrapper over the CEF C API.
        .target(
            name: "CefKit",
            dependencies: ["CCef", "CCefAppKit"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // First-class SwiftUI integration.
        .target(
            name: "CefSwiftUI",
            dependencies: ["CefKit"]
        ),
        // Helper-process executable, bundled five times by the CefPlugin.
        .executableTarget(
            name: "cef-helper",
            dependencies: ["CefKit"]
        ),
        // WSurf patch 3 (D4): CEF's browser process, windowless, in an XPC service. Swift 5 mode keeps the C callback code that
        // later phases add readable; everything in it runs on the service's main thread, which is CEF's UI thread.
        .executableTarget(
            name: "wsurf-chromium-service",
            dependencies: ["CefKit", "CCef", "CCefAppKit"],
            // Tools/embed-chromium.sh builds the service in release, where `#if DEBUG` is false, so the debug ops (abort, stats,
            // exitOnHello, askHost, memoryPressure, stubBrowser, hangExit, holdHistory, and `browser.create`'s DEBUG creation flags,
            // and a log file) have their own define. It is on only when the environment says WSURF_SERVICE_DEBUG_OPS=YES, which
            // embed-chromium.sh sets for the OOP test lane and staged DEBUG ad hoc builds and never for Release or a signing
            // identity (D4-20). Tools/check-service-strings.sh proves a build without it has none of them.
            swiftSettings: [.swiftLanguageMode(.v5)] + (serviceDebugOps ? [.define("WSURF_SERVICE_DEBUG_OPS")] : []),
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // `swift package cef <download|bundle|info|clean>`
        .plugin(
            name: "CefPlugin",
            capability: .command(
                intent: .custom(
                    verb: "cef",
                    description: "Download the pinned CEF distribution and assemble runnable .app bundles"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Cache CEF distributions in .cef/ and write .app bundles"),
                    .allowNetworkConnections(scope: .all(ports: []), reason: "Download CEF binaries from cef-builds.spotifycdn.com"),
                ]
            )
        ),
        .testTarget(
            name: "CefKitTests",
            dependencies: ["CefKit", "CefSwiftUI"]
        ),
    ],
    cLanguageStandard: .c11
)
