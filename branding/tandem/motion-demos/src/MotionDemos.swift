// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1
//
// Illustrated product walkthrough renderer for wsurf.app/media/demos/.
// Renders deterministic 16:10 (960x600 @ 2x -> 1920x1200) PNG frames via SwiftUI ImageRenderer.
// Usage:
//   motion-demos <spaces|micro> frames <outdir> <fps> <startFrame> <endFrameExclusive>
//   motion-demos <spaces|micro> still  <out.png> <timeSeconds>

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tandem Day Palette (mint reserved strictly for the assistant, unused here)

enum Brand {
    static let ground = Color(hex: 0xF5F5F7)
    static let windowChrome = Color(hex: 0xF1F1F5)
    static let sidebar = Color(hex: 0xEAEAEE)
    static let surface = Color(hex: 0xFFFFFF)
    static let line = Color(hex: 0xD2D2D7)
    static let lineStrong = Color(hex: 0x86868B)
    static let ink = Color(hex: 0x1D1D1F)
    static let muted = Color(hex: 0x636366)
    static let tertiary = Color(hex: 0x8E8E93)
    static let accent = Color(hex: 0x3B1FD1)
    static let accentHover = Color(hex: 0x2E17A8)
    static let accentWash = Color(hex: 0x3B1FD1).opacity(0.09)
    static let accentSoft = Color(hex: 0x3B1FD1).opacity(0.16)

    // Standard macOS window control colors (not brand mint)
    static let trafficRed = Color(hex: 0xFF5F57)
    static let trafficYellow = Color(hex: 0xFEBC2E)
    static let trafficGreen = Color(hex: 0x28C840)
    static let trafficInactive = Color(hex: 0xD1D1D6)

    // Neutral material/editorial tones for synthetic demo pages (zero mint/teal)
    static let slate = Color(hex: 0x4A5568)
    static let stone = Color(hex: 0xD9D4CC)
    static let warmWood = Color(hex: 0xC6A987)
    static let aluminum = Color(hex: 0xC4C9D0)
    static let indigoSoft = Color(hex: 0xEBE8FB)
    static let amberInk = Color(hex: 0x9A5412)
    static let amberWash = Color(hex: 0xFBF1E4)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

// MARK: - Math & Easing

enum Anim {
    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        min(max(x, lo), hi)
    }

    static func progress(_ t: Double, start: Double, end: Double) -> Double {
        guard end > start else { return t >= end ? 1 : 0 }
        return clamp((t - start) / (end - start))
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
    }

    static func easeOutCubic(_ x: Double) -> Double {
        let u = clamp(x)
        return 1 - pow(1 - u, 3)
    }

    static func easeInOutCubic(_ x: Double) -> Double {
        let u = clamp(x)
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    static func easeOutQuint(_ x: Double) -> Double {
        let u = clamp(x)
        return 1 - pow(1 - u, 5)
    }

    static func easeInOutQuart(_ x: Double) -> Double {
        let u = clamp(x)
        return u < 0.5 ? 8 * u * u * u * u : 1 - pow(-2 * u + 2, 4) / 2
    }

    /// Critically-to-lightly damped spring settling smoothly from 0 -> 1 over normalized t in [0, 1].
    static func gentleSpring(_ x: Double) -> Double {
        let u = clamp(x)
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        // Damped sinusoid normalized so f(1) == 1 cleanly
        let raw: (Double) -> Double = { s in
            1.0 - exp(-7.2 * s) * (cos(6.4 * s) + 0.55 * sin(6.4 * s))
        }
        return raw(u) / raw(1.0)
    }

    static func quadBezier(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: Double) -> CGPoint {
        let u = CGFloat(clamp(t))
        let inv = 1 - u
        return CGPoint(
            x: inv * inv * p0.x + 2 * inv * u * c.x + u * u * p1.x,
            y: inv * inv * p0.y + 2 * inv * u * c.y + u * u * p1.y
        )
    }

    /// WSurf's authentic SidebarRevealPulse opacity (WSurf/UI/Sidebar/SidebarReveal.swift).
    static func sidebarRevealPulse(elapsed: Double) -> Double {
        let duration = 0.85
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let p = elapsed / duration
        return 0.26 * 0.5 * (1 - cos(4 * Double.pi * p))
    }

    /// Click press pulse: peaks at 1 during a quick 0.16s press.
    static func clickPulse(_ t: Double, at peakTime: Double) -> Double {
        let dt = t - peakTime
        guard dt >= -0.06, dt <= 0.16 else { return 0 }
        if dt < 0 {
            return easeOutCubic((dt + 0.06) / 0.06)
        }
        return 1 - easeOutCubic(dt / 0.16)
    }
}

// MARK: - Shared UI Building Blocks (Faithful to WSurf SwiftUI Chrome)

struct StageBackdrop: View {
    var body: some View {
        ZStack {
            Brand.ground
            // Ultra-subtle studio vignetting that blends naturally on #F5F5F7
            RadialGradient(
                colors: [Color.white.opacity(0.55), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 40,
                endRadius: 520
            )
        }
    }
}

struct TrafficLights: View {
    var active: Bool = true
    var size: CGFloat = 9
    var spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            Circle().fill(active ? Brand.trafficRed : Brand.trafficInactive).frame(width: size, height: size)
            Circle().fill(active ? Brand.trafficYellow : Brand.trafficInactive).frame(width: size, height: size)
            Circle().fill(active ? Brand.trafficGreen : Brand.trafficInactive).frame(width: size, height: size)
        }
        .overlay {
            HStack(spacing: spacing) {
                Circle().strokeBorder(Color.black.opacity(active ? 0.12 : 0.06), lineWidth: 0.5).frame(width: size, height: size)
                Circle().strokeBorder(Color.black.opacity(active ? 0.12 : 0.06), lineWidth: 0.5).frame(width: size, height: size)
                Circle().strokeBorder(Color.black.opacity(active ? 0.12 : 0.06), lineWidth: 0.5).frame(width: size, height: size)
            }
        }
    }
}

struct MacCursor: View {
    var position: CGPoint
    var opacity: Double = 1
    var pressed: Double = 0
    var ripple: Double = 0

    var body: some View {
        ZStack {
            if ripple > 0.01 {
                Circle()
                    .stroke(Brand.accent.opacity(0.45 * (1 - ripple)), lineWidth: 1.75)
                    .frame(width: 10 + 26 * ripple, height: 10 + 26 * ripple)
                    .position(position)
            }

            CursorArrowShape()
                .fill(Brand.ink)
                .overlay(
                    CursorArrowShape()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                )
                .frame(width: 15, height: 21)
                .shadow(color: Color.black.opacity(0.24), radius: 2.5, x: 0.5, y: 1.5)
                .scaleEffect(1 - 0.10 * pressed, anchor: .topLeading)
                .position(x: position.x + 7.5, y: position.y + 10.5)
        }
        .opacity(opacity)
    }
}

