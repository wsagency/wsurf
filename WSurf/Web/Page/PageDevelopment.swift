// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

/// What the current engine and page can do for an MCP development lease. Device axes are never reported as supported
/// without a measurement: Chromium verifies each profile after applying it and rolls back when the runtime did not honor it.
struct DevelopmentCapabilities {
    enum Support {
        case supported
        case limited(String)
        case unsupported(String)
    }

    let engine: String
    let viewport: Support
    let deviceAxes: [String: Support]
    let diagnostics: [String: Support]
}

extension BrowserPage {
    var developmentCapabilities: DevelopmentCapabilities {
        let axes = ["dpr", "touch", "mobile"]
        if chromium != nil {
            let verified = DevelopmentCapabilities.Support.limited("Applied through DevTools emulation and verified by measurement on every use.")
            return DevelopmentCapabilities(
                engine: "chromium", viewport: .supported,
                deviceAxes: Dictionary(uniqueKeysWithValues: axes.map { ($0, verified) }),
                diagnostics: [
                    "console": .limited("Main-frame page-world console calls and uncaught exceptions after capture starts."),
                    "network": .limited("Main-frame requests after capture starts: method, sanitized URL, status and timing only."),
                ])
        }
        let none = DevelopmentCapabilities.Support.unsupported("WebKit exposes no public override for this axis.")
        return DevelopmentCapabilities(
            engine: "webkit", viewport: .supported,
            deviceAxes: Dictionary(uniqueKeysWithValues: axes.map { ($0, none) }),
            diagnostics: [
                "console": .limited("console.log/info/warn/error/debug, uncaught errors and unhandled rejections of the current document, from a hook installed when capture starts."),
                "network": .limited("fetch and XMLHttpRequest of the current document only; fetch reports a URL only for a string argument and a method only for fetch(url) without an init; resource loads, WebSockets and workers are not observed."),
            ])
    }

    /// The main-frame document identity both engines already keep (Chromium loader id, WebKit frame-registry nonce).
    var mainDocumentID: String? {
        let id = chromium.map { $0.devTools.framesByID.values.first { $0.isMainFrame }?.documentID }
            ?? PageFrameRegistry.shared.mainFrame(in: self)?.documentID
        return id?.isEmpty == false ? id : nil
    }
}

extension BrowserPage {
    private static let emulationLocks = NSMapTable<BrowserPage, DevelopmentEmulationLock>.weakToStrongObjects()

    var emulationLock: DevelopmentEmulationLock {
        if let lock = Self.emulationLocks.object(forKey: self) { return lock }
        let lock = DevelopmentEmulationLock()
        Self.emulationLocks.setObject(lock, forKey: self)
        return lock
    }
}

struct DevelopmentViewportState {
    let size: CGSize
    /// Device-axis emulation (Chromium) is active in addition to the layout size.
    let device: Bool

    /// Compare-then-restore: clears only what this state applied, never a different size set since.
    @MainActor
    func remove(from owner: DevelopmentOwner) {
        guard let page = owner.page else { return }
        if page.developmentViewport == size { page.developmentViewport = nil }
        if device, let chromium = page.chromium {
            let lock = page.emulationLock
            Task {
                await lock.acquire()
                defer { lock.release() }
                await chromium.clearDeviceEmulation()
            }
        }
    }
}

struct MeasuredViewport: Equatable {
    let width: Int
    let height: Int
    let devicePixelRatio: Double
    let touch: Bool
    let visualWidth: Double
    let visualHeight: Double
}

enum DevelopmentViewportOutcome {
    case applied(MeasuredViewport)
    case invalid(String)
    case unsupported(String)
    /// The requested size was not obtained; layout was rolled back to normal.
    case missed(MeasuredViewport?, String)
    case stale
}

extension BrowserPage {
    func measureViewport() async -> MeasuredViewport? {
        let script = PageDriver.scripted(
            """
            return JSON.stringify({ w: innerWidth, h: innerHeight, dpr: devicePixelRatio,
              touch: 'ontouchstart' in window || navigator.maxTouchPoints > 0,
              vw: window.visualViewport ? visualViewport.width : innerWidth, vh: window.visualViewport ? visualViewport.height : innerHeight });
            """)
        guard let object = await PageDriver.evaluateJSON(script, in: self),
            let width = (object["w"] as? NSNumber)?.intValue, let height = (object["h"] as? NSNumber)?.intValue
        else { return nil }
        return MeasuredViewport(
            width: width, height: height, devicePixelRatio: (object["dpr"] as? NSNumber)?.doubleValue ?? 1,
            touch: object["touch"] as? Bool ?? false, visualWidth: (object["vw"] as? NSNumber)?.doubleValue ?? Double(width),
            visualHeight: (object["vh"] as? NSNumber)?.doubleValue ?? Double(height))
    }

