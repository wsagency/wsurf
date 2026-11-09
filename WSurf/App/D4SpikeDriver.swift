// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4 spike (branch spike/chromium-oop, never merged): functional checks of out-of-process Chromium, run inside the staged
// app. DEBUG only; it runs only with a stage home under `/.wt/d4-spike/build/stage/` and `WSURF_D4_DRIVER` set, loads only
// the loopback fixture in `WSURF_D4_FIXTURE`, and ends the app through its own quit. It is not a measurement harness (that
// is the PerfTour); it proves that things work and records what it saw in `<stage home>/d4/driver.log`.
#if DEBUG
import AppKit
import CefKit
import Darwin
import ImageIO
import MachO
import UniformTypeIdentifiers

@MainActor
enum D4SpikeDriver {
    private static var home: URL!
    private static var output: URL!
    private static var base = "http://127.0.0.1:8791"
    private static var coordinator: AppCoordinator!

    static func runIfRequested(coordinator: AppCoordinator) {
        let environment = ProcessInfo.processInfo.environment
        guard StageMode.isActive, let script = environment["WSURF_D4_DRIVER"], !script.isEmpty, let home = StageMode.home,
              home.path.contains("/.wt/d4-spike/build/stage/") else { return }
        Self.home = home
        Self.coordinator = coordinator
        base = environment["WSURF_D4_FIXTURE"] ?? base
        output = home.appendingPathComponent("d4", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if script == "manual" {
            // The owner's checks (IME, VoiceOver, camera prompt): open the fixtures, then leave the app to the person.
            log("driver manual: start, pid \(getpid()), OOP \(ChromiumOOP.isEnabled)")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                let pages = (environment["WSURF_D4_PAGES"] ?? "ime.html,ax.html").split(separator: ",").map(String.init)
                for page in pages {
                    let target = page.hasPrefix("https://") ? URL(string: page)! : url(page)
                    _ = coordinator.browser.newTab(url: target, engine: .chromium)
                }
                log("driver manual: opened \(pages)")
            }
            return
        }
        let deadline = Double(environment["WSURF_D4_DEADLINE"] ?? "") ?? 240
        log("driver \(script): start, pid \(getpid()), OOP \(ChromiumOOP.isEnabled), deadline \(Int(deadline)) s")
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
            Self.log("deadline reached: quitting")
            Self.requestQuit()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline + 30) {
            Self.log("quit did not finish: exit(3)")
            exit(3)
        }
        Task { @MainActor in
            // The app is not brought forward: the person may be using this Mac.
            try? await Task.sleep(for: .seconds(1.5))
            switch script {
            case "day1": await day1()
            case "frames": await frames()
            case "input": await input()
            case "kill": await kill()
            case "ime": await ime()
            case "imekeys": await imeKeys()
            case "select": await selectMenu()
            case "latency": await latency()
            #if DEBUG
            case "ax": await accessibility()
            #endif
            default: log("unknown script \(script)")
            }
            log("driver \(script): done")
            try? await Task.sleep(for: .milliseconds(300))
            requestQuit()
        }
    }

    // MARK: Scripts

    /// Day 1: a windowless browser in the service loads a page; the helpers are the service's children; CEF never loads here.
    private static func day1() async {
        var browser: BrowserModel { coordinator.browser }
        log("before: CEF loaded in WSurf \(cefLoadedHere()), WSurf children \(childNames(of: getpid()))")
        if ProcessInfo.processInfo.environment["WSURF_D4_WARM"] == "webkit" {
            // K3 attribution: is the first Chromium tab's gap the window's first-tab cost (the same for a WebKit tab)?
            let warmStarted = ContinuousClock.now
            let warmWatch = GapWatch()
            let warm = browser.newTab(url: url("plain/2.html"), engine: .webKit)
            let warmSync = exactMs(ContinuousClock.now - warmStarted)
            let warmLoaded = await waitLoaded(warm, timeout: 60)
            let warmGap = warmWatch.stop()
            log("first WebKit tab (warm-up): loaded \(warmLoaded) in \((ContinuousClock.now - warmStarted).milliseconds) ms, newTab itself \(String(format: "%.1f", warmSync)) ms, longest main-thread gap \(Int(warmGap)) ms (ended \(Int(warmWatch.longestEndedAtMs)) ms after)")
            try? await Task.sleep(for: .seconds(1))
        }
        let started = ContinuousClock.now
        let watch = GapWatch()
        let tab = browser.newTab(url: url("plain/1.html"), engine: .chromium)
        let newTabSync = exactMs(ContinuousClock.now - started)
        let loaded = await waitLoaded(tab, timeout: 60)
        let gap = watch.stop()
        log("first Chromium tab: loaded \(loaded) in \((ContinuousClock.now - started).milliseconds) ms, newTab itself \(String(format: "%.1f", newTabSync)) ms, longest main-thread gap \(Int(gap)) ms (ended \(Int(watch.longestEndedAtMs)) ms after the tab was asked for, uptime \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))), engine \(String(describing: tab.loadedEngine)), title \(tab.liveView?.title ?? "nil"), url \(tab.liveView?.url?.absoluteString ?? "nil")")
        await processReport()
        if let page = tab.liveView {
            let title = try? await page.evaluateJavaScript("document.title + ' / ' + navigator.userAgent")
            log("CDP evaluate: \(String(describing: title))")
            if let chromium = page.chromium {
                do {
                    let image = try await chromium.capture(rect: nil, width: 480, fastEncoding: true)
                    log("CDP capture: \(Int(image.size.width))x\(Int(image.size.height))")
                } catch {
                    log("CDP capture failed: \(error)")
                }
            }
        }
        try? await Task.sleep(for: .seconds(1))
        captureWindow("day1-loaded")
        await serviceStatistics()
        let second = browser.newTab(url: url("plain/2.html"), engine: .chromium)
        let secondStart = ContinuousClock.now
        let secondWatch = GapWatch()
        let secondLoaded = await waitLoaded(second, timeout: 60)
        log("second Chromium tab: loaded \(secondLoaded) in \((ContinuousClock.now - secondStart).milliseconds) ms, longest gap \(Int(secondWatch.stop())) ms")
        try? await Task.sleep(for: .seconds(1))
        log("after the second tab and 1 s: \(ChromiumCaptureStats.summary)")
        captureWindow("day1-second")
        browser.close(second)
        browser.close(tab)
        try? await Task.sleep(for: .seconds(2))
        log("after closing both: service \(ChromiumRemote.shared.servicePID) alive \(isAlive(ChromiumRemote.shared.servicePID)), live browsers \(ChromiumRemote.shared.liveBrowserCount)")
        let pid = ChromiumRemote.shared.servicePID
        let linger = Double(ProcessInfo.processInfo.environment["WSURF_OOP_LINGER"] ?? "") ?? 60
        try? await Task.sleep(for: .seconds(linger + 3))
        log("after the linger (\(Int(linger)) s): service \(pid) alive \(isAlive(pid)), its children \(pid > 0 ? childNames(of: pid) : [])")
        log("end: CEF loaded in WSurf \(cefLoadedHere())\(cefImagePath().map { " from \($0)" } ?? "")")
        log("end: WSurf's helper executables: \(childPaths(of: getpid()))")
    }

    /// Day 2-3: frames at the display rate, resize, switching between two Chromium tabs, the band over the page.
    private static func frames() async {
        var browser: BrowserModel { coordinator.browser }
        // WSURF_D4_ENGINE=webkit: the same switches between two WebKit tabs, the floor of WSurf's own switch (K1 context).
        let engine: BrowserEngine = ProcessInfo.processInfo.environment["WSURF_D4_ENGINE"] == "webkit" ? .webKit : .chromium
        log("frames: engine \(engine)")
        let red = browser.newTab(url: url("color.html?c=d0021b"), engine: engine)
        _ = await waitLoaded(red, timeout: 60)
        let blue = browser.newTab(url: url("color.html?c=1e5bd7"), engine: engine)
        _ = await waitLoaded(blue, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        captureWindow("frames-blue")
        if let page = blue.liveView?.chromium {
            log("layers: \(layerReport(page))")
        }
        _ = await ChromiumRemote.shared.statistics(reset: true)
        for number in 0..<6 {
            let target = number.isMultiple(of: 2) ? red : blue
            let watch = GapWatch()
            let cpu = mainThreadCPU()
            browser.activate(target)
            try? await Task.sleep(for: .milliseconds(400))
            log("switch \(number) to \(number.isMultiple(of: 2) ? "red" : "blue"): main CPU 400 ms \(String(format: "%.1f", mainThreadCPU() - cpu)) ms, longest gap \(Int(watch.stop())) ms; \(ChromiumCaptureStats.summary)")
            try? await Task.sleep(for: .milliseconds(300))
            captureWindow("frames-switch-\(number)")
        }
        try? await Task.sleep(for: .seconds(1.5))
        log("after the 6 switches and 1.5 s: \(ChromiumCaptureStats.summary)")
        // Glass over the page: the command palette's glass must sample the page under it (red, then blue).
        for (name, tab) in [("red", red), ("blue", blue)] {
            browser.activate(tab)
            try? await Task.sleep(for: .milliseconds(500))
            coordinator.openPalette()
            try? await Task.sleep(for: .milliseconds(900))
            captureWindow("frames-glass-\(name)")
            coordinator.closePalette()
            try? await Task.sleep(for: .milliseconds(300))
        }
        let animated = browser.newTab(url: url("animated.html"), engine: .chromium)
        _ = await waitLoaded(animated, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        _ = await ChromiumRemote.shared.statistics(reset: true)
        _ = RemoteFrameSinks.shared.report(reset: true)
        try? await Task.sleep(for: .seconds(3))
        await serviceStatistics()
        if let fps = try? await animated.liveView?.evaluateJavaScript("JSON.stringify(window.__frames ? window.__frames() : null)") {
            log("page rAF report: \(String(describing: fps))")
        }
        if let window = coordinator.nativeWindow {
            let frame = window.frame
            for (index, size) in [CGSize(width: 900, height: 640), CGSize(width: 1300, height: 860), frame.size].enumerated() {
                window.setFrame(NSRect(origin: frame.origin, size: size), display: true)
                try? await Task.sleep(for: .milliseconds(700))
                captureWindow("frames-resize-\(index)")
            }
        }
        for tab in [animated, blue, red] {
            browser.close(tab)
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// Day 4: clicks, typing and scrolling reach the page, delivered as in-app events to WSurf's own window (nothing is
    /// posted through the window server).
    private static func input() async {
        var browser: BrowserModel { coordinator.browser }
        let tab = browser.newTab(url: url("input.html"), engine: .chromium)
        _ = await waitLoaded(tab, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        guard let page = tab.liveView, let chromium = page.chromium, let window = chromium.window else {
            log("input: no page")
            return
        }
        // The field sits at the page's top-left (input.html): click into it.
        let fieldInPage = CGPoint(x: 120, y: 40)
        let inWindow = chromium.convert(fieldInPage, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        for character in "wsurf" {
            let text = String(character)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: text,
                                                charactersIgnoringModifiers: text, isARepeat: false, keyCode: Self.keyCode(character)) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let value = try? await page.evaluateJavaScript("JSON.stringify({value: document.querySelector('input').value, keys: window.__keys || []})")
        log("input: after typing \(String(describing: value)); first responder is page \(window.firstResponder === chromium)")
        captureWindow("input-typed")
        // The cursor comes back from CEF as an event: over the field it is the I-beam.
        if let move = NSEvent.mouseEvent(with: .mouseMoved, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            chromium.mouseMoved(with: move)
        }
        try? await Task.sleep(for: .milliseconds(400))
        log("input: cursor over the field is the I-beam \(chromium.remoteCursor == NSCursor.iBeam)")
        // A WSurf shortcut while the page has focus: Cmd-T opens the new-tab palette.
        if let commandT = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: "t", charactersIgnoringModifiers: "t",
                                           isARepeat: false, keyCode: 17) {
            NSApp.sendEvent(commandT)
        }
        try? await Task.sleep(for: .milliseconds(500))
        log("input: Cmd-T with the page focused opened the palette \(coordinator.isPaletteOpen)")
        coordinator.closePalette()
        try? await Task.sleep(for: .milliseconds(300))
        await serviceStatistics()
        browser.close(tab)
        try? await Task.sleep(for: .seconds(1))
        await scroll()
    }

    /// K4 with a real sample: 200 keystrokes typed into a field (in-app events, 50 ms apart), each one's input leg (WSurf's send to
    /// the service's `send_key_event`) and the output leg of the frames they cause (CEF's paint callback to WSurf's commit).
    private static func latency() async {
        var browser: BrowserModel { coordinator.browser }
        let tab = browser.newTab(url: url("input.html"), engine: .chromium)
        _ = await waitLoaded(tab, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        guard let page = tab.liveView, let chromium = page.chromium, let window = chromium.window else {
            log("latency: no page")
            return
        }
        let inWindow = chromium.convert(CGPoint(x: 120, y: 40), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        _ = await ChromiumRemote.shared.statistics(reset: true)
        _ = RemoteFrameSinks.shared.report(reset: true)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for index in 0..<200 {
            let text = String(letters[index % letters.count])
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: text,
                                                charactersIgnoringModifiers: text, isARepeat: false, keyCode: Self.keyCode(letters[index % letters.count])) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(800))
        let value = try? await page.evaluateJavaScript("document.querySelector('input').value.length")
        log("latency: typed 200 keys; the field holds \(String(describing: value)) characters")
        await serviceStatistics()
        browser.close(tab)
        try? await Task.sleep(for: .seconds(1))
    }

    /// Wheel events reach the page: ten 40-point steps down on a long article. The event is made in process from a CGEvent
    /// (never posted) and handed to the page view.
    private static func scroll() async {
        var browser: BrowserModel { coordinator.browser }
        let tab = browser.newTab(url: url("article.html"), engine: .chromium)
        _ = await waitLoaded(tab, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        guard let page = tab.liveView, let chromium = page.chromium, chromium.window != nil else {
            log("scroll: no page")
            return
        }
        let before = try? await page.evaluateJavaScript("window.scrollY")
        // NSEvent(cgEvent:) has no window, so its locationInWindow is the screen point: aim it at the page's centre.
        let target = chromium.convert(CGPoint(x: chromium.bounds.midX, y: chromium.bounds.midY), to: nil)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        for _ in 0..<10 {
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0) else { continue }
            wheel.location = CGPoint(x: target.x, y: screenHeight - target.y)
            if let event = NSEvent(cgEvent: wheel) {
                chromium.scrollWheel(with: event)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(600))
        let after = try? await page.evaluateJavaScript("window.scrollY")
        log("scroll: window.scrollY before \(String(describing: before)), after ten wheel steps \(String(describing: after))")
        captureWindow("scroll-after")
        browser.close(tab)
        try? await Task.sleep(for: .seconds(1))
    }

    /// Day 5, the plumbing only (no system input method is driven): marked text, its bounds coming back for the candidate
    /// window, commit, and cancel, through the page's own NSTextInputClient calls, in each of the three fields.
    private static func ime() async {
        var browser: BrowserModel { coordinator.browser }
        let tab = browser.newTab(url: url("ime.html"), engine: .chromium)
        _ = await waitLoaded(tab, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        guard let page = tab.liveView, let chromium = page.chromium, let window = chromium.window else {
            log("ime: no page")
            return
        }
        for (name, selector) in [("search box", "#s"), ("contenteditable", "#e"), ("textarea", "#t")] {
            // Focus the field with a click at its centre (in-app events), as a person would.
            let rectJSON = try? await page.evaluateJavaScript(
                "JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])(document.querySelector('\(selector)').getBoundingClientRect()))")
            guard let text = rectJSON as? String, let data = text.data(using: .utf8),
                  let point = try? JSONSerialization.jsonObject(with: data) as? [Double], point.count == 2 else {
                log("ime \(name): field not found")
                continue
            }
            let inWindow = chromium.convert(CGPoint(x: point[0], y: point[1]), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            let before = chromium.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            chromium.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(400))
            let marked = chromium.hasMarkedText()
            let during = chromium.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            let caret = chromium.convert(window.convertFromScreen(during), from: nil)
            chromium.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(300))
            chromium.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(200))
            chromium.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(300))
            let value = try? await page.evaluateJavaScript(
                "(e => e.value !== undefined ? e.value : e.textContent)(document.querySelector('\(selector)')) + ' | ' + document.getElementById('log').textContent")
            log("ime \(name): marked \(marked); firstRect before \(before.integral), during \(during.integral) (field centre at \(Int(point[0])),\(Int(point[1])) in the page, the marked text's first character at \(caret.integral) in the page); value after commit and cancel: \(String(describing: value))")
        }
        // WSurf-side paste (`WSURF_OOP_PASTE=host`), the service's half only: the text goes as WSurf sends it after reading
        // the pasteboard. The general pasteboard is the person's: agents neither read nor write it.
        if let remote = chromium.remote {
            let message = remote.message(CefRemote.Op.edit)
            message.set(CefRemote.Key.kind, "pasteText")
            message.set(CefRemote.Key.text, " pasted")
            remote.sendInput(message)
            try? await Task.sleep(for: .milliseconds(400))
            let value = try? await page.evaluateJavaScript("document.querySelector('#t').value")
            log("ime: WSurf-side paste into the textarea (service half): value \(String(describing: value))")
        }
        captureWindow("ime-after")
        browser.close(tab)
        try? await Task.sleep(for: .seconds(1))
    }

    /// Day 5, the keystroke path of IME, the one real typing with an input method takes: the input method's calls come inside
    /// keyDown, and the page gets them after `interpretKeyEvents` (the deferred model of cefclient and Chromium's own view). The
    /// calls are played by the driver; no system input method is driven.
    private static func imeKeys() async {
        var browser: BrowserModel { coordinator.browser }
        let tab = browser.newTab(url: url("ime.html"), engine: .chromium)
        _ = await waitLoaded(tab, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        guard let page = tab.liveView, let chromium = page.chromium, let window = chromium.window else {
            log("imekeys: no page")
            return
        }
        let rectJSON = try? await page.evaluateJavaScript(
            "JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2])(document.querySelector('#t').getBoundingClientRect()))")
        guard let text = rectJSON as? String, let data = text.data(using: .utf8),
              let point = try? JSONSerialization.jsonObject(with: data) as? [Double], point.count == 2 else {
            log("imekeys: textarea not found")
            return
        }
        let inWindow = chromium.convert(CGPoint(x: point[0], y: point[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let none = NSRange(location: NSNotFound, length: 0)
        func key(_ code: UInt16, _ characters: String, _ interpret: () -> Void) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            chromium.simulateKeyDownForIMECheck(event, interpret: interpret)
        }
        func state(_ label: String) async {
            try? await Task.sleep(for: .milliseconds(350))
            let value = try? await page.evaluateJavaScript(
                "JSON.stringify(document.querySelector('#t').value) + ' | ' + document.getElementById('log').textContent")
            log("imekeys \(label): marked \(chromium.hasMarkedText()); value | events (newest first): \(String(describing: value))")
        }
        func reset() async {
            _ = try? await page.evaluateJavaScript(
                "document.querySelector('#t').value = ''; seen.length = 0; document.getElementById('log').textContent = ''; 0")
            try? await Task.sleep(for: .milliseconds(200))
        }
        // a. Compose, update, then Return commits inside the keystroke.
        key(45, "n") { chromium.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        key(34, "i") { chromium.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        await state("a1 after n, i (composition に)")
        key(36, "\r") { chromium.insertText("に", replacementRange: none) }
        await state("a2 after Return (commit に)")
        // b. Compose, then the input method calls unmarkText inside the keystroke (finish).
        await reset()
        key(40, "k") { chromium.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        key(36, "\r") { chromium.unmarkText() }
        await state("b after unmarkText in a keystroke (finish か)")
        // c. Compose, then an empty setMarkedText inside the keystroke (Escape cancels).
        await reset()
        key(1, "s") { chromium.setMarkedText("さ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        key(53, "\u{1b}") { chromium.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none) }
        await state("c after an empty setMarkedText in a keystroke (cancel さ)")
        // d. Space converts the whole composition (selected), then Return commits it.
        await reset()
        key(45, "n") { chromium.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: none) }
        key(49, " ") { chromium.setMarkedText("日本", selectedRange: NSRange(location: 0, length: 2), replacementRange: none) }
        await state("d1 after Space (composition 日本, selected)")
        key(36, "\r") { chromium.insertText("日本", replacementRange: none) }
        await state("d2 after Return (commit 日本)")
        // e. Commit and a new composition in one keystroke (typing on after a conversion): commit 日本, then compose か.
        await reset()
        key(45, "n") { chromium.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: none) }
        key(40, "k") {
            chromium.insertText("日本", replacementRange: none)
            chromium.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        }
        await state("e after commit-and-compose in one keystroke (日本, then composition k)")
        key(36, "\r") { chromium.insertText("k", replacementRange: none) }
        await state("e2 after Return (commit k)")
        // f. A plain key with no input method: KEYDOWN and CHAR.
        await reset()
        key(0, "a") { chromium.insertText("a", replacementRange: none) }
        await state("f plain a")
        // g. Real keystrokes (AppKit's own interpretKeyEvents): Left moves the caret and inserts nothing, so Left then b gives "ba".
        let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        for (code, characters, flags) in [(UInt16(123), left, NSEvent.ModifierFlags([.numericPad, .function])), (UInt16(11), "b", [])] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        await state("g after the real keys Left, b (expect \"ba\")")
        captureWindow("imekeys-after")
        browser.close(tab)
        try? await Task.sleep(for: .seconds(1))
    }

    /// Decision 3 (windowless changes): a `<select>` opens as Chromium's own popup widget; it must show at the menu, follow the
    /// arrow keys and Return, and close.
    private static func selectMenu() async {
        var browser: BrowserModel { coordinator.browser }
        let tab = browser.newTab(url: url("select.html"), engine: .chromium)
        _ = await waitLoaded(tab, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        guard let page = tab.liveView, let chromium = page.chromium, let window = chromium.window else {
            log("select: no page")
            return
        }
        let rectJSON = try? await page.evaluateJavaScript(
            "JSON.stringify((r => [r.x + r.width / 2, r.y + r.height / 2, r.x, r.bottom])(document.querySelector('#s').getBoundingClientRect()))")
        guard let text = rectJSON as? String, let data = text.data(using: .utf8),
              let box = try? JSONSerialization.jsonObject(with: data) as? [Double], box.count == 4 else {
            log("select: menu not found")
            return
        }
        let inWindow = chromium.convert(CGPoint(x: box[0], y: box[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        try? await Task.sleep(for: .milliseconds(700))
        log("select: menu at page \(Int(box[2])),\(Int(box[3])) (left, bottom); popup events \(RemoteFrameSinks.shared.popupReport())")
        captureWindow("select-open")
        for (code, name) in [(UInt16(125), "Down"), (UInt16(125), "Down"), (UInt16(36), "Return")] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let characters = code == 36 ? "\r" : String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: code == 36 ? [] : [.numericPad, .function],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                isARepeat: false, keyCode: code) {
                    window.sendEvent(event)
                }
            }
            log("select: key \(name) sent")
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let value = try? await page.evaluateJavaScript("document.querySelector('#s').value + ' / ' + document.getElementById('out').textContent")
        log("select: after Down, Down, Return: \(String(describing: value)); popup events \(RemoteFrameSinks.shared.popupReport())")
        captureWindow("select-closed")
        browser.close(tab)
        try? await Task.sleep(for: .seconds(1))
    }

    /// Day 8-9: the service ends as a crash would; WSurf must not stall or crash, and the tab must come back.
    private static func kill() async {
        var browser: BrowserModel { coordinator.browser }
        let tab = browser.newTab(url: url("plain/3.html"), engine: .chromium)
        _ = await waitLoaded(tab, timeout: 60)
        try? await Task.sleep(for: .seconds(1))
        let pid = ChromiumRemote.shared.servicePID
        let watch = GapWatch()
        ChromiumRemote.shared.abortService()
        try? await Task.sleep(for: .seconds(2))
        log("after the service's abort: longest WSurf main-thread gap \(Int(watch.stop())) ms, old service \(pid) alive \(isAlive(pid)), interruptions \(ChromiumRemote.shared.interruptions)")
        let reloaded = await waitLoaded(tab, timeout: 30)
        log("tab reloaded \(reloaded), new service \(ChromiumRemote.shared.servicePID), url \(tab.liveView?.url?.absoluteString ?? "nil")")
        captureWindow("kill-recovered")
        browser.close(tab)
        try? await Task.sleep(for: .seconds(1))
    }

    #if DEBUG
    /// Day 8-9: CEF's tree reaches WSurf's mirror (run with `WSURF_OOP_AX=1`; VoiceOver is the owner's pass). Press on a
    /// button and on a link goes back to the page as a click.
    private static func accessibility() async {
        var browser: BrowserModel { coordinator.browser }
        let tab = browser.newTab(url: url("ax.html"), engine: .chromium)
        _ = await waitLoaded(tab, timeout: 60)
        try? await Task.sleep(for: .seconds(2))
        guard let page = tab.liveView, let chromium = page.chromium else {
            log("ax: no page")
            return
        }
        guard let mirror = chromium.accessibilityMirror else {
            log("ax: no mirror (wantsAccessibility \(ChromiumRemote.shared.wantsAccessibility))")
            return
        }
        log("ax: \(mirror.summary())")
        func describe(_ element: Any, depth: Int) -> [String] {
            guard depth < 8, let element = element as? NSAccessibilityElement else { return [] }
            let line = String(repeating: "  ", count: depth) + "\(element.accessibilityRole()?.rawValue ?? "?") title '\(element.accessibilityTitle() ?? "")' value '\(String(describing: element.accessibilityValue() ?? ""))' frame \(element.accessibilityFrame().integral)"
            return [line] + (element.accessibilityChildren() ?? []).flatMap { describe($0, depth: depth + 1) }
        }
        let tree = (chromium.accessibilityChildren() ?? []).flatMap { describe($0, depth: 0) }
        log("ax: tree as VoiceOver sees it (\(tree.count) elements):\n" + tree.prefix(40).joined(separator: "\n"))
        func find(_ role: NSAccessibility.Role, in element: Any) -> ChromiumAccessibilityElement? {
            guard let element = element as? ChromiumAccessibilityElement else { return nil }
            if element.accessibilityRole() == role { return element }
            for child in element.accessibilityChildren() ?? [] {
                if let found = find(role, in: child) { return found }
            }
            return nil
        }
        let root: Any = chromium.accessibilityChildren()?.first ?? NSNull()
        if let button = find(.button, in: root) {
            log("ax: press button '\(button.accessibilityTitle() ?? "")': \(button.accessibilityPerformPress())")
            try? await Task.sleep(for: .milliseconds(800))
            let title = try? await page.evaluateJavaScript("document.title")
            log("ax: document.title after Press: \(String(describing: title))")
        } else {
            log("ax: no button in the mirror")
        }
        if let link = find(.link, in: root) {
            log("ax: press link '\(link.accessibilityTitle() ?? "")' url \(link.accessibilityURL()?.absoluteString ?? "nil"): \(link.accessibilityPerformPress())")
            try? await Task.sleep(for: .seconds(2))
            log("ax: url after Press: \(tab.liveView?.url?.absoluteString ?? "nil")")
        } else {
            log("ax: no link in the mirror")
        }
        log("ax: after navigation: \(chromium.accessibilityMirror?.summary() ?? "no mirror")")
        captureWindow("ax-after")
        browser.close(tab)
        try? await Task.sleep(for: .seconds(1))
    }
    #endif

    // MARK: Helpers

    /// Where the page's layer sits: the view chain, the hosted layer and, in presentation "xpc", the frames shown.
    private static func layerReport(_ page: ChromiumPage) -> String {
        var chain: [String] = []
        var view: NSView? = page
        while let current = view, chain.count < 12 {
            chain.append("\(type(of: current))\(current.isHidden ? "(hidden)" : "")\(current.alphaValue < 1 ? "(alpha \(current.alphaValue))" : "")")
            view = current.superview
        }
        let layer = page.layer
        let hosted = page.remoteLayer.map {
            "\(type(of: $0)) frame \($0.frame.integral) attached \($0.superlayer === layer) hidden \($0.isHidden) opacity \($0.opacity)"
        } ?? "nil"
        return "page frame \(page.frame.integral) in window \(page.window != nil), layer \(layer != nil), sublayers "
            + "\(layer?.sublayers?.count ?? -1), hosted \(hosted), xpc frames shown \(RemoteFrameSinks.shared.framesShown), "
            + "chain \(chain.joined(separator: " < "))"
    }

    private static func url(_ path: String) -> URL {
        URL(string: base + "/" + path)!
    }

    /// A duration in milliseconds with its fraction (`Duration.milliseconds` here is a whole number).
    private static func exactMs(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func waitLoaded(_ tab: BrowserTab, timeout: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let page = tab.liveView, let url = page.url, !url.absoluteString.isEmpty, !page.isLoading, !tab.isLoading, !tab.hasNoPageYet {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func processReport() async {
        let remote = ChromiumRemote.shared
        let pid = remote.servicePID
        log("service pid \(pid), hello round trip \(remote.helloRoundTripMs) ms, CEF start in service \(remote.cefStartMs) ms")
        guard pid > 0 else { return }
        log("service parent \(parent(of: pid)), service responsible pid \(responsible(for: pid)) (WSurf is \(getpid()))")
        log("service children: \(childNames(of: pid))")
        log("WSurf children: \(childNames(of: getpid()))")
        log("CEF loaded in WSurf: \(cefLoadedHere())")
    }

    private static func serviceStatistics() async {
        guard let stats = await ChromiumRemote.shared.statistics() else {
            log("service statistics: no answer")
            return
        }
        var lines = ["service statistics: cefStartMs \(stats.double("cefStartMs")), frameRate \(stats.int("frameRate")), external \(stats.bool("externalBeginFrames"))"]
        for browser in stats.messages(CefRemote.Key.stats) {
            let keys = ["readyMs", "firstFrameMs", "presented", "accelerated", "cpuFrames", "droppedParked", "ringOverruns", "ringSize",
                        "fpsLast2s", "outputLegMs.p50", "outputLegMs.p95", "outputLegMs.max", "blitMs.p50", "blitMs.p95",
                        "inputLegMs.n", "inputLegMs.p50", "inputLegMs.p95", "hidden", "parked"]
            lines.append("  browser \(browser.browser): " + keys.map { "\($0) \(String(format: "%.2f", browser.double($0)))" }.joined(separator: ", "))
        }
        lines.append(RemoteFrameSinks.shared.report())
        log(lines.joined(separator: "\n"))
    }

    private static func cefLoadedHere() -> Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            return String(cString: name).contains("Chromium Embedded Framework")
        }
    }

    /// Where the CEF framework in this process was loaded from, if it was.
    private static func cefImagePath() -> String? {
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if path.contains("Chromium Embedded Framework") {
                return path
            }
        }
        return nil
    }

    /// The executable paths of a process's children, with the app's bundle path cut to "<app>".
    private static func childPaths(of pid: pid_t) -> [String] {
        var pids = [pid_t](repeating: 0, count: 512)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let app = Bundle.main.bundlePath
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.map { child in
            var path = [CChar](repeating: 0, count: 4096)
            proc_pidpath(child, &path, 4096)
            return String(cString: path).replacingOccurrences(of: app, with: "<app>")
        }.sorted()
    }

    private static func childNames(of pid: pid_t) -> [String] {
        var pids = [pid_t](repeating: 0, count: 512)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.map { child in
            var name = [CChar](repeating: 0, count: 256)
            proc_name(child, &name, 256)
            return "\(String(cString: name))(\(child))"
        }.sorted()
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 ? pid_t(info.pbi_ppid) : -1
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsible(for pid: pid_t) -> pid_t {
        responsibleFunction?(pid) ?? -1
    }

    private static func mainThreadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
    }

    private static func keyCode(_ character: Character) -> UInt16 {
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
                                          "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
                                          "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
        return codes[character] ?? 0
    }

    /// This app's own window, by window number (no Screen Recording grant is needed for a window of the calling process).
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    private static func captureWindow(_ name: String) {
        guard let window = coordinator.nativeWindow, let createImage,
              let image = createImage(.null, 8, UInt32(window.windowNumber), 1 | 16)?.takeRetainedValue() else {
            log("capture \(name): unavailable")
            return
        }
        let file = output.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        log("capture \(name): \(image.width)x\(image.height) -> \(file.lastPathComponent)")
    }

    private nonisolated static func log(_ line: String) {
        let text = String(format: "%.3f ", Date().timeIntervalSince1970) + line + "\n"
        guard let home = StageMode.home else { return }
        let file = home.appendingPathComponent("d4/driver.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }

    private nonisolated static func requestQuit() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// The longest gap between 2 ms ticks on the main thread while it runs: a stall the person would see.
@MainActor
private final class GapWatch {
    private var timer: Timer?
    private var last = DispatchTime.now().uptimeNanoseconds
    private var longest = 0.0
    /// When the longest gap ended, in milliseconds after the watch started.
    private(set) var longestEndedAtMs = 0.0
    private let started = DispatchTime.now().uptimeNanoseconds

    init() {
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let gap = Double(now - last) / 1e6
        if gap > longest {
            longest = gap
            longestEndedAtMs = Double(now - started) / 1e6
        }
        last = now
    }

    func stop() -> Double {
        tick()
        timer?.invalidate()
        timer = nil
        return longest
    }
}
#endif
