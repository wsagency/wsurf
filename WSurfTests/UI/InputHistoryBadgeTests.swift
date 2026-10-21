// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized)
struct InputHistoryBadgeTests {
    private func settings(recording: Bool, _ names: inout [String]) throws -> BrowserSettings {
        let name = AppDatabase.defaultsSuite("InputHistoryBadgeTests.\(UUID().uuidString)")
        names.append(name)
        let settings = BrowserSettings(defaults: try #require(UserDefaults(suiteName: name)))
        settings.recordsInputHistory = recording
        return settings
    }

    private func forget(_ names: [String]) {
        for name in names {
            UserDefaults().removePersistentDomain(forName: name)
        }
    }

    @Test func isShownOnlyWhileInputHistoryIsOn() throws {
        var names: [String] = []
        defer { forget(names) }
        let off = try settings(recording: false, &names)
        let on = try settings(recording: true, &names)

        #expect(!InputHistoryBadge.isShown(settings: off, isPrivate: false, isWebPage: true))
        #expect(InputHistoryBadge.isShown(settings: on, isPrivate: false, isWebPage: true))

        // The same settings object follows the switch: turning it off hides the button again.
        on.recordsInputHistory = false
        #expect(!InputHistoryBadge.isShown(settings: on, isPrivate: false, isWebPage: true))
    }

    @Test func staysHiddenInAPrivateProfileAndOnInternalPages() throws {
        var names: [String] = []
        defer { forget(names) }
        let on = try settings(recording: true, &names)

        #expect(!InputHistoryBadge.isShown(settings: on, isPrivate: true, isWebPage: true))
        #expect(!InputHistoryBadge.isShown(settings: on, isPrivate: false, isWebPage: false))
    }

    @Test func opensTheInputHistorySubPageOfAutofill() throws {
        let entry = try #require(SettingsIndex.all.first { $0.id == InputHistoryBadge.anchor })
        #expect(entry.category == .autofill)
        #expect(AutofillDestination(anchor: entry.targetAnchor) == .inputHistory)
    }

    @Test func hasAVoiceOverLabelAndASymbolThatExists() {
        #expect(String(localized: InputHistoryBadge.title) == "Input History")
        #expect(NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: nil) != nil)
    }
}
