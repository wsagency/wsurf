// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

@MainActor
struct SmartCardFeatureTests {
    private func makeDefaults() -> UserDefaults {
        let name = "wsurf-smartcard-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeFeature(
        _ defaults: UserDefaults? = nil,
        pluginKit: @escaping PluginKitRunner = { nil }
    ) -> SmartCardFeature {
        SmartCardFeature(defaults: defaults ?? makeDefaults(), runPluginKit: pluginKit)
    }

    @Test
    func startsDisabledAndInactive() {
        let feature = makeFeature()
        #expect(!feature.enabled)
        #expect(!feature.isActive)
    }

    @Test
    func enableLoads() {
        let feature = makeFeature()
        feature.enable()
        #expect(feature.enabled)
        #expect(feature.loaded)
        #expect(feature.isActive)
    }

    @Test
    func unloadDeactivatesButStaysEnabled() {
        let feature = makeFeature()
        feature.enable()
        feature.unload()
        #expect(feature.enabled)
        #expect(feature.manuallyUnloaded)
        #expect(!feature.isActive)
    }

    @Test
    func explicitLoadClearsManualUnload() {
        let feature = makeFeature()
        feature.enable()
        feature.unload()
        feature.load()
        #expect(feature.isActive)
        #expect(!feature.manuallyUnloaded)
    }

    @Test
    func disableTurnsEverythingOff() {
        let feature = makeFeature()
        feature.enable()
        feature.unload()
        feature.disable()
        #expect(!feature.enabled)
        #expect(!feature.loaded)
        #expect(!feature.manuallyUnloaded)
        #expect(!feature.isActive)
    }

    @Test
    func loadWhileDisabledIsANoOp() {
        let feature = makeFeature()
        feature.load()
        #expect(!feature.loaded)
        #expect(!feature.isActive)
    }

    @Test
    func appDidStartLoadsAfterPlainEnable() {
        let defaults = makeDefaults()
        makeFeature(defaults).enable()

        let relaunched = makeFeature(defaults)
        #expect(relaunched.enabled)
        #expect(!relaunched.loaded)
        relaunched.appDidStart()
        #expect(relaunched.isActive)
    }

    @Test
    func appDidStartDoesNotReloadAfterManualUnload() {
        let feature = makeFeature()
        feature.enable()
        feature.unload()
        feature.appDidStart()
        #expect(!feature.loaded)
        #expect(!feature.isActive)
    }

    @Test
    func appDidStartDoesNothingWhenDisabled() {
        let feature = makeFeature()
        feature.appDidStart()
        #expect(!feature.isActive)
    }

    @Test
    func loadedStateIsNotPersisted() {
        let defaults = makeDefaults()
        let feature = makeFeature(defaults)
        feature.enable()
        feature.unload()

        let relaunched = makeFeature(defaults)
        #expect(relaunched.enabled)
        #expect(!relaunched.manuallyUnloaded)
        #expect(!relaunched.loaded)
    }

    // MARK: - pluginkit parsing

    private nonisolated static let listing = """
    +    com.example.other.token(1.2)\t0F1E2D3C-0000-0000-0000-000000000001\t2026-10-01 09:00:00 +0000\t/Applications/Other.app/Contents/PlugIns/Token.appex
    +    io.wsagency.smartcard.ctk(1.0)\t0F1E2D3C-0000-0000-0000-000000000002\t2026-10-15 09:00:00 +0000\t/Applications/WSurf.app/Contents/PlugIns/SmartCardToken.appex
    """

    @Test
    func parsesRegisteredExtension() {
        #expect(SmartCardFeature.ctkStatus(fromPluginKit: Self.listing) == .registered)
    }

    @Test
    func parsesAbsentExtension() {
        let others = Self.listing.split(separator: "\n").prefix(1).joined(separator: "\n")
        #expect(SmartCardFeature.ctkStatus(fromPluginKit: others) == .notInstalled)
        #expect(SmartCardFeature.ctkStatus(fromPluginKit: "(no matches)\n") == .notInstalled)
    }

    @Test
    func doesNotMatchLookalikeIdentifier() {
        let lookalike = "+    io.wsagency.smartcard.ctk.helper(1.0)\tUUID\tdate\t/path"
        #expect(SmartCardFeature.ctkStatus(fromPluginKit: lookalike) == .notInstalled)
    }

    @Test
    func garbageIsUnknown() {
        #expect(SmartCardFeature.ctkStatus(fromPluginKit: "") == .unknown)
        #expect(SmartCardFeature.ctkStatus(fromPluginKit: "pluginkit: error\nsomething went wrong") == .unknown)
    }

    @Test
    func refreshUsesInjectedRunner() async {
        let found = makeFeature(pluginKit: { Self.listing })
        await found.refreshCTKStatus()
        #expect(found.ctkStatus == .registered)
        #expect(!found.isCheckingCTK)

        let failed = makeFeature(pluginKit: { nil })
        await failed.refreshCTKStatus()
        #expect(failed.ctkStatus == .unknown)
    }
}
