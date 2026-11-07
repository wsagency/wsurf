// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI
import WebKit

extension BrowserTab {
    func holdPageColorUntilLoaded() {
        guard isShowingRealPage else {
            clearPageColor()
            return
        }
        holdsPageColor = true
    }

    func releasePageColorHold() {
        holdsPageColor = false
    }

    func refreshPageColor(from page: BrowserPage, onShow: Bool = false) {
        guard isShowingRealPage else {
            clearPageColor()
            return
        }
        guard provisionalNavigation == nil, !holdsPageColor else { return }
        guard hasPresentedContent else {
            setPageColor(nil)
            return
        }
        if onShow {
            measureBandOnShow()
        } else {
            measureBandUnderBar()
        }
    }

    func measureBandUnderBar() {
        guard !isClosed, isMaterialised, isShowingRealPage, hasPresentedContent, !holdsPageColor, page.window != nil,
              page.bounds.height > 0 else { return }
        guard !isMeasuringBand else {
            // The first presentation can still contain the old/blank frame.
            // Keep the didFinish request instead of dropping it behind that
            // early snapshot.
            needsBandRemeasure = true
            return
        }
        isMeasuringBand = true
        needsBandRemeasure = false
        let requested = BandKey(url: urlString, isDark: isDarkAppearance)
        let requestedURL = requested.url
        let bandFraction = Theme.topBarHeight / page.bounds.height
        let view = page
        bandMeasureCount += 1
        Task { [weak self] in
            let image = try? await view.capture(width: 48, afterScreenUpdates: true, fastEncoding: true)
            guard let self else { return }
            isMeasuringBand = false
            let shouldRemeasure = needsBandRemeasure
            needsBandRemeasure = false
            defer {
                if shouldRemeasure {
                    measureBandUnderBar()
                }
            }
            guard !isClosed, isMaterialised, page === view, !view.isClosed, urlString == requestedURL, isDarkAppearance == requested.isDark,
                  provisionalNavigation == nil, hasPresentedContent, !holdsPageColor,
                  let image,
                  let average = Self.averageOfTopBand(of: image, fraction: bandFraction)
            else { return }
            bandMeasuredKey = requested
            setPageColor(average)
        }
    }

    // MARK: - Band colour of a Chromium tab that comes to the front

    /// The address and light or dark mode a band colour was measured for.
    struct BandKey: Equatable {
        let url: String
        let isDark: Bool
    }

    /// How long a Chromium tab is in front before its band is looked at. Past the switch itself, so the capture (Chromium's UI-thread
    /// half runs on the main thread, ~80 ms for a viewport) is not in the window of the switch or of the leaving tab's preview.
    static let bandSettleDelay: Duration = .milliseconds(700)
    /// The same for a tab that has just woken. The saved scroll offset is put back by a script that tries for up to 1.2 s
    /// (`restoreScrollScript`), and a look in the middle of that would see the page still on its way. This waits it out; there is
    /// no completion of the script to wait on instead.
    static let bandWakeDelay: Duration = .milliseconds(1300)

    var isDarkAppearance: Bool {
        liveView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Whether the colour this tab holds was measured for its address and for the current light or dark mode.
    var holdsCurrentBandColour: Bool {
        pageColor != nil && bandMeasuredKey == BandKey(url: urlString, isDark: isDarkAppearance)
    }

    /// Whether coming to the front will make this tab take a band capture in the switch itself: a Chromium tab with no colour for its
    /// address and mode, that is not waking (a woken tab looks after its scroll is back) and is not already measuring.
    var willCaptureBandOnShow: Bool {
        liveView?.chromium != nil && !isDeferred && !bandWakePending && !isMeasuringBand && !holdsCurrentBandColour
    }

    /// At most one Chromium capture per switch: the leaving tab keeps the preview it has when the arriving tab captures its band in the
    /// switch, or when the leaving tab's own band capture is still running. A tab with no preview yet takes one.
    static func skipsPreview(isChromium: Bool, hasPreview: Bool, arrivingCaptures: Bool, isMeasuringBand: Bool) -> Bool {
        isChromium && hasPreview && (arrivingCaptures || isMeasuringBand)
    }

    /// What a tab coming to the front asks of its band. WebKit measures as it always did. A Chromium tab that holds the colour for its
    /// address and mode shows it and looks once more after the switch has settled (`scheduleBandRecheck`). One that does not keeps
    /// the colour it had (the theme's own if it never had one) and captures its band now, in place of that look. A woken tab waits for
    /// its own look (`navigationFinished`).
    func measureBandOnShow() {
        guard liveView?.chromium != nil else {
            measureBandUnderBar()
            return
        }
        guard !bandWakePending else { return }
        if holdsCurrentBandColour {
            scheduleBandRecheck()
        } else if !isMeasuringBand {
            cancelBandRecheck()
            measureBandUnderBar()
        }
    }

    /// One look at the band after `delay`. A look that is already waiting is kept, unless `restart` moves it: a woken tab restarts
    /// it once the saved scroll offset has been asked for, so it never sees a page still at the top.
    func scheduleBandRecheck(restart: Bool = false, after delay: Duration = BrowserTab.bandSettleDelay) {
        if bandRecheck != nil, !restart {
            return
        }
        bandRecheck?.cancel()
        bandRecheck = Task { [weak self, bandClock] in
            try? await bandClock.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            bandRecheck = nil
            bandWakePending = false
            // Changes the band only when the colour differs (`setPageColor`).
            measureBandUnderBar()
        }
    }

    func cancelBandRecheck() {
        bandRecheck?.cancel()
        bandRecheck = nil
        bandWakePending = false
    }

    /// Light or dark mode reached the page's view. A Chromium tab that is on screen looks again once the page has taken it. A tab on the
    /// shelf (parked, hidden, behind the front tab) is left to its next show, which finds the colour is for the other mode and captures
    /// then; looking in every tab at once would put all those captures in one turn.
    func appearanceDidChange() {
        guard liveView?.chromium != nil, isInFront, page.window != nil, isShowingRealPage, !bandWakePending else { return }
        scheduleBandRecheck(restart: true)
    }

    func webViewDidBecomeVisible() {
        refreshCanvas(from: page)
        refreshPageColor(from: page, onShow: true)
    }

    static func averageOfTopBand(of image: NSImage, fraction: CGFloat) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.height > 0
        else { return nil }
        let bandHeight = max(1, Int(CGFloat(cg.height) * min(max(fraction, 0), 1)))
        guard let band = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: bandHeight)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(band, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    fileprivate func clearPageColor() {
        setPageColor(nil)
    }

    private func setPageColor(_ color: NSColor?) {
        guard !Self.perceptuallyEqual(pageColor, color) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageColor = color
        }
    }

    private static func perceptuallyEqual(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            return (a == nil) && (b == nil)
        }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}
