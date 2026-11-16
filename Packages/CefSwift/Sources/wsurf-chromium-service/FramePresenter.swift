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
// A live resize: every size Chromium paints would allocate a new ring (the exit gate measured 106 new surfaces for 120 sizes sent
// 16 ms apart, 2.4 MB each; about 18 MB each at 1300x860 @2x). A frame at a size other than the one being shown is only taken once
// that size has been stable for one frame interval (`settleInterval`), or when `maxWait` has passed since the last change was taken
// (a long drag still repaints, ten times a second at most). The frames before that are dropped: WSurf's layer keeps the old-size copy and
// shows it stretched, as it does between two frames. A repaint is asked for when the wait is over, so the final size always gets its
// frame. A size change after a quiet time is taken at once.
//
// Source textures: wrapping CEF's surface in a texture is most of the copy's CPU cost (595 of 1,000 us a frame). Chromium cycles a
// handful of surfaces, so a texture is kept per CEF surface (`sourceTextures`, keyed by `IOSurfaceGetID` and checked against the
// surface itself, its size and its format, since an ID can be reused once a surface is freed) and the command buffer does not retain
// what it uses. That is safe only because `present` waits for the copy before it returns: CEF takes its surface back then. The cache
// is capped (least recently used goes first), because a stale entry keeps a dropped surface alive (18 MB at 1300x860 @2x), and it is
// emptied with the size or format, with the ring (hidden, closed) and when the browser is parked. The popup's frames are not cached.
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

    /// A class: `lastSent` and the colour tag are written through the ring's arrays.
    private final class Slot {
        let surface: IOSurfaceRef
        let texture: MTLTexture
        let width: Int
        let height: Int
        let format: OSType
        /// When this copy was last sent (`sendSequence`); 0 while it never was.
        var lastSent: UInt64 = 0
        /// The colour-space tag written to `surface` last; the tag is written again only when CEF's differs.
        var colourTag: CFTypeRef?

        init(surface: IOSurfaceRef, texture: MTLTexture, width: Int, height: Int, format: OSType) {
            self.surface = surface
            self.texture = texture
            self.width = width
            self.height = height
            self.format = format
        }
    }

    /// Source textures kept at most (`sourceTextures`); the DEBUG `smallSourceCache` makes it 1.
    var sourceTextureLimit = CefRemote.sourceTextureLimit

    private let browser: Int64
    private var ring: [Slot] = []
    private var popupRing: [Slot] = []
    /// The copies last sent: not written again while they may be on screen.
    private var shown: IOSurfaceRef?
    private var popupShown: IOSurfaceRef?
    private var popupVisible = false
    /// Counts the frames sent: a copy's `lastSent`, so that a ring with every copy in use writes the least recently sent one.
    private var sendSequence: UInt64 = 0
    private var popupRect = CGRect.zero
    /// The view's CEF surfaces as textures, least recently used first, all of `sourceKey`'s size and format.
    private var sourceTextures: [(id: IOSurfaceID, texture: MTLTexture)] = []
    private var sourceKey: (width: Int, height: Int, format: OSType)?

    /// A size that differs from the one being shown is taken after it has been stable this long: one frame interval at the 30 frames a
    /// second the service paints at.
    static let settleInterval: TimeInterval = 1.0 / 30
    /// The longest a size that keeps changing waits for its frame.
    static let maxWait: TimeInterval = 0.1
    /// The pixel size of the last view frame taken; nil while there is none (the first frame is always taken).
    private var shownSize: (width: Int, height: Int)?
    /// The size of the dropped frames that wait, and when it was first seen.
    private var pendingSize: (width: Int, height: Int)?
    private var pendingSince: TimeInterval = 0
    /// When (system uptime) a frame of a size other than the previous one was last taken.
    private var lastSizeChange: TimeInterval = 0
    private var repaintScheduled = false
    /// Asks Chromium for a frame of the whole view (`RemoteBrowser.requestFrame`): after frames were dropped for their size.
    var repaint: (() -> Void)?

    /// The page is not shown to the person but still visible to itself: frames are dropped (`RemoteBrowser.setVisibility`).
    var parked = false {
        didSet {
            guard parked, !oldValue else { return }
            dropSourceTextures()
        }
    }

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
    /// Ring surfaces ever allocated (`debug.stats`): a size that keeps changing allocates new ones.
    private(set) var slotsMade = 0
    /// Accelerated frames whose CEF surface carried a colour-space tag (copied to the ring surface) and that carried none.
    private(set) var taggedSources = 0
    private(set) var untaggedSources = 0
    /// The ring surfaces that were overwritten while in use, by identity (`debug.stats`: which copies the fallback reaches).
    private var overwrittenSurfaces = Set<ObjectIdentifier>()
    private var loggedUnknownFormat = false

    init(browser: Int64) {
        self.browser = browser
    }

    /// How many surfaces the ring holds now (the popup's too): what `debug.stats` reports and the tests read.
    var ringSurfaces: Int { ring.count + popupRing.count }

    /// Gives every copy back. WSurf's layer keeps what it was last sent.
    func freeRing() {
        dropSourceTextures()
        ring.removeAll()
        popupRing.removeAll()
        overwrittenSurfaces.removeAll()
        shown = nil
        popupShown = nil
        shownSize = nil
        pendingSize = nil
    }

    private func dropSourceTextures() {
        sourceTextures.removeAll()
        sourceKey = nil
    }

    /// Whether a view frame of this size is taken now (see the top of the file); one that is not asks for its repaint when it may be.
    private func admitsSize(_ element: Element, width: Int, height: Int) -> Bool {
        guard element == .view else { return true }
        let size = (width: width, height: height)
        guard let current = shownSize, current != size else {
            shownSize = size
            pendingSize = nil
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        if pendingSize.map({ $0 != size }) ?? true {
            pendingSize = size
            pendingSince = now
        }
        let ready = min(pendingSince + Self.settleInterval, lastSizeChange + Self.maxWait)
        guard now < ready else {
            shownSize = size
            pendingSize = nil
            lastSizeChange = now
            return true
        }
        if !repaintScheduled {
            repaintScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(ready - now, 0.005)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.repaintScheduled = false
                    self?.repaint?()
                }
            }
        }
        return false
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
        message.set(CefRemote.Key.slotsMade, slotsMade)
        message.set(CefRemote.Key.sourceTextures, sourceTextures.count)
        let key = sourceKey
        message.set(CefRemote.Key.staleSourceTextures, sourceTextures.filter {
            $0.texture.width != key?.width || $0.texture.height != key?.height
                || $0.texture.iosurface.map { IOSurfaceGetPixelFormat($0) } != key?.format
        }.count)
        message.set(CefRemote.Key.overwrittenSlots, overwrittenSurfaces.count)
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
        guard admitsSize(element, width: width, height: height) else {
            framesDropped += 1
            return
        }
        if Self.metalFormat(format) == nil, !loggedUnknownFormat {
            loggedUnknownFormat = true
            note("browser \(browser): frames dropped, unsupported pixel format \(format)")
        }
        guard let queue = Self.queue, let device = Self.device, let pixelFormat = Self.metalFormat(format),
              let slot = acquire(element: element, width: width, height: height, format: format, device: device),
              let sourceTexture = cachedTexture(of: source, element: element, device: device, width: width, height: height,
                                                  format: format, metalFormat: pixelFormat),
              let commands = queue.makeCommandBufferWithUnretainedReferences(), let blit = commands.makeBlitCommandEncoder()
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
        // CEF reuses its surface once this callback returns, so the copy must have read it by then. The wait also makes the command
        // buffer's unretained references safe: the textures live in this frame's locals and the cache until it is over.
        commands.waitUntilCompleted()
        // Chromium tags its surfaces with a colour space: the copy carries the same tag, or WSurf's layer would show it unmatched.
        // The tag is written when it differs from the one the copy carries (the same one nearly always).
        if let tag = IOSurfaceCopyValue(source, kIOSurfaceColorSpace) {
            if slot.colourTag.map({ !CFEqual($0, tag) }) ?? true {
                IOSurfaceSetValue(slot.surface, kIOSurfaceColorSpace, tag)
                slot.colourTag = tag
            }
            taggedSources += 1
        } else {
            untaggedSources += 1
        }
        send(slot.surface, element: element, entry: entry)
    }

    /// CEF's surface as a texture: the view's are kept per surface (see the top of the file), the popup's are made for the frame.
    private func cachedTexture(of source: IOSurfaceRef, element: Element, device: MTLDevice, width: Int, height: Int, format: OSType,
                               metalFormat: MTLPixelFormat) -> MTLTexture? {
        guard element == .view else {
            return Self.texture(device: device, surface: source, width: width, height: height, format: metalFormat, usage: .shaderRead)
        }
        if let key = sourceKey, key.width != width || key.height != height || key.format != format {
            sourceTextures.removeAll()
        }
        sourceKey = (width, height, format)
        let id = IOSurfaceGetID(source)
        if let index = sourceTextures.firstIndex(where: { $0.id == id }) {
            let entry = sourceTextures.remove(at: index)
            if entry.texture.iosurface === source {
                sourceTextures.append(entry)
                return entry.texture
            }
        }
        guard let made = Self.texture(device: device, surface: source, width: width, height: height, format: metalFormat, usage: .shaderRead)
        else { return nil }
        sourceTextures.append((id, made))
        if sourceTextures.count > sourceTextureLimit {
            sourceTextures.removeFirst(sourceTextures.count - sourceTextureLimit)
        }
        return made
    }

    /// `on_paint`, the CPU path: BGRA rows, top-left origin.
    func present(pixels: UnsafeRawPointer, width: Int, height: Int, element: Element, entry: UInt64) {
        cpuFrames += 1
        guard shouldSend, element == .view || popupVisible else {
            framesDropped += 1
            return
        }
        guard admitsSize(element, width: width, height: height), let device = Self.device,
              let slot = acquire(element: element, width: width, height: height, format: Self.bgra, device: device)
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
            slot.colourTag = list
        }
        send(slot.surface, element: element, entry: entry)
    }

    private func send(_ surface: IOSurfaceRef, element: Element, entry: UInt64) {
        switch element {
        case .view: shown = surface
        case .popup: popupShown = surface
        }
        framesSent += 1
        sendSequence += 1
        let slot = ring.first { $0.surface === surface } ?? popupRing.first { $0.surface === surface }
        slot?.lastSent = sendSequence
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
        var slot = slots.filter { $0.surface !== current && !IOSurfaceIsInUse($0.surface) }.min { $0.lastSent < $1.lastSent }
        if slot == nil, slots.count < Self.ringSize, let made = Self.makeSlot(device: device, width: width, height: height, format: format) {
            slots.append(made)
            slot = made
            slotsMade += 1
        }
        if slot == nil {
            // Every copy is still in use (or the ring cannot grow): the LEAST RECENTLY SENT one that is not the one last sent is
            // written again, possibly while the render server reads it: the one the render server is most likely done with. (The
            // first in allocation order alternated between two copies and never touched the third.) Dropping the frame instead
            // could leave a still page stale. Counted (`ringOverwrites`).
            slot = slots.filter { $0.surface !== current }.min { $0.lastSent < $1.lastSent }
            if let slot {
                ringOverwrites += 1
                overwrittenSurfaces.insert(ObjectIdentifier(slot.surface))
            }
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
