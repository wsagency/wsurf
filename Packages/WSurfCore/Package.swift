// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

// Platform-neutral code shared by the macOS app and a later iOS app. No target imports AppKit, SwiftUI, WebKit or CefKit.
//
// Each target must compile exactly as it did inside the WSurf app target, so these settings mirror that target's
// build settings: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES and
// SWIFT_APPROACHABLE_CONCURRENCY = YES. In Swift 6 language mode that last setting adds only InferIsolatedConformances
// and NonisolatedNonsendingByDefault; Xcode's Swift.xcspec applies its other three features to Swift 4 and 5 only,
// because Swift 6 mode already includes them.
let coreSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "WSurfCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Static on purpose: a dynamic library would add a framework bundle to the app and its signature.
        .library(name: "WSurfVault", targets: ["WSurfVault"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "WSurfVault",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: coreSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