struct CursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 15.0
        let sy = rect.height / 21.0
        var p = Path()
        p.move(to: CGPoint(x: 0.6 * sx, y: 0.6 * sy))
        p.addLine(to: CGPoint(x: 0.6 * sx, y: 16.4 * sy))
        p.addLine(to: CGPoint(x: 4.4 * sx, y: 12.8 * sy))
        p.addLine(to: CGPoint(x: 7.4 * sx, y: 19.6 * sy))
        p.addLine(to: CGPoint(x: 9.7 * sx, y: 18.6 * sy))
        p.addLine(to: CGPoint(x: 6.7 * sx, y: 11.9 * sy))
        p.addLine(to: CGPoint(x: 12.2 * sx, y: 11.9 * sy))
        p.closeSubpath()
        return p
    }
}

struct MacTooltip: View {
    let text: String
    var shortcut: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.ink)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Brand.muted)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.97))
                .shadow(color: Color.black.opacity(0.14), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Brand.line, lineWidth: 0.6)
        )
    }
}

/// WSurf Space switcher dot (matches WSurf/UI/Sidebar/Spaces/SidebarSpaceSwitcher.swift).
struct SpaceDotView: View {
    let symbol: String
    let isCurrent: Bool
    var isShared: Bool = false
    var size: CGFloat = 22
    var pulseStrength: Double = 0

    var body: some View {
        ZStack {
            if pulseStrength > 0.01 {
                Circle()
                    .stroke(Brand.accent.opacity(0.55 * (1 - pulseStrength)), lineWidth: 1.5)
                    .frame(width: size + 10 * pulseStrength, height: size + 10 * pulseStrength)
            }

            Circle()
                .fill(isCurrent ? Brand.accent.opacity(0.14) : Color.clear)
                .frame(width: size, height: size)

            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(isCurrent ? Brand.accent : Brand.muted)

            if isShared {
                Image(systemName: "icloud.fill")
                    .font(.system(size: size * 0.30, weight: .semibold))
                    .foregroundStyle(isCurrent ? Brand.accent : Brand.muted)
                    .padding(1.2)
                    .background(Brand.sidebar, in: Circle())
                    .offset(x: size * 0.30, y: size * 0.28)
            }
        }
        .frame(width: size, height: size)
    }
}

struct TabSpec: Identifiable {
    let id: String
    let title: String
    let domain: String
    let symbol: String
}

/// Authentic WSurf sidebar tab row (WSurf/UI/Sidebar/SidebarTabRow.swift + SidebarRowInk.swift).
struct WSurfSidebarRow: View {
    let tab: TabSpec
    let isActive: Bool
    var isUnseen: Bool = false
    var isInMicro: Bool = false
    var microBadgeAccent: Double = 0
    var revealPulse: Double = 0
    var isHovered: Bool = false
    var compact: Bool = false

    var body: some View {
        let rowHeight: CGFloat = compact ? 27 : 30
        let corner: CGFloat = compact ? 7.5 : 8.5
        let iconSize: CGFloat = compact ? 11 : 12
        let fontSize: CGFloat = compact ? 10.5 : 11.8

        HStack(spacing: compact ? 6.5 : 7.5) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: tab.symbol)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(isActive ? Brand.ground : Brand.muted)
                    .frame(width: compact ? 15 : 16, height: compact ? 15 : 16)

                if isUnseen && !isActive {
                    Circle()
                        .fill(Brand.accent)
                        .frame(width: 5.5, height: 5.5)
                        .background(Circle().fill(Brand.sidebar).padding(-1.2))
                        .offset(x: 2.5, y: -1)
                }
            }

            Text(tab.title)
                .font(.system(size: fontSize, weight: (isActive || isUnseen) ? .semibold : .regular))
                .foregroundStyle(isActive ? Brand.ground : Brand.ink)
                .lineLimit(1)

            Spacer(minLength: 2)

            if isInMicro {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(
                        microBadgeAccent > 0.01
                            ? Brand.accent.opacity(0.65 + 0.35 * microBadgeAccent)
                            : Brand.muted
                    )
                    .scaleEffect(1 + 0.14 * microBadgeAccent)
            }
        }
        .padding(.horizontal, compact ? 7.5 : 9)
        .frame(height: rowHeight)
        .background {
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            if isActive {
                shape.fill(Brand.ink)
            } else if isHovered {
                shape.fill(Color.black.opacity(0.06))
            }
        }
        .overlay {
            if revealPulse > 0.004 {
                let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
                shape
                    .fill(Brand.accent.opacity(revealPulse))
                    .overlay(
                        shape.strokeBorder(Brand.accent.opacity(min(1, revealPulse * 2.6)), lineWidth: 1.5)
                    )
            }
        }
    }
}

/// Authentic WSurf toolbar AskSurface address pill (WSurf/UI/Ask/AskSurfaceRow.swift).
struct WSurfAddressPill: View {
    let domain: String
    var height: CGFloat = 30
    var compact: Bool = false
    var showsMicroOut: Bool = true
    var showsMicroBack: Bool = false
    var microHover: Double = 0
    var microPressed: Double = 0

    var body: some View {
        let corner: CGFloat = compact ? 8.5 : 10
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Brand.surface)
                .shadow(color: Color.black.opacity(0.045), radius: 2, y: 0.5)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.black.opacity(0.085), lineWidth: 0.6)

            HStack(spacing: compact ? 4 : 6) {
                if !compact {
                    Image(systemName: "mic")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.tertiary)
                        .frame(width: 18, height: 18)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4.5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: compact ? 8 : 8.5, weight: .medium))
                        .foregroundStyle(Brand.tertiary)

                    if !compact {
                        Text("WK")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Brand.muted)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }

                    Text(domain)
                        .font(.system(size: compact ? 10.5 : 11.5, weight: .regular))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: compact ? 3 : 4) {
                    if !compact {
                        Image(systemName: "pin")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Brand.tertiary)
                            .frame(width: 18, height: 18)
                    }

                    if showsMicroOut || showsMicroBack {
                        let sym = showsMicroBack ? "arrow.down.backward.square" : "arrow.up.forward.square"
                        ZStack {
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(
                                    microPressed > 0.01
                                        ? Brand.accent.opacity(0.22)
                                        : Brand.accent.opacity(0.12 * microHover)
                                )
                                .frame(width: compact ? 20 : 22, height: compact ? 20 : 22)

                            Image(systemName: sym)
                                .font(.system(size: compact ? 10 : 10.5, weight: .semibold))
                                .foregroundStyle(microHover > 0.15 ? Brand.accent : Brand.muted)
                                .scaleEffect(1 - 0.09 * microPressed)
                        }
                        .frame(width: compact ? 20 : 22, height: compact ? 20 : 22)
                    }

                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: compact ? 9 : 9.5, weight: .semibold))
                        .foregroundStyle(Brand.tertiary)
                        .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
                }
            }
            .padding(.horizontal, compact ? 6 : 7)
        }
        .frame(height: height)
    }
}

// MARK: - Synthetic Neutral Web Pages for Demo A (Shared Space — Field Guide)

