// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct LoomTransparencyControl: View {
    @Binding var opacity: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: "capsule.on.rectangle")
                    .foregroundStyle(.secondary)
                LoomTransparencySnapSlider(opacity: $opacity, onEditingChanged: onEditingChanged)
                Image(systemName: "capsule.on.rectangle.fill")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("More transparent")
                Spacer()
                Text("Less transparent")
            }
            .font(Theme.Font.micro)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .settingsSurface(
            isLifted: true,
            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        )
    }
}

private struct LoomTransparencySnapSlider: View {
    private static let snapTolerance = 0.04
    @Binding var opacity: Double
    let onEditingChanged: (Bool) -> Void
    @State private var snappedStop: Double?

    var body: some View {
        VStack(spacing: 1) {
            Slider(value: $opacity, in: 0...1, onEditingChanged: onEditingChanged)
                .tint(Theme.systemAccent)
                .accessibilityLabel("Window transparency")
                .accessibilityValue(Text(opacity, format: .percent))
            HStack(spacing: 0) {
                LoomTransparencySnapDot(isSelected: opacity == 0)
                Spacer(minLength: 0)
                LoomTransparencySnapDot(isSelected: opacity == 0.5)
                Spacer(minLength: 0)
                LoomTransparencySnapDot(isSelected: opacity == 1)
            }
            .padding(.horizontal, 7)
        }
        .onChange(of: opacity) { _, newValue in
            let stop = snapStop(for: newValue)
            if stop != snappedStop {
                snappedStop = stop
                if stop != nil {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            if let stop, newValue != stop {
                opacity = stop
            }
        }
    }

    private func snapStop(for value: Double) -> Double? {
        if value <= Self.snapTolerance {
            return 0
        }
        if abs(value - 0.5) <= Self.snapTolerance {
            return 0.5
        }
        if value >= 1 - Self.snapTolerance {
            return 1
        }
        return nil
    }
}

private struct LoomTransparencySnapDot: View {
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(isSelected ? Theme.systemAccent : Color.primary.opacity(0.36))
            .frame(width: 4, height: 4)
            .animation(Theme.Motion.quick, value: isSelected)
            .accessibilityHidden(true)
    }
}
