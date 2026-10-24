// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    let id: String
    @Binding var recording: String?

    let shortcut: ActivationShortcut
    let defaultShortcut: ActivationShortcut
    let onChange: (ActivationShortcut) -> Void

    @State private var monitor: Any?
    @State private var heldModifier: UInt16?
    @State private var complaint: String?
    @State private var hovering = false

    private var isRecording: Bool {
        recording == id
    }
    private var isDefault: Bool {
        shortcut == defaultShortcut
    }
    private var complaintShown: Binding<Bool> {
        Binding(
            get: { complaint != nil },
            set: { if !$0 { complaint = nil } }
        )
    }

    /// The row keeps its height whatever the recorder has to say: the complaint opens over the field instead of under it,
    /// and the hint to press a key or Escape is the field's own tooltip.
    var body: some View {
        HStack(spacing: 7) {
            field
                .popover(isPresented: complaintShown, arrowEdge: .bottom) {
                    if let complaint {
                        SettingsNotice(symbol: "exclamationmark.triangle.fill", text: complaint)
                            .frame(maxWidth: 260, alignment: .leading)
                            .padding(12)
                    }
                }

            if !isRecording, !isDefault {
                IconButton(symbol: "arrow.uturn.backward", help: "Reset to Default") {
                    complaint = nil
                    onChange(defaultShortcut)
                }
            }
        }
        .onChange(of: isRecording) { _, listening in
            if listening {
                listen()
            } else {
                deafen()
            }
        }
        .onDisappear {
            deafen()
            if isRecording {
                recording = nil
            }
        }
    }

    private var field: some View {
        Button {
            complaint = nil
            recording = isRecording ? nil : id
        } label: {
            HStack(spacing: 5) {
                if isRecording {
                    Text("Press shortcut")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.tertiary)
                } else {
                    KeyCaps(caps: shortcut.caps)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .settingsSurface(
                isActive: hovering || isRecording,
                tint: isRecording ? Theme.danger : nil,
                isLifted: true,
                in: RoundedRectangle(cornerRadius: Theme.Radius.hover, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isRecording ? "Press a shortcut. Press Escape to cancel." : "Change the keyboard shortcut")
        .animation(Theme.Motion.quick, value: isRecording)
        .animation(Theme.Motion.quick, value: hovering)
    }

    // MARK: - Listening

    private func listen() {
        guard monitor == nil else { return }
        heldModifier = nil

        // Swallow every key while recording runs. If not, recording Command-W
        // closes the window being configured.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated {
                capture(event)
            }
            return nil
        }
    }

    private func deafen() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        heldModifier = nil
    }

    private func capture(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard let modifier = ActivationShortcut.modifierKeys[event.keyCode] else { return }
            if event.modifierFlags.contains(modifier.flag) {
                heldModifier = event.keyCode
            } else if heldModifier == event.keyCode {
                commit(ActivationShortcut(keyCode: event.keyCode, label: modifier.name))
            }

        case .keyDown:
            heldModifier = nil
            let modifiers = ActivationShortcut.significant(event.modifierFlags)

            if event.keyCode == 53, modifiers.isEmpty {
                recording = nil
                return
            }

            commit(ActivationShortcut(
                keyCode: event.keyCode,
                modifiers: modifiers,
                label: ActivationShortcut.label(for: event)
            ))

        default:
            break
        }
    }

    private func commit(_ recorded: ActivationShortcut) {
        recording = nil
        if let refusal = ActivationShortcut.refusal(for: recorded) {
            complaint = Self.complaint(for: refusal)
            return
        }
        complaint = nil
        onChange(recorded)
    }

    private static func complaint(for refusal: ActivationShortcut.Refusal) -> String {
        switch refusal {
        case .bareKey:
            String(localized: "A key on its own would fire while you type. Hold a modifier with it, or press a modifier by itself.")
        case .command:
            String(localized: "Menu commands already use ⌘ shortcuts. Hold ⌥, ⌃ or ⇧ instead.")
        }
    }
}