struct SitePlanPage: View {
    var buttonHover: Double = 0
    var buttonPress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FIELD GUIDE · REV 4")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.accent)
                    Text("North Pavilion — Site Plan")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(Brand.ink)
                }
                Spacer()
                Text("Phase 2")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Brand.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Brand.ground, in: Capsule())
            }

            // Clean schematic architectural plan
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: 0xFAFAFC))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Brand.line.opacity(0.7), lineWidth: 0.7)
                    )

                // Grid + floorplan blueprint geometry
                GeometryReader { g in
                    let w = g.size.width
                    let h = g.size.height
                    Path { p in
                        for i in 1..<7 {
                            let x = w * CGFloat(i) / 7
                            p.move(to: CGPoint(x: x, y: 10))
                            p.addLine(to: CGPoint(x: x, y: h - 10))
                        }
                        for j in 1..<5 {
                            let y = h * CGFloat(j) / 5
                            p.move(to: CGPoint(x: 10, y: y))
                            p.addLine(to: CGPoint(x: w - 10, y: y))
                        }
                    }
                    .stroke(Color.black.opacity(0.045), lineWidth: 0.7)

                    // Outer building perimeter
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Brand.ink.opacity(0.72), lineWidth: 1.5)
                        .frame(width: w * 0.68, height: h * 0.56)
                        .position(x: w * 0.48, y: h * 0.50)

                    // Highlighted studio wing
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Brand.accent.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Brand.accent.opacity(0.65), lineWidth: 1.2)
                        )
                        .frame(width: w * 0.30, height: h * 0.56)
                        .position(x: w * 0.67, y: h * 0.50)

                    // Interior partition + courtyard label
                    Text("WEST GALLERY")
                        .font(.system(size: 7.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Brand.muted)
                        .position(x: w * 0.33, y: h * 0.50)

                    Text("STUDIO WING")
                        .font(.system(size: 7.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Brand.accent)
                        .position(x: w * 0.67, y: h * 0.50)

                    // Dimension ticks
                    Text("24.0 m")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(Brand.tertiary)
                        .position(x: w * 0.48, y: h * 0.14)
                }
            }
            .frame(height: 158)

            // Summary metrics
            HStack(spacing: 8) {
                MetricTile(label: "Footprint", value: "312 m²")
                MetricTile(label: "Setback", value: "4.5 m")
                MetricTile(label: "Status", value: "Review")
            }

            Spacer(minLength: 4)

            // Interactive link card that Mac A's cursor clicks to open Build Schedule
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(buttonHover > 0.2 ? Color.white : Brand.accent)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(buttonHover > 0.2 ? Brand.accent : Brand.accentWash)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Open Build Schedule")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                    Text("build.fieldguide.example")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .offset(x: CGFloat(2 * buttonHover))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(buttonHover > 0.1 ? Brand.accent.opacity(0.08 + 0.06 * buttonPress) : Brand.ground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .strokeBorder(
                        buttonHover > 0.1 ? Brand.accent.opacity(0.55) : Brand.line.opacity(0.8),
                        lineWidth: buttonHover > 0.1 ? 1.1 : 0.7
                    )
            )
            .scaleEffect(1 - 0.025 * buttonPress)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.surface)
    }
}

struct MetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Brand.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Brand.ink)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.ground.opacity(0.75), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct MaterialSpecPage: View {
    private let materials: [(String, String, String, Color)] = [
        ("Limestone Cladding", "Honed 24 mm · Exterior", "M-01", Brand.stone),
        ("White Oak Flooring", "Matte oil · Quarter-sawn", "M-04", Brand.warmWood),
        ("Brushed Aluminum", "Clear anodized mullion", "M-07", Brand.aluminum),
        ("Acoustic Plaster", "Fine mineral finish", "M-11", Color(hex: 0xE6E6EA)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SPECIFICATIONS")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.muted)
                    Text("Material Spec")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(Brand.ink)
                }
                Spacer()
                Text("4 samples")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Brand.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Brand.ground, in: Capsule())
            }

            VStack(spacing: 7) {
                ForEach(Array(materials.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(item.3)
                            .frame(width: 28, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.6)
                            )

                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(item.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                            Text(item.1)
                                .font(.system(size: 9, weight: .regular))
                                .foregroundStyle(Brand.muted)
                        }

                        Spacer()

                        Text(item.2)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Brand.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Brand.ground, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7.5)
                    .background(Color(hex: 0xFAFAFC), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Brand.line.opacity(0.65), lineWidth: 0.6)
                    )
                }
            }

            Spacer(minLength: 4)

            HStack {
                Text("Note: Verify finish sample under north daylight before sign-off.")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(Brand.muted)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.ground.opacity(0.7), in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.surface)
    }
}

struct BuildSchedulePage: View {
    private let items: [(String, String, CGFloat, CGFloat, Bool)] = [
        ("Site Prep", "Wk 1–2", 0.00, 0.30, false),
        ("Foundation", "Wk 2–4", 0.22, 0.34, false),
        ("Timber Framing", "Wk 4–7", 0.44, 0.38, true),
        ("Glazing & Roof", "Wk 6–8", 0.68, 0.32, false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SCHEDULE · Q3")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.accent)
                    Text("Build Schedule")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(Brand.ink)
                }
                Spacer()
                Text("8 weeks")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3)
                    .background(Brand.accentWash, in: Capsule())
            }

            // Timeline grid
            VStack(spacing: 10) {
                HStack {
                    ForEach(["Wk 1", "Wk 3", "Wk 5", "Wk 7"], id: \.self) { wk in
                        Text(wk)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Brand.tertiary)
                        if wk != "Wk 7" { Spacer() }
                    }
                }
                .padding(.horizontal, 2)

                ForEach(Array(items.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.0)
                                .font(.system(size: 10.5, weight: row.4 ? .semibold : .medium))
                                .foregroundStyle(Brand.ink)
                            Spacer()
                            Text(row.1)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Brand.muted)
                        }

                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Brand.ground)
                                    .frame(height: 8)
                                Capsule()
                                    .fill(row.4 ? Brand.accent : Brand.ink.opacity(0.68))
                                    .frame(width: g.size.width * row.3, height: 8)
                                    .offset(x: g.size.width * row.2)
                            }
                        }
                        .frame(height: 8)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7.5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(row.4 ? Brand.accentWash : Color(hex: 0xFAFAFC))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(row.4 ? Brand.accent.opacity(0.28) : Brand.line.opacity(0.6), lineWidth: 0.6)
                    )
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Brand.accent)
                Text("Framing crew booked · Inspect footings Friday")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Brand.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.surface)
    }
}

// MARK: - Demo A: Spaces Walkthrough (8.00s, 16:10, Two Macs + Shared Space A -> B)

struct SpacesDemoView: View {
    let t: Double

    static let duration: Double = 8.0

    private let baseTabs: [TabSpec] = [
        TabSpec(id: "plan", title: "Site Plan", domain: "plan.fieldguide.example", symbol: "map"),
        TabSpec(id: "spec", title: "Material Spec", domain: "spec.fieldguide.example", symbol: "square.stack.3d.up"),
        TabSpec(id: "notes", title: "Lighting Notes", domain: "notes.fieldguide.example", symbol: "sun.max"),
    ]
    private let newTab = TabSpec(id: "sched", title: "Build Schedule", domain: "build.fieldguide.example", symbol: "calendar")

    // Window geometry in 960x600 coordinate space
    private let winW: CGFloat = 432
    private let winH: CGFloat = 474
    private let winY: CGFloat = 94
    private let leftX: CGFloat = 28
    private let rightX: CGFloat = 500
    private let sidebarW: CGFloat = 148

