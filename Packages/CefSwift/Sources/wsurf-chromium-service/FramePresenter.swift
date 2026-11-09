// D4 spike: puts a windowless browser's frames on screen in WSurf's window without WSurf's main thread doing anything per
// frame. Each frame CEF hands over is copied on the GPU into one of a few IOSurfaces this service owns (CEF takes its own
// surface back when the callback returns), and that copy becomes the contents of a layer tree published to WSurf through
// the public remote-layer API (CARemoteLayerClient here, `CALayer(remoteClientId:)` in WSurf).

import AppKit
import IOSurface
import Metal
import QuartzCore

@MainActor
final class FramePresenter {
    enum Element {
        case view, popup
    }

    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let queue: MTLCommandQueue? = device?.makeCommandQueue()
    /// Surfaces per element. Three cover the one shown, the one the render server may still read, and the one being written.
    private static let ringLimit = 4

    /// Presentation "remote" only: with XPC presentation WSurf sends no layer server port and there is no client.
    let client: CARemoteLayerClient?
    private let root = CALayer()
    private let content = CALayer()
    private let popup = CALayer()

    private struct Slot {
        let surface: IOSurfaceRef
        let texture: MTLTexture
        let width: Int
        let height: Int
        let format: OSType
    }

    private var ring: [Slot] = []
    private var popupRing: [Slot] = []
    private var shown: IOSurfaceRef?
    private var popupShown: IOSurfaceRef?
    private var sizeDIP = CGSize(width: 1, height: 1)
    private var scale: CGFloat = 2

    /// The page is not shown to the person (its view waits on WSurf's shelf) but is still visible to itself: frames are dropped
    /// here, and the next one after unparking comes from an invalidate.
    var parked = false
    /// `was_hidden(true)`: no frames come; the copies except the one on screen are freed.
    var hidden = false {
        didSet {
            guard hidden, !oldValue else { return }
            ring.removeAll { $0.surface !== shown }
            popupRing.removeAll { $0.surface !== popupShown }
        }
    }

    // Statistics for K4's output leg and the frame rate.
    private(set) var presented = 0
    private(set) var droppedParked = 0
    private(set) var ringOverruns = 0
    private(set) var cpuFrames = 0
    private(set) var acceleratedFrames = 0
    private var outputLegMs: [Double] = []
    private var blitMs: [Double] = []
    private var presentTimes: [Double] = []

    /// Presentation "xpc": each frame's surface goes to WSurf over XPC instead of into the remote layer tree.
    var sink: ((IOSurfaceRef, Element, UInt64) -> Void)?

    init(serverPort: mach_port_t, debugRoot: Bool = false) {
        client = serverPort != 0 ? CARemoteLayerClient(serverPort: serverPort) : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.anchorPoint = .zero
        root.isGeometryFlipped = true
        root.backgroundColor = debugRoot ? NSColor.systemPink.cgColor : NSColor.white.cgColor
        root.masksToBounds = true
        content.anchorPoint = .zero
        content.contentsGravity = .resize
        popup.anchorPoint = .zero
        popup.contentsGravity = .resize
        popup.isHidden = true
        root.addSublayer(content)
        root.addSublayer(popup)
        client?.layer = root
        CATransaction.commit()
        CATransaction.flush()
    }

    var clientID: UInt32 {
        client?.clientId ?? 0
    }

    func invalidate() {
        client?.layer = nil
        client?.invalidate()
        ring.removeAll()
        popupRing.removeAll()
        shown = nil
        popupShown = nil
    }

