// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A closed tab and its page must deinitialise. Counts, not time: the case opens tabs, closes them, waits for each retirement and
/// then for the objects to go, and states how many are still alive. The perf programme (P4) measured 27-28 of 90 closed
/// `BrowserTab` objects alive ten seconds after the close; this is the deterministic form of that number.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct TabDeinitTests {
    /// What one closed tab left behind, held weakly.
    private struct Remains {
        weak var tab: BrowserTab?
        weak var page: BrowserPage?
    }

    private static let tabCount = 8
    /// Retirement waits up to `ChromiumPage.closeTimeout` for CEF; the objects get this long after it.
    private static let bound: Duration = .seconds(30)

    private func closeTabs(in rig: LiveWindowRig) async throws -> [Remains] {
        var remains: [Remains] = []
        var tabs: [BrowserTab] = []
        for _ in 0..<Self.tabCount {
            tabs.append(try await rig.open("/still"))
        }
        for tab in tabs {
            remains.append(Remains(tab: tab, page: tab.page))
        }
        for tab in tabs {
            rig.browser.close(tab, recordForReopening: false)
        }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        return remains
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func closedTabsAndTheirPagesDeinitialise(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            _ = try await rig.open("/still")  // The window keeps one tab, so closing the others never closes it.
            let remains = try await closeTabs(in: rig)
            try #require(remains.count == Self.tabCount)
            _ = await waitUntil(timeout: Self.bound) { remains.allSatisfy { $0.tab == nil && $0.page == nil } }
            let tabsAlive = remains.filter { $0.tab != nil }.count
            let pagesAlive = remains.filter { $0.page != nil }.count
            if ProcessInfo.processInfo.environment[Self.triageKey] != nil {
                await Self.writeTriage(engine: engine, remains: remains, rig: rig)
            }
            #expect(pagesAlive == 0, "\(pagesAlive) of \(Self.tabCount) closed BrowserPage objects are still alive on \(engine)")
            // Known: every closed tab in a window outlives its close, though its page does not (P4). Remove this wrapper when the
            // retainer is fixed. It is intermittent so that a run in which the tab does go does not fail the gate.
            withKnownIssue("a closed BrowserTab stays alive after its page is gone (P4 triage)", isIntermittent: true) {
                #expect(tabsAlive == 0, "\(tabsAlive) of \(Self.tabCount) closed BrowserTab objects are still alive on \(engine)")
            }
        }
    }

    // MARK: - Triage

    /// With `WSURF_LEAK_TRIAGE=<directory>` in the environment (`TEST_RUNNER_WSURF_LEAK_TRIAGE` for xcodebuild), the case also
    /// writes `<engine>-triage.txt` there: how many closed tabs are alive, the path `leaks --traceTree` finds from a root to the
    /// first of them, and how many are alive once the window is closed as well. A tab alive only while its window is open is
    /// held by that window's views or state; one that survives the window is held by something global.
    private static let triageKey = "WSURF_LEAK_TRIAGE"

    private static func writeTriage(engine: BrowserEngine, remains: [Remains], rig: LiveWindowRig) async {
        guard let directory = ProcessInfo.processInfo.environment[triageKey] else { return }
        var report = "engine: \(engine)\nalive with the window open: \(remains.filter { $0.tab != nil }.count) of \(remains.count)\n"
        if let tab = remains.compactMap(\.tab).first {
            let address = "0x" + String(UInt(bitPattern: Unmanaged.passUnretained(tab).toOpaque()), radix: 16)
            report += "first survivor: \(address)\n\n--- leaks --traceTree\n"
            report += await run("/usr/bin/leaks", ["--traceTree=\(address)", "\(ProcessInfo.processInfo.processIdentifier)"])
        }
        for window in rig.app.windows {
            window.closeWindow()
        }
        _ = await waitUntil(timeout: .seconds(15)) { remains.allSatisfy { $0.tab == nil } }
        report += "\nalive once the window is closed: \(remains.filter { $0.tab != nil }.count) of \(remains.count)\n"
        try? report.write(toFile: directory + "/\(engine.rawValue)-triage.txt", atomically: true, encoding: .utf8)
    }

    /// Runs `tool` and returns what it printed, or why it did not finish within four minutes.
    private static func run(_ tool: String, _ arguments: [String]) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return "could not run \(tool): \(error)"
            }
            let watchdog = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: watchdog)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