    var body: some View {
        // Loop end gentle dissolve back to starting state (7.30s -> 7.82s), leaving clean settled end frames matching t=0
        let loopReset = Anim.easeInOutCubic(Anim.progress(t, start: 7.30, end: 7.82))

        // Phase 1: Cursor A moves to "Open Build Schedule" card on Mac A (0.85s -> 1.65s), clicks at 1.80s
        let curAMove = Anim.easeInOutCubic(Anim.progress(t, start: 0.75, end: 1.60))
        let btnAHover = Anim.easeOutCubic(Anim.progress(t, start: 1.38, end: 1.62)) * (1 - Anim.progress(t, start: 1.92, end: 2.08))
        let clickA = Anim.clickPulse(t, at: 1.80)
        let rippleA = Anim.progress(t, start: 1.80, end: 2.22)

        // Phase 2: Tab 4 opens on Mac A (1.92s -> 2.38s)
        let tabAOpenRaw = Anim.gentleSpring(Anim.progress(t, start: 1.92, end: 2.40))
        let tabAOpen = tabAOpenRaw * (1 - loopReset)
        let pageASwitchRaw = Anim.easeOutCubic(Anim.progress(t, start: 1.98, end: 2.34))
        let pageASwitch = pageASwitchRaw * (1 - loopReset)

        // Phase 3: Shared Space delivery A -> B (2.55s -> 4.05s) — deliberate, calm cadence (no speed/benchmark claim)
        let flight = Anim.easeInOutCubic(Anim.progress(t, start: 2.55, end: 4.05))
        let flightVis = Anim.easeOutCubic(Anim.progress(t, start: 2.50, end: 2.74))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 3.92, end: 4.18)))
        let sendPulseA = Anim.progress(t, start: 2.52, end: 3.15)
        let slotBPrep = Anim.easeOutCubic(Anim.progress(t, start: 3.15, end: 3.65))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 3.95, end: 4.20)))

        // Phase 4: Tab 4 lands on Mac B (3.95s -> 4.40s) with WSurf SidebarRevealPulse + unseen dot
        let tabBOpenRaw = Anim.gentleSpring(Anim.progress(t, start: 3.95, end: 4.42))
        let tabBOpen = tabBOpenRaw * (1 - loopReset)
        let revealPulseB = Anim.sidebarRevealPulse(elapsed: t - 4.08) * (1 - loopReset)
        let recvPulseB = Anim.progress(t, start: 3.98, end: 4.65)

        // Phase 5: Cursor B clicks newly arrived "Build Schedule" on Mac B (4.80s -> 5.42s), clicks at 5.56s
        let curBMove = Anim.easeInOutCubic(Anim.progress(t, start: 4.80, end: 5.40))
        let curBVis = Anim.easeOutCubic(Anim.progress(t, start: 4.72, end: 4.98))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 5.95, end: 6.24)))
        let rowBHover = Anim.easeOutCubic(Anim.progress(t, start: 5.25, end: 5.45))
            * (1 - Anim.progress(t, start: 5.68, end: 5.88))
        let clickB = Anim.clickPulse(t, at: 5.56)
        let rippleB = Anim.progress(t, start: 5.56, end: 5.96)

        let tabBSelectedRaw = Anim.easeOutCubic(Anim.progress(t, start: 5.62, end: 5.92))
        let tabBSelected = tabBSelectedRaw * (1 - loopReset)

        // Cursor A visibility (fades softly away once delivery is underway)
        let curAVis = Anim.easeOutCubic(Anim.progress(t, start: 0.45, end: 0.78))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 2.30, end: 2.68)))

        // Coordinates for cursor A (targeting "Open Build Schedule" card inside Mac A)
        let curAStart = CGPoint(x: leftX + 276, y: winY + 255)
        let curACtrl = CGPoint(x: leftX + 344, y: winY + 335)
        let curAEnd = CGPoint(x: leftX + 292, y: winY + 422)
        let curAPos = Anim.quadBezier(curAStart, curACtrl, curAEnd, curAMove)

        // Coordinates for cursor B (targeting exact vertical center of Row 4 "Build Schedule" in Mac B's sidebar)
        // Top header 38 + section label ~16 + 3 rows * (27 + 4) + half row 13.5 = 160.5
        let row4Y: CGFloat = winY + 161
        let curBStart = CGPoint(x: rightX + 244, y: winY + 272)
        let curBCtrl = CGPoint(x: rightX + 148, y: winY + 215)
        let curBEnd = CGPoint(x: rightX + 78, y: row4Y)
        let curBPos = Anim.quadBezier(curBStart, curBCtrl, curBEnd, curBMove)

        // Delivery arc coordinates from Mac A's Row 4 to Mac B's Row 4, arcing right over the center channel
        let arcStart = CGPoint(x: leftX + sidebarW - 6, y: row4Y)
        let arcEnd = CGPoint(x: rightX + 10, y: row4Y)
        let arcControl = CGPoint(x: 472, y: row4Y - 98)
        let chipPos = Anim.quadBezier(arcStart, arcControl, arcEnd, flight)

        ZStack(alignment: .topLeading) {
            StageBackdrop()

            // Top Shared Space header & Mac device labels
            HStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "briefcase.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(Brand.accent)
                        .padding(1)
                        .background(Brand.surface, in: Circle())
                        .offset(x: 4, y: 2.5)
                }
                .padding(.trailing, 3)

                Text("Shared Space")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Brand.muted)
                Text("—")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Brand.lineStrong)
                Text("Field Guide")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Brand.ink)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)
            .background(Brand.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.line.opacity(0.9), lineWidth: 0.7))
            .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
            .frame(maxWidth: .infinity)
            .position(x: 480, y: 34)

            // Device labels above each Mac
            DeviceCaption(symbol: "laptopcomputer", name: "Studio MacBook", isActive: tabBSelected < 0.5)
                .position(x: leftX + winW / 2, y: 74)
            DeviceCaption(symbol: "desktopcomputer", name: "Desk Mac", isActive: tabBOpen > 0.3 || tabBSelected > 0.3)
                .position(x: rightX + winW / 2, y: 74)

            // Mac A Window
            SpacesMacWindow(
                width: winW,
                height: winH,
                sidebarWidth: sidebarW,
                baseTabs: baseTabs,
                newTab: newTab,
                newTabProgress: tabAOpen,
                activeTabID: pageASwitch > 0.4 ? newTab.id : "plan",
                newTabUnseen: false,
                newTabRevealPulse: 0,
                newTabSlotHint: 0,
                newTabHovered: false,
                spacePulse: sendPulseA,
                isFront: curBVis < 0.3,
                pageContent: {
                    ZStack {
                        SitePlanPage(buttonHover: btnAHover, buttonPress: clickA)
                            .opacity(1 - pageASwitch)
                        BuildSchedulePage()
                            .opacity(pageASwitch)
                    }
                },
                domain: pageASwitch > 0.4 ? newTab.domain : baseTabs[0].domain
            )
            .position(x: leftX + winW / 2, y: winY + winH / 2)

            // Mac B Window
            SpacesMacWindow(
                width: winW,
                height: winH,
                sidebarWidth: sidebarW,
                baseTabs: baseTabs,
                newTab: newTab,
                newTabProgress: tabBOpen,
                activeTabID: tabBSelected > 0.4 ? newTab.id : "spec",
                newTabUnseen: tabBOpen > 0.5 && tabBSelected < 0.4,
                newTabRevealPulse: revealPulseB,
                newTabSlotHint: slotBPrep,
                newTabHovered: rowBHover > 0.2,
                spacePulse: recvPulseB,
                isFront: curBVis >= 0.3 || tabBOpen > 0.5,
                pageContent: {
                    ZStack {
                        MaterialSpecPage()
                            .opacity(1 - tabBSelected)
                        BuildSchedulePage()
                            .opacity(tabBSelected)
                    }
                },
                domain: tabBSelected > 0.4 ? newTab.domain : baseTabs[1].domain
            )
            .position(x: rightX + winW / 2, y: winY + winH / 2)

            // Editorial A -> B delivery trajectory & floating tab token
            if flightVis > 0.005 {
                // Soft dashed guide curve
                QuadArcShape(p0: arcStart, c: arcControl, p1: arcEnd)
                    .stroke(
                        Brand.accent.opacity(0.24 * flightVis),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4.5])
                    )

                // Active leading curve segment trailing the flying chip
                QuadArcShape(p0: arcStart, c: arcControl, p1: arcEnd)
                    .trim(from: max(0, CGFloat(flight) - 0.36), to: CGFloat(flight))
                    .stroke(
                        LinearGradient(
                            colors: [Brand.accent.opacity(0), Brand.accent.opacity(0.85 * flightVis)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )

                // Origin dot on Mac A
                Circle()
                    .fill(Brand.accent.opacity(0.85 * flightVis))
                    .frame(width: 6, height: 6)
                    .position(arcStart)

                // Target ring on Mac B
                Circle()
                    .stroke(Brand.accent.opacity(0.65 * flightVis), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .position(arcEnd)

                // Floating tab chip moving A -> B
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                    Text("Build Schedule")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Brand.accent.opacity(0.75))
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill(Brand.surface)
                        .shadow(color: Brand.accent.opacity(0.18), radius: 14, y: 5)
                        .shadow(color: Color.black.opacity(0.10), radius: 4, y: 1.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .strokeBorder(Brand.accent.opacity(0.45), lineWidth: 1)
                )
                .scaleEffect(0.92 + 0.08 * sin(Double.pi * flight))
                .opacity(flightVis)
                .position(chipPos)
            }

            // Pointer on Mac A
            if curAVis > 0.005 {
                MacCursor(position: curAPos, opacity: curAVis, pressed: clickA, ripple: rippleA)
            }

            // Pointer on Mac B
            if curBVis > 0.005 {
                MacCursor(position: curBPos, opacity: curBVis, pressed: clickB, ripple: rippleB)
            }
        }
        .frame(width: 960, height: 600)
        .clipped()
    }
}

