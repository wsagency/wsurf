// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// The full address on the Ask surface's row, which the toolbar, the Minimal bar and the micro window's bar all carry: the
/// line stops before the controls at the row's end, the controls keep their size, and hovering shows the whole address.
@MainActor
struct AskAddressLayoutTests {
    /// A local page, so Developer mode is on for it without a setting being written: the full address shows and its badge
    /// joins the row's controls. A long path and query make the line far wider than any row.
    private static let longAddress = "http://app.localhost:5173/" + String(repeating: "very-long-path/", count: 12)
        + "?q=" + String(repeating: "x", count: 80) + "#section"

    private struct Frames: Equatable {
        var address = CGRect.zero
        var controls = CGRect.zero
    }

    /// Lays the toolbar's row out at `width` for the page at `longAddress` and returns where the address line and the
    /// controls ended up, in the row's own space. `content` replaces what the row shows when it is not the model's own.
    private func layout(width: CGFloat, scheme: ColorScheme, content: AskRestingContent? = nil) throws -> Frames {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer { coordinator.closeWindow() }
        let tab = coordinator.browser.newTab()
        tab.urlString = Self.longAddress
        // A page playing sound adds its badge to the row's controls, as the window's Micro badge does in the app.
        tab.isPlayingAudio = true
        let model = AskSurfaceModel(placement: .toolbar, browser: coordinator.browser, coordinator: coordinator)
        let shown = try #require(content ?? model.restingContent)

        var frames = Frames()
        let row = AskSurfaceRow(
            model: model,
            sections: [],
            restingContent: shown,
            placeholder: "",
            accessibilityValue: "",
            security: .secure
        ) { part, frame in
            switch part {
            case .address:
                frames.address = frame
            case .controls:
                frames.controls = frame
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: AnyView(row.environment(\.colorScheme, scheme).frame(width: width)))
        window.contentView = host

        // The controls' width is measured, and the line is laid out again with it: wait for the frames to stop moving.
        var previous = frames
        var steady = 0
        for _ in 0..<60 where steady < 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            steady = frames == previous && frames.controls.width > 0 ? steady + 1 : 0
            previous = frames
        }
        return frames
    }

    @Test(arguments: zip([CGFloat(480), 900], [ColorScheme.light, .dark]))
    func aLongFullAddressStopsBeforeTheControlsAtTheEndOfTheRow(width: CGFloat, scheme: ColorScheme) throws {
        let address = try #require(AddressText(URL(string: Self.longAddress)))
        let whole = NSHostingView(rootView: FullAddressLine(address: address, fontSize: AskSurface.Placement.toolbar.textSize))
            .fittingSize.width
        let frames = try layout(width: width, scheme: scheme)

        #expect(whole > width, "the address is wider than the row, so something has to be cut")
        #expect(frames.controls.width > 0 && frames.address.width > 0, "both were laid out: \(frames)")
        #expect(
            frames.address.maxX + AskSurface.Placement.toolbar.controlSpacing <= frames.controls.minX + 0.5,
            "the line ends at \(frames.address.maxX), the controls start at \(frames.controls.minX)"
        )
        #expect(frames.address.width > width / 3, "the line takes the room that is left: \(frames.address.width) of \(width)")
    }

    @Test func theControlsKeepTheirSizeWhateverTheLineSays() throws {
        let long = try layout(width: 480, scheme: .light)
        let name = try layout(width: 480, scheme: .light, content: .address("app.localhost"))

        #expect(long.controls.width > 0)
        #expect(abs(long.controls.width - name.controls.width) < 0.5, "\(long.controls) against \(name.controls)")
        #expect(abs(long.controls.maxX - name.controls.maxX) < 0.5, "they stay at the end of the row")
    }

    @Test func hoveringTheAddressShowsAllOfItThenTheEngine() throws {
        let address = try #require(AddressText(URL(string: Self.longAddress)))
        let full = AskRestingContent.address(address.host, scheme: address.scheme, rest: address.rest)

        #expect(full.tooltip(engine: nil) == Self.longAddress)
        #expect(full.tooltip(engine: .chromium) == Self.longAddress + "\n" + String(localized: BrowserEngine.chromium.label))
        #expect(AskRestingContent.address("app.localhost").tooltip(engine: .webKit) == String(localized: BrowserEngine.webKit.label))
        #expect(AskRestingContent.notice("Copied").tooltip(engine: nil).isEmpty)

        let row = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "WSurf/UI/Ask/AskSurfaceRow.swift"),
            encoding: .utf8
        )
        #expect(row.contains(".help(Text(verbatim: restingContent?.tooltip(engine: model.addressEngine) ?? \"\"))"))
    }
}
