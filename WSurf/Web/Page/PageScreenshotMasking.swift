// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics
import Foundation

/// A capture that blacks out filled sensitive fields instead of being refused. Only the Developer tier asks for one: it types
/// test secrets itself, so a page with a filled password field is the normal case there, not a reason to return nothing.
///
/// The boxes are measured in the page, in viewport CSS pixels, and painted over the bitmap that is returned, so the page is
/// never touched. A full-page image starts at the document's origin, so for it each box is also taken shifted by the page's
/// scroll (a fixed box lands where it is in the viewport, any other where it is in the document): both places are covered. A filled field inside a frame is covered by the whole frame, and a box that cannot be measured refuses the
/// capture. The pixels of page text that merely echo a secret are not covered: read the page, where the registered value is
/// hidden by `MCPSecretScrubber`.
struct ScreenshotMasking: Sendable {
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
              const filled = Array.from(R.walk(document.body)).filter(el => R.isSensitiveField(el) && (el.value || el.isContentEditable && el.textContent));
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