struct QuadArcShape: Shape {
    let p0: CGPoint
    let c: CGPoint
    let p1: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: p0)
        p.addQuadCurve(to: p1, control: c)
        return p
    }
}

struct DeviceCaption: View {
    let symbol: String
    let name: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5.5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Brand.ink : Brand.muted)
            Text(name)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Brand.ink : Brand.muted)
        }
    }
}

struct SpacesMacWindow<PageContent: View>: View {
    let width: CGFloat
    let height: CGFloat
    let sidebarWidth: CGFloat
    let baseTabs: [TabSpec]
    let newTab: TabSpec
    let newTabProgress: Double
    let activeTabID: String
    let newTabUnseen: Bool
    let newTabRevealPulse: Double
    let newTabSlotHint: Double
    let newTabHovered: Bool
    let spacePulse: Double
    let isFront: Bool
    @ViewBuilder let pageContent: () -> PageContent
    let domain: String

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                // Top controls
                HStack(spacing: 0) {
                    TrafficLights(active: isFront, size: 8.5, spacing: 5.5)
                    Spacer(minLength: 6)
                    HStack(spacing: 4) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Brand.muted)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Brand.muted)
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Brand.muted)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 38)

                // Space section micro-label
                HStack(spacing: 4) {
                    Text("FIELD GUIDE")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Brand.tertiary)
                    Spacer()
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Brand.accent.opacity(0.75))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 5)

                // Tab rows
                VStack(spacing: 4) {
                    ForEach(baseTabs) { tab in
                        WSurfSidebarRow(tab: tab, isActive: activeTabID == tab.id, compact: true)
                    }

                    // Animated 4th row or subtle drop slot
                    ZStack(alignment: .top) {
                        if newTabSlotHint > 0.01 && newTabProgress < 0.8 {
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .fill(Brand.accentWash.opacity(newTabSlotHint))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                        .strokeBorder(
                                            Brand.accent.opacity(0.42 * newTabSlotHint),
                                            style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                                        )
                                )
                                .frame(height: 27)
                        }

                        if newTabProgress > 0.01 {
                            WSurfSidebarRow(
                                tab: newTab,
                                isActive: activeTabID == newTab.id,
                                isUnseen: newTabUnseen,
                                revealPulse: newTabRevealPulse,
                                isHovered: newTabHovered,
                                compact: true
                            )
                            .opacity(min(1, newTabProgress * 1.25))
                            .offset(y: CGFloat(-6 * (1 - newTabProgress)))
                        }
                    }
                    .frame(height: 27)
                }
                .padding(.horizontal, 6)

                Spacer(minLength: 8)

                // Bottom bar (SidebarProfileControl + SidebarSpaceSwitcher + Settings)
                HStack(spacing: 3) {
                    Image(systemName: "person")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .frame(width: 22, height: 22)

                    Spacer(minLength: 2)

                    HStack(spacing: 2) {
                        SpaceDotView(symbol: "house", isCurrent: false, size: 21)
                        SpaceDotView(symbol: "briefcase", isCurrent: true, isShared: true, size: 21, pulseStrength: spacePulse)
                        SpaceDotView(symbol: "book", isCurrent: false, size: 21)
                    }

                    Spacer(minLength: 2)

                    Image(systemName: "gearshape")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .frame(width: 22, height: 22)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 9)
            }
            .frame(width: sidebarWidth)
            .background(Brand.sidebar)

            // Main content column (ContentNavBar + LoomPageCanvas)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.muted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.tertiary.opacity(0.6))
                    }
                    .padding(.leading, 4)

                    WSurfAddressPill(domain: domain, height: 26, compact: true)

                    Image(systemName: "sidebar.right")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .padding(.trailing, 4)
                }
                .padding(.horizontal, 4)
                .frame(height: 38)

                pageContent()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.6)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 5, y: 1.5)
                    .padding(.leading, 2)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
            }
            .background(Brand.windowChrome)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.11), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(isFront ? 0.12 : 0.08), radius: isFront ? 22 : 16, y: isFront ? 10 : 6)
        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)
    }
}

// MARK: - Synthetic Neutral Web Pages for Demo B (Micro Window — Out and Back)

/// Responsive Layout Reference page that adapts gracefully from full window to compact Micro Window.
struct LayoutReferencePage: View {
    let isCompact: Bool

