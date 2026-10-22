// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WSurfCore

/// Which device the sidebar shows. Pure, so the rules are tested without a view.
enum SidebarDeviceFilter {
    /// The remote session that `id` names, or nil for This Mac, and for a device that has gone since it was picked.
    static func shown(_ id: String?, in sessions: [RemoteDeviceSession]) -> RemoteDeviceSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// This Mac and the others fit side by side up to three; more go into a menu.
    static func usesMenu(remoteCount: Int) -> Bool {
        remoteCount + 1 > 3
    }
}

/// This Mac, then the other devices by label. The binding reads through `SidebarDeviceFilter`, so a device that vanished shows
/// This Mac.
struct SidebarDevicePicker: View {
    let sessions: [RemoteDeviceSession]
    @Binding var shown: String?

    private var selection: Binding<String?> {
        Binding(
            get: { SidebarDeviceFilter.shown(shown, in: sessions)?.id },
            set: { shown = $0 }
        )
    }

    var body: some View {
        if SidebarDeviceFilter.usesMenu(remoteCount: sessions.count) {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var picker: some View {
        Picker(selection: selection) {
            Text("This Mac").tag(String?.none)
            ForEach(sessions) { session in
                Text(verbatim: session.label)
                    .tag(Optional(session.id))
                    .accessibilityLabel(Text(verbatim: session.deviceName))
            }
        } label: {
            Text("Show tabs from")
        }
        .labelsHidden()
        .controlSize(.small)
    }
}
