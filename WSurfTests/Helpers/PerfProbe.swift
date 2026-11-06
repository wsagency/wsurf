// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Darwin
import Foundation

@testable import WSurf

/// Shared measuring helpers of the benchmark suites (`WindowPerformanceTests`, and the report-only engine and resource suites).
/// Ported from the 0.1.17 perf audit probe and the 0.1.22 audit harness. Everything here runs on the main actor; the clocks it
/// reads (`CLOCK_THREAD_CPUTIME_ID`) belong to the calling thread, so the CPU figures are the main thread's.
@MainActor
enum PerfProbe {
    /// CPU time of the calling thread in milliseconds. Call it on the main actor only.
    static func mainCPUms() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// `n=… medianMs=… meanMs=… p90Ms=… p99Ms=… maxMs=…` of the samples (milliseconds, or any one unit).
    static func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "n=0" }
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return String(
            format: "n=%d medianMs=%.2f meanMs=%.2f p90Ms=%.2f p99Ms=%.2f maxMs=%.2f",
            sorted.count, sorted[sorted.count / 2], mean, percentile(0.9), percentile(0.99), sorted[sorted.count - 1]
        )
    }

    /// One pass of the run loop, then layout and display of `view`: the work of a frame the person sees.
    static func draw(_ view: NSView) {
        RunLoop.current.run(until: Date())
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    /// Spins the run loop in 5 ms slices until `condition` holds or `timeout` passes. Returns whether it holds.
    @discardableResult
    static func spin(timeout: TimeInterval = 60, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    /// Runs the main run loop for `seconds` and does nothing else. Only for a deliberate, named "after" window.
    static func idle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    /// A background tab of a crowded window: a row like one `newTab(activate: false)` adds (unseen, a start page or the given
    /// address), with no web view behind it. Same as `BrowserPerformanceTests.addBackgroundTab`, which keeps its own copy.
    @discardableResult
    static func addBackgroundTab(to browser: BrowserModel, address: String? = nil) -> BrowserTab {
        let tab = browser.makeTab(restoring: true)
        if let address {
            tab.urlString = address
        } else {
            tab.pageTitle = SystemPages.startTitle
        }
        tab.isUnseen = true
        browser.insert(tab, after: nil)
        return tab
    }

    /// Marks onboarding done in this host's own defaults while `body` runs, or every window draws the animated onboarding.
    static func withOnboardingDone<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = StageMode.defaults
        let completed = defaults.object(forKey: "onboarding.completed")
        defaults.set(true, forKey: "onboarding.completed")
        defer { defaults.set(completed, forKey: "onboarding.completed") }
        return try body()
    }

    /// One result line, the format the report scripts and `run` grep for.
    static func report(_ name: String, _ fields: String) {
        print("WSURF-BENCH case=\(name) \(fields)")
    }

    // MARK: - Process accounting

    struct ProcessUsage {
        /// User plus system CPU seconds since the process started.
        var cpuSeconds: Double
        /// Package idle wakeups plus interrupt wakeups since the process started.
        var wakeups: UInt64
        /// Physical footprint in bytes (what `XCTMemoryMetric` samples for the host).
        var footprint: UInt64
        /// Billed energy in nanojoules (`ri_billed_energy`): an energy proxy that needs no sudo.
        var billedEnergy: UInt64
    }

    static func usage(of pid: pid_t) -> ProcessUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let seconds = Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        return ProcessUsage(
            cpuSeconds: seconds,
            wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
            footprint: info.ri_phys_footprint,
            billedEnergy: info.ri_billed_energy
        )
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "?"
    }

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsible: Responsible? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Responsible.self)
    }()

    /// This host, its children (CEF helpers) and the WebKit XPC processes it is responsible for.
    static func family() -> [(pid: pid_t, name: String)] {
        let me = getpid()
        var all = [pid_t](repeating: 0, count: 8_192)
        let bytes = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
        let count = max(0, Int(bytes)) / MemoryLayout<pid_t>.size
        var result: [(pid: pid_t, name: String)] = [(me, "host")]
        for pid in all.prefix(count) where pid > 0 && pid != me {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            let path = path(of: pid)
            let name = (path as NSString).lastPathComponent
            if info.pbi_ppid == UInt32(me) {
                result.append((pid, name))
            } else if path.contains("WebKit"), let responsible, responsible(pid) == me {
                result.append((pid, name))
            }
        }
        return result
    }

    /// Footprint of the whole family in bytes, per process name (a name that occurs twice is summed) and the process count.
    static func familySnapshot() -> (total: UInt64, perProcess: [String: UInt64], count: Int) {
        let members = family()
        var total: UInt64 = 0
        var perProcess: [String: UInt64] = [:]
        for member in members {
            let bytes = usage(of: member.pid)?.footprint ?? 0
            total += bytes
            perProcess[member.name, default: 0] += bytes
        }
        return (total, perProcess, members.count)
    }
}

/// Gaps between the ticks of a 2 ms timer on the main run loop (common modes): a gap is how long the main thread was busy.
@MainActor
final class HitchWatch {
    private(set) var gaps: [Double] = []
    private var last = ContinuousClock.now
    private var timer: Timer?

    var longestMs: Double {
        gaps.max() ?? 0
    }

    func start() {
        gaps = []
        last = ContinuousClock.now
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ContinuousClock.now
        gaps.append(PerfProbe.ms(now - last))
        last = now
    }
}
