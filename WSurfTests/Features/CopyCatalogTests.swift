// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

/// Guards over the string catalog and the settings search index, so the copy
/// conventions in CONTRIBUTING.md are enforced rather than remembered: curly
/// apostrophes and em dashes in what the user reads, US English, no
/// "Are you sure" preambles, and one capitalization per label.
/// The repository checkout, found by walking up from this file until the
/// project file appears, so moving the test does not break the lookup.
private enum Repo {
    nonisolated static let root: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let project = directory.appending(path: "WSurf.xcodeproj").path
            if FileManager.default.fileExists(atPath: project) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }()
}

/// The catalog is compiled away inside the app bundle, so the tests read the
/// source.
struct CopyCatalogTests {

    /// Every string the user can read: each key stands in for its own English
    /// text, and an entry with plural or device variations carries the real
    /// text in its values instead.
    private static let displayStrings: [String] = {
        let url = Repo.root.appending(path: "WSurf/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any]
        else { return [] }

        var collected: [String] = []
        for (key, value) in strings {
            guard let entry = value as? [String: Any] else { continue }
            let values = leafValues(of: entry)
            collected.append(contentsOf: values.isEmpty ? [key] : values)
        }
        return collected
    }()

    private static func leafValues(of node: [String: Any]) -> [String] {
        var found: [String] = []
        for (key, value) in node {
            if key == "value", let text = value as? String {
                found.append(text)
            } else if let nested = value as? [String: Any] {
                found.append(contentsOf: leafValues(of: nested))
            }
        }
        return found
    }

    @Test func theCatalogWasFoundAndIsNotEmpty() {
        #expect(!Self.displayStrings.isEmpty)
    }

    @Test func displayStringsUseTheCurlyApostrophe() {
        let offenders = Self.displayStrings.filter { string in
            string.contains(/[A-Za-z]'/) || string.contains(/'[A-Za-z]/)
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func displayStringsUseAnEmDashNotASpacedHyphen() {
        let offenders = Self.displayStrings.filter { $0.contains(" - ") }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func displayStringsUseUSEnglish() {
        let british: [String] = [
            "colour", "organisation", "behaviour", "favourite", "authorise",
            "customise", "minimise", "maximise", "dialogue", "cancelled",
            "grey ", "centred", "licence",
        ]
        let offenders = Self.displayStrings.filter { string in
            let lowered = string.lowercased()
            return british.contains { lowered.contains($0) }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func confirmationsAskDirectlyWithoutAPreamble() {
        let offenders = Self.displayStrings.filter { $0.contains("Are you sure") }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func webpageIsOneWord() {
        let offenders = Self.displayStrings.filter { $0.lowercased().contains("web page") }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// The page a tab returns to is a pin. "Bookmark" survives in one other
    /// sense only: importing another browser's bookmarks file, which makes a
    /// folder of tabs rather than an anchor.
    @Test func theTabsAnchorPageIsCalledAPin() {
        let offenders = Self.displayStrings
            .filter { $0.contains(/\b[Bb]ookmark(ed)?\b/) }
            // The singular of the imported-file count, not the anchor.
            .filter { $0 != "%lld bookmark" }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// The placeholder teaches the one character that addresses the assistant,
    /// so it has to keep saying it.
    @Test func theAskFieldNamesItsTrigger() {
        #expect(AskSurface.Placement.startPage.placeholder.contains("@"))
        #expect(AskSurface.Placement.toolbar.placeholder.contains("@"))
    }

    /// Case pairs that are two different surfaces sharing words, not one
    /// label forking: a menu item beside a settings row title, or a label
    /// beside its mid-sentence `sentenceName` variant.
    private static let intentionalCasePairs: Set<String> = [
        "all time", "assistant access", "background scripts", "browsing history",
        "cached files", "cookies and site data", "local storage", "money transfers",
        "new tab", "on this mac", "page zoom", "posting and sending",
        "reset settings", "show lyrics", "show sidebar", "software update",
        "start page", "remove extension", "sign in", "extension options",
        "clear list", "pop-up windows", "check for updates",
    ]

    /// Two keys that differ only in case are one label about to fork - the
    /// tooltip spelled one way and the menu item another. Single words are
    /// exempt: their case is decided by where they sit in a sentence, and the
    /// codebase deliberately keeps `listName`/`sentenceName` variants.
    @Test func noLabelShipsInTwoCapitalizations() {
        var byFoldedText: [String: [String]] = [:]
        for string in Self.displayStrings
        where string.contains(" ") && !Self.intentionalCasePairs.contains(string.lowercased()) {
            byFoldedText[string.lowercased(), default: []].append(string)
        }
        let forks = byFoldedText.values.filter { Set($0).count > 1 }
        #expect(forks.isEmpty, "\(forks)")
    }
}
