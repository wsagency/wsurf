// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CoreGraphics
import Foundation
import WebKit

/// A capture that blacks out filled sensitive fields instead of being refused. Only the Developer tier asks for one: it types
/// test secrets itself, so a page with a filled password field is the normal case there, not a reason to return nothing.
///
/// The boxes are measured in the page, in viewport CSS pixels, and painted over the bitmap that is returned, so the page is
/// never touched. A full-page image starts at the document's origin, so for it each box is also taken shifted by the page's
/// scroll (a fixed box lands where it is in the viewport, any other where it is in the document), and both are covered. A
/// filled field inside a frame is covered by the whole frame, and a box that cannot be measured refuses the capture. The
/// pixels of page text that merely echo a secret are not covered: read the page, where the registered value is hidden by
/// `MCPSecretScrubber`.
struct ScreenshotMasking: Sendable {
    struct FrameEvidence: Equatable {
        let documents: [[String]]
        let revision: UInt64

        var addresses: [String] {
            documents.compactMap(\.last)
        }
    }

    struct CaptureEvidence: Equatable {
        let inspected: FrameEvidence
        let native: FrameEvidence
    }

    @MainActor
    static func nativeFrameRevision(in view: BrowserPage) -> UInt64 {
        view.chromium?.devTools.screenshotFrameRevision ?? view.webKitFrameRevision
    }

    /// Only return pixels when the engine accounts for every child document inspected by the masking runtime.
    @MainActor
    static func frameEvidence(_ probe: [String: Any], in view: BrowserPage) async -> CaptureEvidence? {
        guard probe["uninspectableFrame"] as? Bool == false, let documents = probe["frames"] as? [[String]],
              let revision = (probe["frameRevision"] as? NSNumber)?.uint64Value,
              let proof = probe["frameProof"] as? String,
              documents.allSatisfy({ $0.count == 3 })
        else { return nil }
        let inspected = FrameEvidence(documents: documents, revision: revision)
        let native: FrameEvidence?
        if let webKit = view.webKit {
            native = await webKitEvidence(in: view, webKit: webKit, proof: proof, count: documents.count)
        } else if let chromium = view.chromium {
            native = try? await chromium.devTools.screenshotFrameEvidence()
        } else {
            return nil
        }
        guard let native, native.documents.count == documents.count else { return nil }
        let addresses = inspected.addresses.compactMap(URL.init(string:)).map(frameAddress).sorted()
        let nativeAddresses = native.addresses.compactMap(URL.init(string:)).map(frameAddress).sorted()
        guard addresses.count == documents.count, addresses == nativeAddresses else { return nil }
        return CaptureEvidence(inspected: inspected, native: native)
    }

    @MainActor
    private static func webKitEvidence(in view: BrowserPage, webKit: WKWebView, proof: String, count: Int) async -> FrameEvidence? {
        let revision = view.webKitFrameRevision
        guard let frames = await webKit.screenshotChildFrames(), frames.count == count else { return nil }
        var documents: [[String]] = []
        for frame in frames {
            // Require this exact native document to have finished registration and to bear the isolated world's
            // proof from the field traversal. An address can match while it is still loading or belongs to a sibling.
            let script = """
                if (document.__wsurfScreenshotProof !== proof) return null;
                return [globalThis.__wsurfNativeFrameNonce, document.URL];
                """
            guard let document = try? await view.callAsyncJavaScript(
                script, arguments: ["proof": proof], in: BrowserFrame(webKit: frame), contentWorld: PageAutomationGuard.world
            ) as? [String], document.count == 2,
                let target = PageFrameRegistry.shared.target(document[0], in: view),
                PageFrameRegistry.shared.isCurrent(target, in: view)
            else { return nil }
            documents.append(document)
        }
        guard view.webKitFrameRevision == revision else { return nil }
        guard Set(documents.compactMap(\.first)).count == count else { return nil }
        return FrameEvidence(documents: documents.sorted { $0[0] < $1[0] }, revision: revision)
    }

