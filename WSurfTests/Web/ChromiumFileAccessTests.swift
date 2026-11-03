// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// A page opened from a `file:` URL, such as a download opened in a tab, may read only what Chromium lets it read by
/// default. These guards fail if a switch or setting that lets a local page read other local files, or every site,
/// is ever added.
struct ChromiumFileAccessTests {
    /// The switches and CEF settings that widen file access, as the lower-case text they would appear as in source.
    private static let wideningNeedles = [
        "allow-file-access-from-files", "allow-universal-access-from-files", "disable-web-security",
        "file_access_from_file_urls", "universal_access_from_file_urls", "file-access-from-file-urls",
        "universal-access-from-file-urls", "onbeforecommandlineprocessing",
    ]

    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func chromiumIsStartedWithoutAnyFileAccessSwitch() {
        let switches = ChromiumRuntime.extraCommandLineSwitches.keys.map { $0.lowercased() }

        #expect(!switches.isEmpty)
        for name in switches {
            #expect(!Self.wideningNeedles.contains { name.contains($0) }, "\(name) widens file access")
            #expect(!name.contains("file-access") && !name.contains("web-security"), "\(name) widens file access")
        }
    }

    @Test func noSourceTurnsOnFileAccessFromFileURLs() throws {
        let enumerator = try #require(FileManager.default.enumerator(
            at: repositoryRoot.appending(path: "WSurf"), includingPropertiesForKeys: nil
        ))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            if Self.wideningNeedles.contains(where: text.contains) {
                found.append(url.lastPathComponent)
            }
        }
        #expect(found.isEmpty, "file access is widened in \(found)")
        // A scan that found no files would pass for the wrong reason.
        #expect(scanned > 400)
    }
}
