// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

/// Which device the sidebar shows, and how the picker lays out its choices.
@MainActor
struct SidebarDeviceFilterTests {
    private let profile = UUID()

    /// The sessions as the sidebar receives them: from the model, which orders them by label.
    private func sessions(_ names: [String]) -> [RemoteDeviceSession] {
        var state = TabSyncState()
        for (index, name) in names.enumerated() {
            let id = "install-\(index)"
            state.devices[id] = MirroredDevice(info: DeviceInfo(name: name, kind: .mac, appVersion: "0.1.7"), modifiedAt: .distantPast)
            state.sessions[SyncZone.profile(profile), default: [:]][id] = MirroredSession(
                payload: SyncSamples.session(tabs: ["https://example.test/\(index)"]),
                modifiedAt: .distantPast
            )
        }
        let model = TabSync(installID: "me", device: DeviceInfo(name: "Me", kind: .mac, appVersion: "0.1.7"), state: state, persist: { _ in })
        return model.remoteSessions(profileID: profile, fallbackLabel: "Device")
    }

    @Test func thisMacComesFirstThenOtherDevicesByLabel() {
        let listed = sessions(["Ana’s iPad", "Ana’s MacBook Pro", "Ana’s MacBook Air"])

        #expect(listed.map(\.label) == ["Air", "Pro", "iPad"])
        #expect(SidebarDeviceFilter.shown(nil, in: listed) == nil)
        #expect(SidebarDeviceFilter.shown(listed[1].id, in: listed)?.label == "Pro")
    }

    @Test func vanishedDeviceFallsBackToThisMac() {
        let listed = sessions(["Ana’s iPad"])

        #expect(SidebarDeviceFilter.shown("install-gone", in: listed) == nil)
        #expect(SidebarDeviceFilter.shown(listed[0].id, in: []) == nil)
    }

    @Test func fourOrMoreChoicesUseAMenu() {
        #expect(!SidebarDeviceFilter.usesMenu(remoteCount: 1))
        #expect(!SidebarDeviceFilter.usesMenu(remoteCount: 2))
        #expect(SidebarDeviceFilter.usesMenu(remoteCount: 3))
        #expect(SidebarDeviceFilter.usesMenu(remoteCount: 7))
    }

    @Test func noOtherDevicesHidesTheFilter() {
        #expect(sessions([]).isEmpty)
        #expect(SidebarDeviceFilter.shown("install-0", in: sessions([])) == nil)
        #expect(!SidebarDeviceFilter.usesMenu(remoteCount: 0))
    }
}
