// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// WSurf's start scripts in a Chromium frame's first, empty document and in the document that takes over its window, in the window
/// the app builds (every script the app installs). A page that reads a new frame's window at once makes Chromium set that empty
/// document up and run the start scripts in it; a document of the same origin then takes over the window, and Chromium starts none of
/// its scripts again.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct FrameStartScriptTests {
    /// A frame whose announced document is a 204 keeps its first, empty document. The page reads the frame's window at once and later
    /// plays a muted player in that document, on a loop so that it is still playing half a second later unless something stopped it.
    private static let blankFrame = """
        <!doctype html><title>Frame</title><body><script>
        const frame = document.createElement('iframe');
        frame.src = '/empty';
        frame.name = 'blank';
        document.body.append(frame);
        const blank = window.frames[frame.name];
        setTimeout(() => {
          const video = blank.document.createElement('video');
          video.muted = true;
          video.loop = true;
          video.src = '/tone.wav';
          blank.document.body.append(video);
          video.play().then(() => setTimeout(() => { document.title = video.paused ? 'held' : 'played'; }, 500),
                            error => { document.title = error.name; });
        }, 1000);
        </script>
        """

    /// Apple's sign-in shape: a frame of the page's own origin whose window the page keeps at once (`window.frames[name]`).
    private static let takeover = """
        <!doctype html><title>Top</title><body><script>
        const frame = document.createElement('iframe');
        frame.src = location.origin + '/frame';
        frame.name = 'widget';
        document.body.append(frame);
        window.widget = window.frames[frame.name];
        </script>
        """

    private static var routes: [String: HTTPFixtureServer.Response] {
        [
            "/blank-frame": .html(blankFrame),
            "/empty": HTTPFixtureServer.Response(status: "204 No Content", headers: [:], body: Data()),
            "/tone.wav": .bytes(WebKitSiteContentTests.wave, contentType: "audio/wav"),
            "/takeover": .html(takeover),
            "/frame": .html(#"<!doctype html><title>Widget</title><form><input id="u" autocomplete="username"><input id="p" type="password"></form>"#),
        ]
    }

    private static func widget(in chromium: ChromiumPage) async -> BrowserFrame? {
        try? await chromium.devTools.frames().first { !$0.isMainFrame && $0.request.url?.path == "/frame" }
    }

    /// The start-script instances of `world` in `frame`: how many there are, and how many are live and the current document's.
    private static func runs(in tab: BrowserTab, frame: BrowserFrame, world: String) async -> [String: Any] {
        let answer = try? await tab.page.callAsyncJavaScript("""
            const runs = [...(globalThis.__wsurfStartRuns?.values() ?? [])];
            return {count: runs.length, current: runs.filter(run => run.document === document && run.alive).length};
            """, in: frame, contentWorld: WKContentWorld.world(name: world))
        return answer as? [String: Any] ?? [:]
    }

    private func title(of tab: BrowserTab) async -> String? {
        (try? await tab.page.evaluateJavaScript("document.title")) as? String
    }

    /// A page can use a frame's first, empty document itself, and the site's answer holds there as anywhere on the page: under Never
    /// a muted player the page starts in it is stopped. The frame element still names a document to load (a 204 that never commits),
    /// so nothing the page controls may keep WSurf's start scripts out of that document.
    @Test func aBlankFrameThePageUsesIsUnderTheSitesAnswer() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            rig.browser.sitePermissions.setAutoplay(.block, for: SitePermissions.origin(for: try rig.server.url("/blank-frame")))
            let tab = try await rig.open("/blank-frame")
            let started = await waitUntil { await title(of: tab) != "Frame" }
            #expect(started, "the page started its player")
            let outcome = await title(of: tab)
            print("FRAME-SCRIPTS blank frame player: \(outcome ?? "nil")")
            #expect(outcome == "AbortError" || outcome == "held", "the player in the blank frame was stopped: \(outcome ?? "nil")")
        }
    }

    /// The document that takes over gets every start script once: in each of WSurf's worlds, each script WSurf runs in frames has one
    /// live instance, the current document's, and the empty document's instance is retired.
    @Test func theDocumentThatTakesOverRunsEveryStartScriptOnce() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            let tab = try await rig.open("/takeover")
            let chromium = try #require(tab.page.chromium)
            // Waits outside the macros: a closure in a macro's expansion and the next one in the same function get one name.
            let loaded = await waitUntil { await Self.widget(in: chromium) != nil }
            try #require(loaded, "the frame loaded")
            let frame = try #require(await Self.widget(in: chromium))
            let rerun = chromium.devTools.scripts.filter {
                !$0.mainFrameOnly && !$0.worldName.isEmpty && !WebAuthnScript.followsItsWindow($0.source)
            }
            let worlds = Dictionary(grouping: rerun, by: \.worldName).mapValues { Set($0.map(\.source)).count }
            try #require(!worlds.isEmpty, "the app runs start scripts in frames")
            for (name, expected) in worlds {
                let settled = await waitUntil { await Self.runs(in: tab, frame: frame, world: name)["current"] as? Int == expected }
                let runs = await Self.runs(in: tab, frame: frame, world: name)
                #expect(settled && runs["count"] as? Int == expected, "\(name): \(runs) for \(expected) scripts")
            }
        }
    }
}