    func setGeometry(sizeDIP: CGSize, scale: CGFloat) {
        self.sizeDIP = CGSize(width: max(1, sizeDIP.width), height: max(1, sizeDIP.height))
        self.scale = max(1, scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: self.sizeDIP)
        content.frame = root.bounds
        for layer in [root, content, popup] {
            layer.contentsScale = self.scale
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    func setPopup(visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popup.isHidden = !visible
        if !visible {
            popup.contents = nil
            popupShown = nil
            popupRing.removeAll()
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    func setPopup(rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popup.frame = rect
        CATransaction.commit()
        CATransaction.flush()
    }

    /// `entry`: mach nanoseconds when CEF's callback was entered.
    func present(surface source: IOSurfaceRef, element: Element, entry: UInt64) {
        acceleratedFrames += 1
        guard !hidden else { return }
        guard !parked else {
            droppedParked += 1
            return
        }
        let width = IOSurfaceGetWidth(source)
        let height = IOSurfaceGetHeight(source)
        let format = IOSurfaceGetPixelFormat(source)
        guard let queue = Self.queue, let device = Self.device, let pixelFormat = Self.metalFormat(format),
              let slot = acquire(element: element, width: width, height: height, format: format, device: device),
              let sourceTexture = Self.texture(device: device, surface: source, width: width, height: height, format: pixelFormat,
                                               usage: .shaderRead),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else {
            // No GPU path: show CEF's surface itself. It can be overwritten while shown; the counter makes that visible.
            ringOverruns += 1
            show(source, element: element, entry: entry, blitDone: entry)
            return
        }
        blit.copy(from: sourceTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: slot.texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        // CEF reuses its surface once this callback returns, so the copy must have read it by then.
        commands.waitUntilCompleted()
        show(slot.surface, element: element, entry: entry, blitDone: Clock.nowNanoseconds)
    }

    /// The CPU path (`on_paint`): BGRA rows, top-left origin.
    func present(pixels: UnsafeRawPointer, width: Int, height: Int, element: Element, entry: UInt64) {
        cpuFrames += 1
        guard !hidden else { return }
        guard !parked else {
            droppedParked += 1
            return
        }
        guard let device = Self.device,
              let slot = acquire(element: element, width: width, height: height, format: Self.bgra, device: device)
        else { return }
        IOSurfaceLock(slot.surface, [], nil)
        let destination = IOSurfaceGetBaseAddress(slot.surface)
        let destinationRow = IOSurfaceGetBytesPerRow(slot.surface)
        for row in 0..<height {
            memcpy(destination + row * destinationRow, pixels + row * width * 4, width * 4)
        }
        IOSurfaceUnlock(slot.surface, [], nil)
        show(slot.surface, element: element, entry: entry, blitDone: Clock.nowNanoseconds)
    }

    private func show(_ surface: IOSurfaceRef, element: Element, entry: UInt64, blitDone: UInt64) {
        if let sink {
            switch element {
            case .view: shown = surface
            case .popup: popupShown = surface
            }
            sink(surface, element, entry)
            let done = Clock.nowNanoseconds
            presented += 1
            record(&blitMs, Double(blitDone &- entry) / 1e6)
            record(&outputLegMs, Double(done &- entry) / 1e6)
            record(&presentTimes, Double(done) / 1e9)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch element {
        case .view:
            content.contents = surface
            shown = surface
        case .popup:
            popup.contents = surface
            popupShown = surface
        }
        CATransaction.commit()
        CATransaction.flush()
        let done = Clock.nowNanoseconds
        presented += 1
        record(&blitMs, Double(blitDone &- entry) / 1e6)
        record(&outputLegMs, Double(done &- entry) / 1e6)
        record(&presentTimes, Double(done) / 1e9)
    }

    private func record(_ samples: inout [Double], _ value: Double) {
        if samples.count >= 4_000 {
            samples.removeFirst(1_000)
        }
        samples.append(value)
    }

    private func acquire(element: Element, width: Int, height: Int, format: OSType, device: MTLDevice) -> Slot? {
        var slots = element == .view ? ring : popupRing
        let current = element == .view ? shown : popupShown
        slots.removeAll { ($0.width != width || $0.height != height || $0.format != format) && $0.surface !== current }
        var slot = slots.first { $0.surface !== current && !IOSurfaceIsInUse($0.surface) }
        if slot == nil, slots.count < Self.ringLimit, let made = Self.makeSlot(device: device, width: width, height: height, format: format) {
            slots.append(made)
            slot = made
        }
        if slot == nil {
            // Every copy is still in use: overwrite the oldest that is not on screen.
            ringOverruns += 1
            slot = slots.first { $0.surface !== current && $0.width == width && $0.height == height }
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

    /// Statistics for the debug reply: counts, the output leg and the copy (ms percentiles), and the recent frame rate.
    func statistics(into message: CefRemoteMessageBuilder) {
        message.add("presented", Double(presented))
        message.add("accelerated", Double(acceleratedFrames))
        message.add("cpuFrames", Double(cpuFrames))
        message.add("droppedParked", Double(droppedParked))
        message.add("ringOverruns", Double(ringOverruns))
        message.add("ringSize", Double(ring.count))
        message.percentiles("outputLegMs", outputLegMs)
        message.percentiles("blitMs", blitMs)
        let now = Clock.nowSeconds
        let recent = presentTimes.filter { now - $0 <= 2 }
        message.add("fpsLast2s", Double(recent.count) / 2)
    }

    func resetStatistics() {
        outputLegMs.removeAll()
        blitMs.removeAll()
        presentTimes.removeAll()
    }
}