    private static func frameAddress(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// Refs of fields the connection typed a secret into, covered even when they do not look sensitive. They count only while
    /// the page still shows `documentID`, the document those refs were issued for.
    var secretRefs: Set<Int> = []
    var documentID: String?
    /// The image is a full page, drawn from the document's origin rather than the viewport's.
    var documentSpace = false

    /// Adds `masks` (boxes) and `unmaskable` to the probe's result. Runs inside the page runtime scope.
    var probeScript: String {
        let refs = secretRefs.sorted().map(String.init).joined(separator: ",")
        let document = documentID.flatMap(PageDriver.jsonString) ?? "null"
        return """
            {
              const filled = scan.filled;
              if (R.documentID === \(document)) {
                for (const ref of [\(refs)]) {
                  const el = window.__wsurfRefs[ref - 1];
                  if (el && el.isConnected && !filled.includes(el)) filled.push(el);
                }
              }
              const masks = [];
              let unmaskable = false;
              for (const el of filled) {
                if (!R.visible(el)) continue;
                let box = el, view = el.ownerDocument.defaultView;
                while (view && view !== window && view.frameElement) { box = view.frameElement; view = view.parent; }
                if (view !== window) { unmaskable = true; continue; }
                const r = box.getBoundingClientRect();
                if (![r.x, r.y, r.width, r.height].every(Number.isFinite)) { unmaskable = true; continue; }
                masks.push({ x: r.x, y: r.y, width: r.width, height: r.height });
                if (\(documentSpace) && (window.scrollX || window.scrollY)) {
                  masks.push({ x: r.x + window.scrollX, y: r.y + window.scrollY, width: r.width, height: r.height });
                }
              }
              out.masks = masks;
              out.unmaskable = unmaskable;
            }
            """
    }

    /// Whether a probe's boxes can be trusted: every filled field was measured.
    static func isMeasured(_ probe: [String: Any]) -> Bool {
        probe["unmaskable"] as? Bool == false && probe["masks"] is [[String: Any]]
    }

    static func masks(in probe: [String: Any]) -> [CGRect] {
        (probe["masks"] as? [[String: Any]] ?? []).compactMap { box in
            func number(_ key: String) -> CGFloat? {
                (box[key] as? NSNumber).map { CGFloat($0.doubleValue) }
            }
            guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height") else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// The same boxes, to half a pixel: a field that moved while the capture ran may not be where it was covered.
    static func held(_ before: [CGRect], _ after: [CGRect]) -> Bool {
        before.count == after.count
            && zip(before, after).allSatisfy {
                [$0.minX - $1.minX, $0.minY - $1.minY, $0.width - $1.width, $0.height - $1.height].allSatisfy { abs($0) <= 0.5 }
            }
    }

    /// `bitmap` with every box that falls inside `area` (the CSS rectangle the bitmap shows) painted black, or nil when the
    /// image cannot be redrawn.
    static func apply(_ masks: [CGRect], over area: CGRect, to bitmap: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard !masks.isEmpty else { return bitmap }
        guard let source = bitmap.cgImage, area.width > 0, area.height > 0,
            let context = CGContext(
                data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let scaleX = CGFloat(source.width) / area.width
        let scaleY = CGFloat(source.height) / area.height
        for mask in masks {
            // A little beyond the field, so antialiased edges and focus rings do not show it.
            let covered = mask.insetBy(dx: -2, dy: -2).intersection(area)
            guard !covered.isNull, !covered.isEmpty else { continue }
            // CoreGraphics counts rows from the bottom, the page from the top.
            context.fill(
                CGRect(
                    x: (covered.minX - area.minX) * scaleX, y: CGFloat(source.height) - (covered.maxY - area.minY) * scaleY,
                    width: covered.width * scaleX, height: covered.height * scaleY))
        }
        return context.makeImage().map(NSBitmapImageRep.init(cgImage:))
    }
}

private extension WKWebView {
    /// WebKit's frame tree also includes frames blocked from script access and frames in closed shadow roots.
    func screenshotChildFrames() async -> [WKFrameInfo]? {
        let selector = NSSelectorFromString("_frames:")
        guard responds(to: selector) else { return nil }
        typealias Fetch = @convention(c) (AnyObject, Selector, @escaping @convention(block) (NSObject?) -> Void) -> Void
        let fetch = unsafeBitCast(method(for: selector), to: Fetch.self)
        return await PageReply<[WKFrameInfo]>.awaiting(within: .seconds(2)) { gate in
            fetch(self, selector) { root in
                gate.finish(root.flatMap(Self.screenshotChildFrames))
            }
        }
    }

    private static func screenshotChildFrames(_ root: NSObject) -> [WKFrameInfo]? {
        let infoKey = "info"
        let childrenKey = "childFrames"
        guard root.responds(to: NSSelectorFromString(infoKey)),
              let main = root.value(forKey: infoKey) as? WKFrameInfo, main.isMainFrame,
              root.responds(to: NSSelectorFromString(childrenKey)),
              var pending = root.value(forKey: childrenKey) as? [NSObject] else { return nil }
        var frames: [WKFrameInfo] = []
        while let node = pending.popLast() {
            guard frames.count < 256, node.responds(to: NSSelectorFromString(infoKey)),
                  let frame = node.value(forKey: infoKey) as? WKFrameInfo, !frame.isMainFrame, frame.request.url != nil,
                  !frame.securityOrigin.protocol.isEmpty, node.responds(to: NSSelectorFromString(childrenKey)),
                  let children = node.value(forKey: childrenKey) as? [NSObject] else { return nil }
            frames.append(frame)
            pending.append(contentsOf: children)
        }
        return frames
    }
}
