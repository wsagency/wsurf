// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// A settings control whose own label is hidden (a switch, a pop-up menu, a radio group) is named by the title of its row, so VoiceOver
/// says "Sleep inactive tabs, switch, off" and not just "switch, off". `DetailRow` hands its title to the controls inside it through
/// the environment (`settingsRowTitle`); `SettingsToggle` and `SettingsMenu` read it as their accessibility label; an `OptionList` is given its own title.
///
/// This suite proves the first half: the title reaches a control for every way of giving a row its title, and a control outside a
/// titled row reads none. That the control then speaks it rests on SwiftUI's documented behaviour (a `labelsHidden` label stays the
/// accessibility label): an in-process read of the accessibility tree cannot show it, because it sees none of SwiftUI's own text and
/// button nodes, nor a switch's name, even for a control named the documented way.
@MainActor
struct SettingsRowAccessibilityTests {
    private func hosted(_ view: some View) -> (NSHostingView<AnyView>, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(view.frame(width: 640, height: 240)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// Records the row title its place in the view tree reads from the environment.
    private final class Seen {
        var titles: [String?] = []
    }

    private struct Probe: View {
        @Environment(\.settingsRowTitle) private var title
        let seen: Seen

        var body: some View {
            seen.titles.append(title)
            return Color.clear.frame(width: 4, height: 4)
        }
    }

    @Test func aRowHandsItsTitleToItsControls() {
        let seen = Seen()
        let rows = VStack {
            DetailRow(title: "Sleep inactive tabs") { Probe(seen: seen) }
            DetailRow(verbatimTitle: "Connected app") { Probe(seen: seen) }
            DetailRow(title: "Reading voice", attributedCaption: AttributedString("A voice")) { Probe(seen: seen) }
        }
        let (host, window) = hosted(rows)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(Set(seen.titles.compactMap { $0 }) == ["Sleep inactive tabs", "Connected app", "Reading voice"], "\(seen.titles)")
    }

    @Test func aControlOutsideATitledRowReadsNoTitle() {
        let seen = Seen()
        let rows = VStack {
            DetailRow { Probe(seen: seen) }
            Probe(seen: seen)
        }
        let (host, window) = hosted(rows)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(!seen.titles.isEmpty)
        #expect(seen.titles.allSatisfy { $0 == nil }, "\(seen.titles)")
    }
}
