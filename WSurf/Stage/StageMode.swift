// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

#if DEBUG
import CryptoKit
import Foundation
import WebKit

nonisolated enum StageMode {
    static let isActive: Bool = {
        guard let value = ProcessInfo.processInfo.environment["WSURF_STAGE"] else { return false }
        return !value.isEmpty && value != "0"
    }()

    static let home: URL? = {
        guard isActive else { return nil }
        let path = ProcessInfo.processInfo.environment["WSURF_STAGE_HOME"]
            ?? NSTemporaryDirectory() + "wsurf-stage/home"
        return URL(filePath: path, directoryHint: .isDirectory)
    }()

    static func identity(for home: URL) -> String {
        SHA256.hash(data: Data(home.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func defaultsSuiteName(for home: URL) -> String {
        "io.wsagency.wsurf.stage.\(identity(for: home))"
    }

    static func defaults(for home: URL) -> UserDefaults {
        UserDefaults(suiteName: defaultsSuiteName(for: home))!
    }

    static func dataStoreID(for home: URL) -> UUID {
        let fingerprint = identity(for: home)
        let value = [
            String(fingerprint.prefix(8)),
            String(fingerprint.dropFirst(8).prefix(4)),
            String(fingerprint.dropFirst(12).prefix(4)),
            String(fingerprint.dropFirst(16).prefix(4)),
            String(fingerprint.suffix(12)),
        ].joined(separator: "-")
        return UUID(uuidString: value)!
    }

    static var dataStoreID: UUID {
        guard isActive, let home else {
            return UUID(uuidString: "57A6E000-0000-4000-A000-000000000001")!
        }
        return dataStoreID(for: home)
    }

    static var defaults: UserDefaults {
        guard isActive, let home else { return .standard }
        return defaults(for: home)
    }

    @MainActor
    static func websiteDataStore() -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: dataStoreID)
    }
}
#endif
