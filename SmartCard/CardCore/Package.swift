// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CardCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CardCore", targets: ["CardCore"])],
    targets: [
        // PCSC.framework's modulemap is `requires !swift`, so Swift cannot import it and a C target
        // that #includes its headers fails to build. CPCSC re-declares the seven PC/SC calls we use
        // (ABI from the SDK's winscard.h/pcsclite.h) and links the framework via `link framework`.
        .systemLibrary(name: "CPCSC"),
        .target(name: "CardCore", dependencies: ["CPCSC"]),
        .testTarget(name: "CardCoreTests", dependencies: ["CardCore"]),
    ]
)
