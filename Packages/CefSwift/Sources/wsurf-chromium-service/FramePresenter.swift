// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-7: one browser's frames on their way to WSurf. CEF hands over a pooled IOSurface and takes it back when the paint callback
// returns, so each frame is copied on the GPU into one of a few IOSurfaces this service owns (the ring), and that copy goes to
// WSurf's frames connection (`IOSurfaceCreateXPCObject`). WSurf puts it in a layer from its own frames queue (ChromiumFrameSink),
// so its main thread does nothing per frame.
//
// Memory: a surface is about 17 MB at a full-screen size. The ring is built by the first frame and is FREED while the browser is
// hidden (`hidden`): the spike kept up to 4 of them per tab, hidden tabs included. WSurf's layer keeps the last frame on screen
// by holding its own reference to the surface it was sent, so freeing the ring costs the page nothing.
//
// Everything runs on the main thread, which is CEF's UI thread (the paint callbacks are called there).

import CefKit
import CoreGraphics
import Foundation
import IOSurface
import Metal

@MainActor
final class FramePresenter {
    enum Element {
        case view, popup
    }

    /// Copies per element (`CefRemote.frameRingSize`, which the tests read too).
    private static let ringSize = CefRemote.frameRingSize

    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let queue: MTLCommandQueue? = device?.makeCommandQueue()

    private struct Slot {
        let surface: IOSurfaceRef
        let texture: MTLTexture
        let width: Int
        let height: Int
        let format: OSType
    }

    private let browser: Int64
    private var ring: [Slot] = []
    private var popupRing: [Slot] = []
    /// The copies last sent: not written again while they may be on screen.
    private var shown: IOSurfaceRef?
    private var popupShown: IOSurfaceRef?
    private var popupVisible = false
    private var popupRect = CGRect.zero

    /// The page is not shown to the person but still visible to itself: frames are dropped (`RemoteBrowser.setVisibility`).
    var parked = false

    /// `was_hidden(true)`: CEF sends no frames, and the ring is freed with everything in it.
    var hidden = false {
        didSet {
            guard hidden, !oldValue else { return }
            freeRing()
        }
    }

    private(set) var framesSent = 0
    private(set) var acceleratedFrames = 0
    private(set) var cpuFrames = 0
    private(set) var framesDropped = 0
    /// Frames written into a surface the render server may still have been reading (every copy was in use): `acquire`.
    private(set) var ringOverwrites = 0
    /// Accelerated frames whose CEF surface carried a colour-space tag (copied to the ring surface) and that carried none.
    private(set) var taggedSources = 0
    private(set) var untaggedSources = 0
    private var loggedUnknownFormat = false

    init(browser: Int64) {
        self.browser = browser
    }

    /// How many surfaces the ring holds now (the popup's too): what `debug.stats` reports and the tests read.
    var ringSurfaces: Int { ring.count + popupRing.count }

    /// Gives every copy back. WSurf's layer keeps what it was last sent.
    func freeRing() {
        ring.removeAll()
        popupRing.removeAll()
        shown = nil
        popupShown = nil
    }

    /// With nobody to send to, nothing is copied and no ring is built.
    private var shouldSend: Bool {
        !hidden && !parked && ServiceHost.shared.hasFramesConnection
    }

    /// The counts `debug.stats` reports for this browser.
    func statistics(into message: CefRemoteMessage) {
        message.set(CefRemote.Key.ringSurfaces, ringSurfaces)
        message.set(CefRemote.Key.popupRingSurfaces, popupRing.count)
        message.set(CefRemote.Key.ringOverwrites, ringOverwrites)
        message.set(CefRemote.Key.colourTagged, taggedSources)
        message.set(CefRemote.Key.colourUntagged, untaggedSources)
        message.set(CefRemote.Key.framesSent, framesSent)
        message.set(CefRemote.Key.acceleratedFrames, acceleratedFrames)
        message.set(CefRemote.Key.cpuFrames, cpuFrames)
        message.set(CefRemote.Key.framesDropped, framesDropped)
    }

    // MARK: Frames