    /// Lays the page out at `request` CSS pixels (and, for a device profile, applies Chromium device emulation), then measures
    /// the document's real `innerWidth`/`innerHeight`. Nothing is applied when validation or capability checks fail; a miss
    /// restores normal layout. Every suspension revalidates the lease before anything further is committed.
    func applyDevelopmentViewport(
        _ request: PageViewport.Request, profile: PageViewport.Profile?, owner: DevelopmentOwner, tab: BrowserTab
    ) async -> DevelopmentViewportOutcome {
        let device = profile?.deviceAxes == true
        let hostScale = Double(window?.backingScaleFactor ?? 1)
        switch PageViewport.validate(
            width: request.width, height: request.height, zoom: Double(pageZoom), scale: hostScale * (profile?.scale ?? 1))
        {
        case .failure(let failure): return .invalid(failure.message)
        case .success: break
        }
        if device, chromium == nil {
            return .unsupported("WebKit has no DPR, touch or mobile-viewport override, so device profiles are not applied and nothing was changed.")
        }
        // Every emulation change and cleanup of this page runs one at a time, in arrival order, so an old lease's cleanup
        // can never land after a newer lease applied its own, and each step revalidates the lease before mutating.
        await emulationLock.acquire()
        defer { emulationLock.release() }
        guard tab.isCurrent(owner) else { return .stale }
        // Switching from a device profile to a plain size clears the device axes first.
        if owner.viewport?.device == true, !device, let chromium {
            await chromium.clearDeviceEmulation()
            guard tab.isCurrent(owner) else { return .stale }
            owner.viewport = owner.viewport.map { DevelopmentViewportState(size: $0.size, device: false) }
        }
        if device, let chromium, let profile {
            do {
                try await chromium.setDeviceEmulation(width: request.width, height: request.height, scale: profile.scale)
            } catch {
                // A failed set clears every axis, including the ones a previous request of this lease applied.
                if tab.isCurrent(owner), let previous = owner.viewport, previous.device {
                    owner.viewport = DevelopmentViewportState(size: previous.size, device: false)
                }
                return .unsupported("Chromium rejected the device emulation: \(error.localizedDescription)")
            }
            guard tab.isCurrent(owner) else {
                await chromium.clearDeviceEmulation()
                return .stale
            }
        }
        let size = CGSize(width: request.width, height: request.height)
        developmentViewport = size
        owner.viewport = DevelopmentViewportState(size: size, device: device)
        var measured: MeasuredViewport?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            guard tab.isCurrent(owner) else { return .stale }
            measured = await measureViewport()
            guard tab.isCurrent(owner) else { return .stale }
            if let measured, measured.width == request.width, measured.height == request.height { break }
        }
        guard let measured, measured.width == request.width, measured.height == request.height else {
            rollBackViewport(owner)
            return .missed(measured, "The page did not reach the requested viewport; layout was restored.")
        }
        if device, let profile, measured.devicePixelRatio != profile.scale || !measured.touch {
            rollBackViewport(owner)
            return .unsupported(
                "The embedded runtime did not honor every device axis (measured devicePixelRatio \(measured.devicePixelRatio), touch \(measured.touch)); nothing was kept.")
        }
        return .applied(measured)
    }

    func rollBackViewport(_ owner: DevelopmentOwner) {
        owner.viewport?.remove(from: owner)
        owner.viewport = nil
    }
}

extension PageDriver {
    static func findElements(selector: String, offset: Int, limit: Int, in view: BrowserPage) async -> String {
        switch PageRuntime.validate(selector: selector) {
        case .success: break
        case .failure(.invalid): return "Invalid selector."
        case .failure(.empty), .failure(.tooLong):
            return "The selector must be 1 to \(PageRuntime.maxSelectorBytes) UTF-8 bytes."
        }
        guard let encoded = jsonString(selector) else { return "Invalid selector." }
        guard let object = await evaluateJSON(scripted("return JSON.stringify(R.findAll(\(encoded), \(offset), \(limit)));"), in: view) else {
            return "The page did not respond. Use findElements again after it finishes loading."
        }
        if let error = object["error"] as? String { return error }
        guard let id = object["observation"] as? String, let documentID = object["document"] as? String,
            let url = object["url"] as? String, let items = object["items"] as? [[String: Any]]
        else { return staleMessage }
        observations.setObject(
            PageObservation(id: id, documentID: documentID, url: url, refs: Set(items.compactMap { $0["r"] as? Int })), forKey: view)
        var result = object
        result["observation"] = nil
        return "ELEMENTS:\n\(compactJSON(result))\nobservationID: \(id)"
    }

    /// Inspection reads a ref registered by the latest `findElements` or `readPage`. It needs only a live, current
    /// observation; click/type/select keep their own stricter `matchesRef` check.
    static func inspectElement(ref: Int, in view: BrowserPage) async -> String {
        guard let prior = observation(in: view), prior.refs.contains(ref), expectedObservation == nil || expectedObservation == prior.id,
            await validateObservation(in: view)
        else { return staleMessage }
        guard let object = await evaluateJSON(scripted("return JSON.stringify(R.inspect(\(ref)));"), in: view) else {
            return "The page did not respond. Use findElements again."
        }
        if object["stale"] as? Bool == true { return staleMessage }
        return "ELEMENT:\n\(compactJSON(object))\nobservationID: \(prior.id)"
    }

    private static func compactJSON(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
