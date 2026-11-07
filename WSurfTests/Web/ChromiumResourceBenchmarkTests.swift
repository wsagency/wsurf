// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

// What Chromium leaves behind: the process family before CEF starts, with 1 and 3 Chromium tabs, idle, and 10, 30 and 60 s after
// every Chromium tab is closed. Reported (`WSURF-ENGINE-BENCH`), never budgeted.
//
// CEF cannot start twice in one process, and once it runs in a test host XCTest's memory metric crashes later cases
// (`ChromiumLoadBenchmarkTests`), so this suite is in `Tools/serial-parts.json` `skippedSuites`, gated on `WSURF_PERF_BENCH=1`,
// and run alone, one run per sample: `-only-testing:WSurfTests/ChromiumResourceBenchmarkTests`, with
// `-default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 900`. No getUserMedia, not even with fake
// devices (they still prompt for the microphone).
private nonisolated let benchEnabled = ProcessInfo.processInfo.environment["WSURF_PERF_BENCH"] == "1"

@MainActor
@Suite(.serialized)
struct ChromiumResourceBenchmarkTests {
    private nonisolated static let prefix = "WSURF-ENGINE-BENCH"

    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func chromiumFamilyLifecycle() async throws {
        guard !ChromiumRuntime.shared.isInitialized else {
            print("\(Self.prefix) case=R8 skipped=\"CEF is already initialised in this host\"")
            return
        }
        try await LiveWindowRig.with(engine: .chromium) { rig in
            @MainActor func record(_ label: String) {
                let stage = ResourceProbe.stage(label)
                print(String(
                    format: "%@ case=R8-lifecycle step=%@ hostMB=%.1f hostWakeups=%llu helperCount=%d helperMB=%.1f webKitWebContent=%d totalMB=%.1f procs=%d",
                    Self.prefix, label, stage.host, stage.hostWakeups, stage.otherCount, stage.other, stage.webContentCount,
                    stage.total, stage.count
                ))
            }
            record("before-cef")
            var tabs: [BrowserTab] = []
            tabs.append(try await rig.open("/still"))
            try await Task.sleep(for: .seconds(3))
            record("1-chromium-tab")
            tabs.append(try await rig.open("/still"))
            tabs.append(try await rig.open("/still"))
            try await Task.sleep(for: .seconds(3))
            record("3-chromium-tabs")
            await ResourceProbe.idleTable("R8-idle-3-tabs", seconds: 20, prefix: Self.prefix)
            let clock = ContinuousClock()
            let closing = clock.now
            for tab in tabs {
                rig.browser.close(tab)
            }
            for tab in tabs {
                await tab.waitForRetirement()
            }
            print(String(format: "%@ case=R8-lifecycle closeAndRetireMs=%.1f", Self.prefix, PerfProbe.ms(clock.now - closing)))
            try await Task.sleep(for: .seconds(10))
            record("closed+10s")
            try await Task.sleep(for: .seconds(20))
            record("closed+30s")
            try await Task.sleep(for: .seconds(30))
            record("closed+60s")
            await ResourceProbe.idleTable("R8-idle-0-chromium-tabs", seconds: 20, prefix: Self.prefix)
        }
    }
}