    private let specs: [(String, String, String)] = [
        ("Page spacing", "6 pt", "Inset around canvas"),
        ("Toolbar height", "44 pt", "Top & Micro bar"),
        ("Corner radius", "12 pt", "Continuous squircle"),
        ("Row height", "30 pt", "Sidebar standard"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 9 : 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MEADOW UI · REFERENCE")
                        .font(.system(size: isCompact ? 8 : 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.accent)
                    Text("Layout Reference")
                        .font(.system(size: isCompact ? 15 : 20, weight: .bold))
                        .foregroundStyle(Brand.ink)
                }
                Spacer()
                Text("v2.4")
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Brand.accent)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3)
                    .background(Brand.accentWash, in: Capsule())
            }

            // Visual 12-column rhythm preview bar
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Grid cadence")
                        .font(.system(size: isCompact ? 9.5 : 10.5, weight: .semibold))
                        .foregroundStyle(Brand.muted)
                    Spacer()
                    Text("12 cols · 16 pt gutter")
                        .font(.system(size: isCompact ? 8.5 : 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Brand.tertiary)
                }

                HStack(spacing: isCompact ? 3.5 : 5) {
                    ForEach(0..<12, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill((i == 0 || i == 1 || i == 10 || i == 11) ? Brand.accent.opacity(0.24) : Brand.accent.opacity(0.11))
                            .frame(height: isCompact ? 26 : 42)
                    }
                }
                .padding(isCompact ? 6 : 8)
                .background(Color(hex: 0xFAFAFC), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Brand.line.opacity(0.65), lineWidth: 0.6)
                )
            }

            // Spec rows (2-column grid when wide, clean stacked list when compact!)
            if isCompact {
                VStack(spacing: 5.5) {
                    ForEach(Array(specs.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.0)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Brand.ink)
                            Spacer()
                            Text(row.1)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Brand.accent)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 2)
                                .background(Brand.accentWash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color(hex: 0xFAFAFC), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Brand.line.opacity(0.6), lineWidth: 0.6)
                        )
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array(specs.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(row.0)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Brand.ink)
                                Spacer()
                                Text(row.1)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Brand.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Brand.accentWash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            Text(row.2)
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundStyle(Brand.muted)
                        }
                        .padding(12)
                        .background(Color(hex: 0xFAFAFC), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Brand.line.opacity(0.7), lineWidth: 0.6)
                        )
                    }
                }

                // Extra editorial note block visible in normal window
                VStack(alignment: .leading, spacing: 6) {
                    Text("Window Chrome Guidance")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                    Text("Keep reference pages legible at compact widths so metrics remain readable while floating beside working drafts.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Brand.muted)
                        .lineSpacing(2.5)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.ground.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .padding(isCompact ? 14 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.surface)
    }
}