    /// `on_accelerated_paint`. `entry`: mach nanoseconds when CEF's callback was entered.
    func present(surface source: IOSurfaceRef, element: Element, entry: UInt64) {
        acceleratedFrames += 1
        guard shouldSend, element == .view || popupVisible else {
            framesDropped += 1
            return
        }
        let width = IOSurfaceGetWidth(source)
        let height = IOSurfaceGetHeight(source)
        let format = IOSurfaceGetPixelFormat(source)
        if Self.metalFormat(format) == nil, !loggedUnknownFormat {
            loggedUnknownFormat = true
            note("browser \(browser): frames dropped, unsupported pixel format \(format)")
        }
        guard let queue = Self.queue, let device = Self.device, let pixelFormat = Self.metalFormat(format),
              let slot = acquire(element: element, width: width, height: height, format: format, device: device),
              let sourceTexture = Self.texture(device: device, surface: source, width: width, height: height, format: pixelFormat,
                                               usage: .shaderRead),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else {
            // CEF's own surface is never sent: it is overwritten as soon as this callback returns.
            framesDropped += 1
            return
        }
        blit.copy(from: sourceTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: slot.texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        // CEF reuses its surface once this callback returns, so the copy must have read it by then.
        commands.waitUntilCompleted()
        // Chromium tags its surfaces with a colour space: the copy carries the same tag, or WSurf's layer would show it unmatched.
        if let tag = IOSurfaceCopyValue(source, kIOSurfaceColorSpace) {
            IOSurfaceSetValue(slot.surface, kIOSurfaceColorSpace, tag)
            taggedSources += 1
        } else {
            untaggedSources += 1
        }
        send(slot.surface, element: element, entry: entry)
    }

    /// `on_paint`, the CPU path: BGRA rows, top-left origin.
    func present(pixels: UnsafeRawPointer, width: Int, height: Int, element: Element, entry: UInt64) {
        cpuFrames += 1
        guard shouldSend, element == .view || popupVisible else {
            framesDropped += 1
            return
        }
        guard let device = Self.device, let slot = acquire(element: element, width: width, height: height, format: Self.bgra, device: device)
        else {
            framesDropped += 1
            return
        }
        guard IOSurfaceLock(slot.surface, [], nil) == kIOReturnSuccess else {
            framesDropped += 1
            return
        }
        let destination = IOSurfaceGetBaseAddress(slot.surface)
        let destinationRow = IOSurfaceGetBytesPerRow(slot.surface)
        for row in 0..<height {
            memcpy(destination + row * destinationRow, pixels + row * width * 4, width * 4)
        }
        IOSurfaceUnlock(slot.surface, [], nil)
        // `on_paint` gives sRGB pixels.
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB), let list = srgb.copyPropertyList() {
            IOSurfaceSetValue(slot.surface, kIOSurfaceColorSpace, list)
        }
        send(slot.surface, element: element, entry: entry)
    }

    private func send(_ surface: IOSurfaceRef, element: Element, entry: UInt64) {
        switch element {
        case .view: shown = surface
        case .popup: popupShown = surface
        }
        framesSent += 1
        ServiceHost.shared.sendFrame(browser: browser, surface: surface, popup: element == .popup, entry: entry)
    }

    // MARK: Popup (a `<select>` list: CEF paints it as a second element)

    func setPopup(visible: Bool) {
        popupVisible = visible
        if !visible {
            popupRect = .zero
            popupRing.removeAll()
            popupShown = nil
        }
        ServiceHost.shared.sendPopup(browser: browser, visible: visible, rect: popupRect)
    }

    /// `rect` is in view points, top-left origin, as CEF gives it.
    func setPopup(rect: CGRect) {
        popupRect = rect
        ServiceHost.shared.sendPopup(browser: browser, visible: popupVisible, rect: rect)
    }

    // MARK: The ring

    private func acquire(element: Element, width: Int, height: Int, format: OSType, device: MTLDevice) -> Slot? {
        var slots = element == .view ? ring : popupRing
        let current = element == .view ? shown : popupShown
        slots.removeAll { ($0.width != width || $0.height != height || $0.format != format) && $0.surface !== current }
        var slot = slots.first { $0.surface !== current && !IOSurfaceIsInUse($0.surface) }
        if slot == nil, slots.count < Self.ringSize, let made = Self.makeSlot(device: device, width: width, height: height, format: format) {
            slots.append(made)
            slot = made
        }
        if slot == nil {
            // Every copy is still in use (or the ring cannot grow): the first one in allocation order (not send order) that is
            // not the one last sent is written again, possibly while the render server reads it. Dropping the frame instead
            // could leave a still page stale. Counted (`ringOverwrites`).
            slot = slots.first { $0.surface !== current }
            if slot != nil { ringOverwrites += 1 }
        }
        if element == .view {
            ring = slots
        } else {
            popupRing = slots
        }
        return slot
    }

    private static let bgra: OSType = 0x4247_5241  // 'BGRA'
    private static let rgba: OSType = 0x5247_4241  // 'RGBA'

    private static func metalFormat(_ format: OSType) -> MTLPixelFormat? {
        switch format {
        case bgra: .bgra8Unorm
        case rgba: .rgba8Unorm
        default: nil
        }
    }

    private static func makeSlot(device: MTLDevice, width: Int, height: Int, format: OSType) -> Slot? {
        guard let pixelFormat = metalFormat(format) else { return nil }
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow, kIOSurfacePixelFormat: format,
            kIOSurfaceAllocSize: IOSurfaceAlignProperty(kIOSurfaceAllocSize, bytesPerRow * height),
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary),
              let texture = texture(device: device, surface: surface, width: width, height: height, format: pixelFormat,
                                    usage: [.shaderRead, .shaderWrite, .renderTarget])
        else { return nil }
        return Slot(surface: surface, texture: texture, width: width, height: height, format: format)
    }

    private static func texture(device: MTLDevice, surface: IOSurfaceRef, width: Int, height: Int, format: MTLPixelFormat,
                                usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }
}