/// Working document revealed in the main window while Layout Reference floats in the Micro Window.
struct ProjectBriefPage: View {
    private let tasks: [(String, Bool)] = [
        ("Confirm 6 pt page canvas inset", true),
        ("Check 12-column responsive gutters", true),
        ("Verify compact toolbar rhythm", false),
        ("Publish updated web layout notes", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AUTUMN STUDIO · WORKING DRAFT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.muted)
                Text("Project Brief")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Brand.ink)
            }

            Text("Compare spacing and corner values against the reference sheet before finalizing the print and web layouts.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Brand.muted)
                .lineSpacing(3)
                .frame(maxWidth: 340, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("Review Checklist")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Brand.ink)

                ForEach(Array(tasks.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 9) {
                        Image(systemName: item.1 ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(item.1 ? Brand.accent : Brand.lineStrong)
                        Text(item.0)
                            .font(.system(size: 11.5, weight: item.1 ? .regular : .medium))
                            .foregroundStyle(item.1 ? Brand.muted : Brand.ink)
                            .strikethrough(item.1, color: Brand.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color(hex: 0xFAFAFC), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Brand.line.opacity(0.65), lineWidth: 0.6)
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.surface)
    }
}

// MARK: - Demo B: Micro Window Walkthrough (8.50s, 16:10, Out and Back, Seamless Loop)

struct MicroDemoView: View {
    let t: Double

    static let duration: Double = 8.5

    private let tabs: [TabSpec] = [
        TabSpec(id: "brief", title: "Project Brief", domain: "brief.meadow.example", symbol: "doc.text"),
        TabSpec(id: "layout", title: "Layout Reference", domain: "docs.meadow.example", symbol: "ruler"),
        TabSpec(id: "spec", title: "Component Spec", domain: "spec.meadow.example", symbol: "square.grid.2x2"),
        TabSpec(id: "notes", title: "Meeting Notes", domain: "notes.meadow.example", symbol: "note.text"),
    ]

    // Main window resting vs yielded geometry
    private let mainW: CGFloat = 728
    private let mainH: CGFloat = 504
    private let sidebarW: CGFloat = 192

    // Micro Window compact geometry (exact 4:3 compact ratio echoing MicroWindowMetrics.defaultSize 560x420)
    private let microW: CGFloat = 356
    private let microH: CGFloat = 282

    var body: some View {
        // Phase 1: Pointer moves to MicroWindowBadge (arrow.up.forward.square) in normal toolbar (0.65s -> 1.40s)
        let moveOutCur = Anim.easeInOutCubic(Anim.progress(t, start: 0.60, end: 1.32))
        let outBadgeHover = Anim.easeOutCubic(Anim.progress(t, start: 1.18, end: 1.38))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 1.92, end: 2.08)))
        let outTooltip = Anim.easeOutCubic(Anim.progress(t, start: 1.28, end: 1.46))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 1.88, end: 2.02)))
        let clickOut = Anim.clickPulse(t, at: 1.88)
        let rippleOut = Anim.progress(t, start: 1.88, end: 2.30)

        // Phase 2: Page moves OUT to Micro Window (1.96s -> 2.86s)
        let popOut = Anim.gentleSpring(Anim.progress(t, start: 1.96, end: 2.86))
        // Phase 6: Page moves BACK to Main Window (6.52s -> 7.42s)
        let popBack = Anim.gentleSpring(Anim.progress(t, start: 6.52, end: 7.42))

        // Unified "is out in Micro Window" factor (0 -> 1 -> 0)
        let microPresence = Anim.clamp(popOut - popBack)
        let isOut = microPresence > 0.02

        // Main window shifts gently left while Micro Window floats on the right
        let mainCenterX = Anim.lerp(CGFloat(480), CGFloat(398), microPresence)
        let mainCenterY = Anim.lerp(CGFloat(302), CGFloat(308), microPresence)
        let mainOriginX = mainCenterX - mainW / 2
        let mainOriginY = mainCenterY - mainH / 2

        // Main window canvas center (origin & return destination of the flying Micro Window)
        let canvasRectCenter = CGPoint(
            x: mainOriginX + sidebarW + (mainW - sidebarW) / 2,
            y: mainOriginY + 42 + (mainH - 48) / 2
        )
        let microRestCenter = CGPoint(x: 742, y: 294)

        // Smooth morph path between main window canvas and compact floating Micro Window
        let morphT: Double = t < 5.0 ? popOut : (1 - popBack)
        let currentMicroW = Anim.lerp(mainW - sidebarW - 10, microW, morphT)
        let currentMicroH = Anim.lerp(mainH - 50, microH, morphT)
        let microCenter: CGPoint = {
            if t < 5.0 {
                let ctrl = CGPoint(x: (canvasRectCenter.x + microRestCenter.x) / 2 + 24, y: min(canvasRectCenter.y, microRestCenter.y) - 34)
                return Anim.quadBezier(canvasRectCenter, ctrl, microRestCenter, popOut)
            } else {
                let ctrl = CGPoint(x: (canvasRectCenter.x + microRestCenter.x) / 2 + 16, y: min(canvasRectCenter.y, microRestCenter.y) - 26)
                return Anim.quadBezier(microRestCenter, ctrl, canvasRectCenter, popBack)
            }
        }()

        // Main window page switches cleanly underneath to Project Brief once popOut starts
        let mainShowsBrief = Anim.easeOutCubic(Anim.progress(t, start: 2.02, end: 2.38))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 7.12, end: 7.42)))
        let rowMarkedInMicro = t >= 2.02 && t < 7.28
        let microBadgeAccent = Anim.easeOutCubic(Anim.progress(t, start: 2.05, end: 2.40))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 2.85, end: 3.45)))

        // Phase 3 & 4: MicroBar auto-hides (3.30s -> 3.75s), then slides back down on top-edge hover (4.95s -> 5.40s)
        let barInitialHide = Anim.easeInOutCubic(Anim.progress(t, start: 3.32, end: 3.76))
        let barHoverReveal = Anim.easeOutCubic(Anim.progress(t, start: 4.92, end: 5.36))
        let barHideOnReturn = Anim.easeOutCubic(Anim.progress(t, start: 6.52, end: 6.72))
        let microBarShown = Anim.clamp((1 - barInitialHide + barHoverReveal) * (1 - barHideOnReturn))

        // Phase 5: Pointer reveals MicroBar & hovers Move Back to Main Window (arrow.down.backward.square)
        let curToMicroTop = Anim.easeInOutCubic(Anim.progress(t, start: 4.55, end: 5.08))
        let curToBackBtn = Anim.easeInOutCubic(Anim.progress(t, start: 5.20, end: 5.64))
        let backBadgeHover = Anim.easeOutCubic(Anim.progress(t, start: 5.48, end: 5.70))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 6.46, end: 6.62)))
        let backTooltip = Anim.easeOutCubic(Anim.progress(t, start: 5.58, end: 5.76))
            * (1 - Anim.easeOutCubic(Anim.progress(t, start: 6.42, end: 6.56)))
        let clickBack = Anim.clickPulse(t, at: 6.42)
        let rippleBack = Anim.progress(t, start: 6.42, end: 6.84)

        // Exact address bar MicroWindowBadge target coordinates
        // Right column width = mainW - sidebarW = 536; centered pill width = 340 -> pillRight = mainOriginX + sidebarW + 268 + 170
        // Inside pill: padding 7 + slider(18) + spacing 4 + half badge(11) = 40 from pillRight -> +398 from sidebar edge
        let outBtnPos = CGPoint(x: mainOriginX + sidebarW + 398, y: mainOriginY + 21)

        // In Micro Window settled at (742, 294), width=356, height=282 -> top=153, left=564
        // Right side of MicroBar: trailing 6 + floatBtn(24) + gap 5 + pillRight -> inside compact pill: padding 6 + slider(16) + gap 3 + half badge(10) = 35
        // Total from microRight = 6 + 24 + 5 + 35 = 70 -> from microLeft = 356 - 70 = 286
        let microTopY = microRestCenter.y - microH / 2
        let microLeftX = microRestCenter.x - microW / 2
        let microRevealPos = CGPoint(x: microLeftX + 195, y: microTopY + 8)
        let backBtnPos = CGPoint(x: microLeftX + 286, y: microTopY + 17)

        // Compute continuous pointer trajectory across the whole 8.5s walkthrough
        let cursorStart = CGPoint(x: 420, y: 240)
        let cursorPos: CGPoint = {
            if t < 4.55 {
                let ctrl = CGPoint(x: 476, y: 118)
                return Anim.quadBezier(cursorStart, ctrl, outBtnPos, moveOutCur)
            } else if t < 5.20 {
                let ctrl = CGPoint(x: 632, y: 92)
                return Anim.quadBezier(outBtnPos, ctrl, microRevealPos, curToMicroTop)
            } else {
                let ctrl = CGPoint(x: 808, y: 155)
                return Anim.quadBezier(microRevealPos, ctrl, backBtnPos, curToBackBtn)
            }
        }()

        let cursorOpacity: Double = {
            let fadeIn = Anim.easeOutCubic(Anim.progress(t, start: 0.35, end: 0.62))
            let dipMiddle = 1 - Anim.easeOutCubic(Anim.progress(t, start: 2.28, end: 2.60))
                + Anim.easeOutCubic(Anim.progress(t, start: 4.42, end: 4.74))
            let fadeOut = 1 - Anim.easeOutCubic(Anim.progress(t, start: 7.00, end: 7.45))
            return Anim.clamp(fadeIn * dipMiddle * fadeOut)
        }()

        // Subtle curved motion indicator during flight (pop-out & return)
        let flightRibbonAlpha =
            (Anim.easeOutCubic(Anim.progress(t, start: 2.00, end: 2.24)) * (1 - Anim.easeOutCubic(Anim.progress(t, start: 2.68, end: 2.95))))
            + (Anim.easeOutCubic(Anim.progress(t, start: 6.56, end: 6.76)) * (1 - Anim.easeOutCubic(Anim.progress(t, start: 7.18, end: 7.45))))

        ZStack(alignment: .topLeading) {
            StageBackdrop()

            // Normal Main WSurf Browser Window
            MainWSurfWindow(
                width: mainW,
                height: mainH,
                sidebarWidth: sidebarW,
                tabs: tabs,
                activeTabID: mainShowsBrief > 0.3 ? "brief" : "layout",
                inMicroTabID: rowMarkedInMicro ? "layout" : nil,
                microBadgeAccent: microBadgeAccent,
                domain: mainShowsBrief > 0.3 ? tabs[0].domain : tabs[1].domain,
                isFront: microPresence < 0.35,
                microOutHover: outBadgeHover,
                microOutPressed: clickOut,
                pageContent: {
                    ZStack {
                        LayoutReferencePage(isCompact: false)
                            .opacity(1 - mainShowsBrief)
                        ProjectBriefPage()
                            .opacity(mainShowsBrief)
                    }
                }
            )
            .position(x: mainCenterX, y: mainCenterY)

            // Subtle vector arc showing motion path during pop-out / return
            if flightRibbonAlpha > 0.01 {
                let p0 = outBtnPos
                let p1 = CGPoint(x: microRestCenter.x - microW / 2 + 12, y: microRestCenter.y - microH / 2 + 18)
                let ctrl = CGPoint(x: (p0.x + p1.x) / 2 + 18, y: min(p0.y, p1.y) - 34)
                QuadArcShape(p0: p0, c: ctrl, p1: p1)
                    .stroke(
                        Brand.accent.opacity(0.45 * flightRibbonAlpha),
                        style: StrokeStyle(lineWidth: 1.75, lineCap: .round, dash: [4.5, 4.5])
                    )
            }

            // Compact Floating Micro Window (exact MicroWindowView + MicroShell + MicroBar)
            if isOut {
                MicroWindowChrome(
                    width: currentMicroW,
                    height: currentMicroH,
                    barShown: microBarShown,
                    domain: tabs[1].domain,
                    backHover: backBadgeHover,
                    backPressed: clickBack,
                    morphFraction: morphT
                )
                .opacity(Anim.clamp(microPresence * 3.5))
                .position(microCenter)
            }

            // Real WSurf Tooltip: "Move to Micro Window"
            if outTooltip > 0.01 {
                MacTooltip(text: "Move to Micro Window", shortcut: "⇧⌥⌘N")
                    .opacity(outTooltip)
                    .offset(y: CGFloat(4 * (1 - outTooltip)))
                    .position(x: outBtnPos.x - 16, y: outBtnPos.y + 30)
            }

            // Real WSurf Tooltip: "Move Back to Main Window" (positioned cleanly above MicroBar so page content stays unobstructed)
            if backTooltip > 0.01 {
                MacTooltip(text: "Move Back to Main Window", shortcut: "⇧⌥⌘N")
                    .opacity(backTooltip)
                    .offset(y: CGFloat(-4 * (1 - backTooltip)))
                    .position(x: backBtnPos.x - 42, y: microTopY - 18)
            }

            // Pointer
            if cursorOpacity > 0.005 {
                MacCursor(
                    position: cursorPos,
                    opacity: cursorOpacity,
                    pressed: max(clickOut, clickBack),
                    ripple: max(rippleOut, rippleBack)
                )
            }
        }
        .frame(width: 960, height: 600)
        .clipped()
    }
}

struct MainWSurfWindow<PageContent: View>: View {
    let width: CGFloat
    let height: CGFloat
    let sidebarWidth: CGFloat
    let tabs: [TabSpec]
    let activeTabID: String
    let inMicroTabID: String?
    let microBadgeAccent: Double
    let domain: String
    let isFront: Bool
    let microOutHover: Double
    let microOutPressed: Double
    @ViewBuilder let pageContent: () -> PageContent

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    TrafficLights(active: isFront, size: 9.5, spacing: 6)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Brand.muted)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.muted)
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.muted)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)

                Text("WORKSPACE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Brand.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)

                VStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        WSurfSidebarRow(
                            tab: tab,
                            isActive: activeTabID == tab.id,
                            isInMicro: inMicroTabID == tab.id,
                            microBadgeAccent: inMicroTabID == tab.id ? microBadgeAccent : 0,
                            compact: false
                        )
                    }
                }
                .padding(.horizontal, 8)

                Spacer(minLength: 8)

                // Bottom bar
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .frame(width: 24, height: 24)

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        SpaceDotView(symbol: "briefcase", isCurrent: true, size: 22)
                        SpaceDotView(symbol: "book", isCurrent: false, size: 22)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .frame(width: 22, height: 22)
                    Image(systemName: "gearshape")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Brand.muted)
                        .frame(width: 22, height: 22)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .frame(width: sidebarWidth)
            .background(Brand.sidebar)

            // Toolbar + Page Canvas
            VStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Brand.muted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Brand.tertiary.opacity(0.55))
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Brand.muted)
                        }
                        .padding(.leading, 12)

                        Spacer()

                        Image(systemName: "sidebar.right")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Brand.muted)
                            .padding(.trailing, 12)
                    }

                    WSurfAddressPill(
                        domain: domain,
                        height: 30,
                        compact: false,
                        showsMicroOut: true,
                        showsMicroBack: false,
                        microHover: microOutHover,
                        microPressed: microOutPressed
                    )
                    .frame(width: 340)
                }
                .frame(height: 42)

                pageContent()
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.065), lineWidth: 0.6)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 5, y: 1.5)
                    .padding(.leading, 2)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
            }
            .background(Brand.windowChrome)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.black.opacity(0.11), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(isFront ? 0.13 : 0.08), radius: isFront ? 24 : 16, y: isFront ? 10 : 6)
        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)
    }
}

/// Authentic WSurf Micro Window (WSurf/UI/Shell/Micro/MicroWindowView.swift + MicroShell.swift + MicroBar.swift).
struct MicroWindowChrome: View {
    let width: CGFloat
    let height: CGFloat
    let barShown: Double
    let domain: String
    let backHover: Double
    let backPressed: Double
    let morphFraction: Double

    private let barH: CGFloat = 36

    var body: some View {
        ZStack(alignment: .top) {
            // Full-bleed single page, no sidebar or tab bar
            LayoutReferencePage(isCompact: morphFraction > 0.45)
                .padding(.top, CGFloat(barShown) * 24)

            // Sliding MicroBar (slides down from y = -44 to y = 0 on pointer at top)
            HStack(spacing: 5) {
                TrafficLights(active: true, size: 8.5, spacing: 5.5)
                    .padding(.leading, 8)

                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Brand.muted)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Brand.muted)
                }

                WSurfAddressPill(
                    domain: domain,
                    height: 25,
                    compact: true,
                    showsMicroOut: false,
                    showsMicroBack: true,
                    microHover: backHover,
                    microPressed: backPressed
                )

                // Float on Top button (MicroBar.swift:45 — square.3.layers.3d.top.filled)
                ZStack {
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(Brand.accentWash)
                        .frame(width: 24, height: 22)
                    Image(systemName: "square.3.layers.3d.top.filled")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                }
                .padding(.trailing, 6)
            }
            .frame(height: barH)
            .background(Color(hex: 0xF4F4F8))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.09))
                    .frame(height: 0.6)
            }
            .offset(y: Anim.lerp(-barH - 6, 0, barShown))
            .opacity(Anim.clamp(barShown * 1.4))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.13), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.22 * morphFraction + 0.04), radius: 26 * morphFraction + 6, y: 12 * morphFraction + 2)
        .shadow(color: Brand.accent.opacity(0.06 * morphFraction), radius: 12, y: 4)
    }
}

// MARK: - Frame Rendering CLI

@MainActor
func renderCGImage(scene: String, time: Double) -> CGImage {
    let content: AnyView
    switch scene {
    case "spaces":
        content = AnyView(SpacesDemoView(t: time).environment(\.colorScheme, .light))
    case "micro":
        content = AnyView(MicroDemoView(t: time).environment(\.colorScheme, .light))
    default:
        fatalError("Unknown scene: \(scene)")
    }
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2.0 // 960x600 @ 2x = 1920x1200 -> Lanczos downscale to crisp 1280x800 (16:10)
    renderer.isOpaque = true
    guard let img = renderer.cgImage else {
        fatalError("ImageRenderer produced nil CGImage at t=\(time)")
    }
    return img
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Failed to create PNG destination: \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Failed to finalize PNG: \(path)")
    }
}

@main
struct MotionDemosCLI {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            fputs("Usage:\n  motion-demos <spaces|micro> frames <outdir> <fps> <start> <end>\n  motion-demos <spaces|micro> still <out.png> <seconds>\n", stderr)
            exit(2)
        }
        let scene = args[1]
        let mode = args[2]
        switch mode {
        case "still":
            guard args.count == 5, let seconds = Double(args[4]) else { exit(2) }
            let outPath = args[3]
            let img = renderCGImage(scene: scene, time: seconds)
            writePNG(img, to: outPath)
        case "frames":
            guard args.count == 7,
                  let fps = Double(args[4]),
                  let start = Int(args[5]),
                  let end = Int(args[6]) else { exit(2) }
            let outDir = args[3]
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            for i in start..<end {
                let time = Double(i) / fps
                let img = renderCGImage(scene: scene, time: time)
                let file = String(format: "%@/f%04d.png", outDir, i)
                writePNG(img, to: file)
            }
        default:
            exit(2)
        }
    }
}
