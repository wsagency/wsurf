// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized)
struct ExtensionUpdateTests {
    private let key = "extensions.lastUpdateCheck"

    private func scratchDefaults() -> UserDefaults {
        let suite = AppDatabase.defaultsSuite("io.wsagency.wsurf.tests.\(UUID().uuidString)")
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private func manager(_ defaults: UserDefaults, profile: Profile? = nil) -> ExtensionManager {
        ExtensionManager.defaults = defaults
        return ExtensionManager(profile: profile)
    }

    @Test func theFirstLaunchOfTheDayTakesTheSweep() async {
        let defaults = scratchDefaults()
        defer { ExtensionManager.defaults = .standard }
        let extensions = manager(defaults)

        await extensions.updateInstalledIfDue()

        #expect(defaults.object(forKey: key) is Date, "the sweep records when it ran")
    }

    @Test func aSweepAnHourOldIsNotDueAgain() async {
        let defaults = scratchDefaults()
        defer { ExtensionManager.defaults = .standard }
        let anHourAgo = Date().addingTimeInterval(-3_600)
        defaults.set(anHourAgo, forKey: key)
        let extensions = manager(defaults)

        await extensions.updateInstalledIfDue()

        #expect(defaults.object(forKey: key) as? Date == anHourAgo, "the stamp is left where it was")
    }

    @Test func aSweepFromYesterdayIsDue() async {
        let defaults = scratchDefaults()
        defer { ExtensionManager.defaults = .standard }
        let yesterday = Date().addingTimeInterval(-90_000)
        defaults.set(yesterday, forKey: key)
        let extensions = manager(defaults)

        await extensions.updateInstalledIfDue()

        let stamped = defaults.object(forKey: key) as? Date
        #expect(stamped != nil)
        #expect((stamped ?? .distantPast) > yesterday, "a day later the sweep runs again")
    }

    @Test func theSweepJudgesTheClockItIsGiven() async {
        let defaults = scratchDefaults()
        defer { ExtensionManager.defaults = .standard }
        let now = Date()
        defaults.set(now, forKey: key)
        let extensions = manager(defaults)

        await extensions.updateInstalledIfDue(now: now.addingTimeInterval(60))
        #expect(defaults.object(forKey: key) as? Date == now)

        await extensions.updateInstalledIfDue(now: now.addingTimeInterval(86_401))
        #expect(defaults.object(forKey: key) as? Date != now)
    }

    @Test func anExtensionThatIsNotInstalledIsNotChecked() async {
        let defaults = scratchDefaults()
        defer { ExtensionManager.defaults = .standard }
        let extensions = manager(defaults)

        await extensions.checkForUpdate(id: "not-installed")

        #expect(extensions.updateChecks["not-installed"] == nil, "nothing to report about nothing")
    }

    // MARK: - What an update adds

    private func webExtension(_ manifest: String) async throws -> WKWebExtension {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-ext-update-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try Data(#"{"manifest_version":3,"name":"Update","version":"1.0",\#(manifest)}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        return try await WKWebExtension(resourceBaseURL: package)
    }

    @Test func anUpdateAskingForTheSameAccessAddsNothing() async throws {
        let manifest = #""permissions":["storage"],"host_permissions":["*://*.twitch.tv/*"]"#
        let added = ExtensionManager.access(
            in: try await webExtension(manifest),
            beyond: try await webExtension(manifest)
        )
        #expect(added.isEmpty)
    }

    @Test func anUpdateAskingForLessAccessAddsNothing() async throws {
        let added = ExtensionManager.access(
            in: try await webExtension(#""permissions":["storage"],"host_permissions":["*://*.twitch.tv/*"]"#),
            beyond: try await webExtension(
                #""permissions":["storage","cookies"],"host_permissions":["*://*.twitch.tv/*","*://*.example.com/*"]"#
            )
        )
        #expect(added.isEmpty)
    }

    @Test func anUpdateAskingForEveryWebsiteAddsWebsites() async throws {
        let added = ExtensionManager.access(
            in: try await webExtension(#""host_permissions":["*://*.twitch.tv/*","<all_urls>"]"#),
            beyond: try await webExtension(#""host_permissions":["*://*.twitch.tv/*"]"#)
        )
        #expect(added.permissions.isEmpty)
        #expect(added.websites.count == 1)
        #expect(added.websites.first?.matchesAllURLs == true)
    }

    @Test func aWebsiteInsideAnApprovedPatternIsNotNew() async throws {
        let added = ExtensionManager.access(
            in: try await webExtension(#""host_permissions":["*://clips.twitch.tv/*"]"#),
            beyond: try await webExtension(#""host_permissions":["<all_urls>"]"#)
        )
        #expect(added.isEmpty)
    }

    @Test func aContentScriptOnANewWebsiteCounts() async throws {
        let added = ExtensionManager.access(
            in: try await webExtension(#""content_scripts":[{"matches":["*://*.example.com/*"],"js":["a.js"]}]"#),
            beyond: try await webExtension(#""host_permissions":["*://*.twitch.tv/*"]"#)
        )
        #expect(added.permissions.isEmpty)
        #expect(added.websites.map(\.string) == ["*://*.example.com/*"])
    }

    @Test func anUpdateAskingForANewPermissionAddsIt() async throws {
        let added = ExtensionManager.access(
            in: try await webExtension(#""permissions":["storage","cookies"]"#),
            beyond: try await webExtension(#""permissions":["storage"]"#)
        )
        #expect(added.permissions.map(\.rawValue) == ["cookies"])
        #expect(added.websites.isEmpty)
    }

    @Test func anUpdateThatAddsAnExternalWebsiteAddsWebsites() async throws {
        let added = ExtensionManager.access(
            in: try await webExtension(#""externally_connectable":{"matches":["*://*.example.com/*"]}"#),
            beyond: try await webExtension(#""permissions":["storage"]"#)
        )
        #expect(added.websites.map(\.string) == ["*://*.example.com/*"])
    }

    @Test func withoutAnApprovedPackageEverythingIsNew() async throws {
        let added = ExtensionManager.access(
            in: try await webExtension(#""permissions":["storage"],"host_permissions":["*://*.twitch.tv/*"]"#),
            beyond: nil
        )
        #expect(added.permissions.map(\.rawValue) == ["storage"])
        #expect(added.websites.map(\.string) == ["*://*.twitch.tv/*"])
    }

    // MARK: - Apple Passwords

    /// The official Chrome 3.4.0 package, as the store serves it and as the shim reshapes it
    /// before the first load.
    private func applePasswordsPackage(version: String = "3.4.0") throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-ext-update-apple-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(ExtensionShims.applePasswordsID, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "key": ExtensionShims.applePasswordsPublicKey,
            "manifest_version": 3,
            "version": version,
            "name": "Apple Passwords",
            "description": "Update gate regression",
            "action": ["default_popup": "page_popup.html"],
            "background": ["service_worker": "background.js"],
            "permissions": ["nativeMessaging", "storage", "scripting"],
            "host_permissions": ["*://*/*"],
            "web_accessible_resources": [["matches": ["<all_urls>"], "resources": ["completion_list.html"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: package.appendingPathComponent("manifest.json"))
        try """
        function disconnected() {
            chrome.runtime.lastError?.message;setTimeout((()=>{const e=chrome.runtime.lastError?.message;}),1000);
        }
        async function inject(i,r,e) {
            await chrome.scripting.executeScript({target:{tabId:i,allFrames:e},files:r.js});
            return chrome.webNavigation.getAllFrames({tabId:i});
        }
        """.write(to: package.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        for page in ["page_popup.html", "completion_list.html"] {
            try "<!doctype html><title>Page</title>"
                .write(to: package.appendingPathComponent(page), atomically: true, encoding: .utf8)
        }
        return package
    }

    @Test func anApplePasswordsUpdateStillAsksOnlyForScripting() async throws {
        let installedPackage = try applePasswordsPackage()
        let updatePackage = try applePasswordsPackage(version: "3.4.1")
        defer {
            try? FileManager.default.removeItem(at: installedPackage.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: updatePackage.deletingLastPathComponent())
        }
        #expect(ExtensionShims.prepareApplePasswordsPersistent(at: installedPackage) == .converted)

        let added = ExtensionManager.access(
            in: try await WKWebExtension(resourceBaseURL: updatePackage),
            beyond: try await WKWebExtension(resourceBaseURL: installedPackage)
        )

        #expect(added.permissions.map(\.rawValue) == ["scripting"], "the shim drops it, so the store package asks again")
        #expect(added.websites.isEmpty, "the folded host pattern still covers the store package's host permission")
    }

    // MARK: - The update flow

    private func zipped(_ contents: URL) throws -> Data {
        let archive = contents.deletingLastPathComponent()
            .appendingPathComponent("package-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", contents.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: archive) }
        return try Data(contentsOf: archive)
    }

    private func zippedPackage(version: String, access: String) throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-ext-update-zip-\(UUID().uuidString)", isDirectory: true)
        let contents = scratch.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data(#"{"manifest_version":3,"name":"Update","version":"\#(version)",\#(access)}"#.utf8)
            .write(to: contents.appendingPathComponent("manifest.json"))
        return try zipped(contents)
    }

    @MainActor private struct Installed {
        let manager: ExtensionManager
        let directory: URL

        func tearDown() {
            manager.stop()
            try? FileManager.default.removeItem(at: directory)
            ExtensionManager.defaults = .standard
            ExtensionManager.downloadPackage = ExtensionManager.downloadPackageFromStore
            ExtensionManager.confirmAddedAccess = ExtensionManager.askForAddedAccess
        }
    }

    /// Installs `installedPackage` and makes the store offer `update`.
    /// A disabled extension is never loaded, so its update is judged by the package on disk.
    private func install(
        id: String,
        package installedPackage: Data,
        serving update: Data,
        version: String = "1.0",
        enabled: Bool = true,
        defaults: UserDefaults
    ) async throws -> Installed {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-ext-update-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = ExtensionLibrary(baseDirectory: directory, profile: .original())
        library.load()
        library.recordInstall(id: id)
        try await library.unpack(installedPackage, id: id)
        library.updateMetadata(id: id, name: "Update", version: version)
        library.setEnabled(enabled, id: id)

        ExtensionManager.defaults = defaults
        ExtensionManager.downloadPackage = { _ in update }
        let manager = ExtensionManager(profile: .original(), library: library)
        await manager.start()
        return Installed(manager: manager, directory: directory)
    }

    private let twitch = #""host_permissions":["*://*.twitch.tv/*"]"#
    private let twitchAndEveryWebsite = #""host_permissions":["*://*.twitch.tv/*","<all_urls>"]"#

    @MainActor private final class Prompts {
        var permissions: [Set<String>] = []
        var websites: [Set<String>] = []
        var count: Int {
            permissions.count
        }
    }

    private func answerPrompts(with answer: Bool) -> Prompts {
        let prompts = Prompts()
        ExtensionManager.confirmAddedAccess = { _, permissions, websites in
            prompts.permissions.append(Set(permissions.map(\.rawValue)))
            prompts.websites.append(Set(websites.map(\.string)))
            return answer
        }
        return prompts
    }

    @Test func aQuietUpdateAskingForMoreWebsitesWaitsForApproval() async throws {
        let id = "update-needs-access"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "2.0", access: twitchAndEveryWebsite),
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }
        let prompts = answerPrompts(with: true)

        await installed.manager.checkForUpdate(id: id, quietly: true)

        #expect(installed.manager.heldUpdates[id] == "2.0")
        #expect(installed.manager.installedRecord(id: id)?.version == "1.0", "the old version keeps running")
        #expect(installed.manager.updateChecks[id] == nil, "a quiet check reports nothing")
        #expect(prompts.count == 0, "a quiet check never asks")
    }

    @Test func aQuietUpdateOfAnExtensionThatIsOffIsJudgedByItsPackageOnDisk() async throws {
        let id = "update-off-needs-access"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "2.0", access: twitchAndEveryWebsite),
            enabled: false,
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }

        #expect(installed.manager.contexts[id] == nil, "nothing is running to compare with")
        await installed.manager.checkForUpdate(id: id, quietly: true)

        #expect(installed.manager.heldUpdates[id] == "2.0")
        #expect(installed.manager.installedRecord(id: id)?.version == "1.0")
    }

    @Test func aQuietUpdateOfAnExtensionThatIsOffInstallsWhenItAsksForNothingNew() async throws {
        let id = "update-off-same-access"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "2.0", access: twitch),
            enabled: false,
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }

        await installed.manager.checkForUpdate(id: id, quietly: true)

        #expect(installed.manager.installedRecord(id: id)?.version == "2.0")
        #expect(installed.manager.heldUpdates[id] == nil)
    }

    @Test func aQuietUpdateAskingForNothingNewInstalls() async throws {
        let id = "update-same-access"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "2.0", access: twitch),
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }

        await installed.manager.checkForUpdate(id: id, quietly: true)

        #expect(installed.manager.installedRecord(id: id)?.version == "2.0")
        #expect(installed.manager.heldUpdates[id] == nil)
        #expect(installed.manager.updateChecks[id] == .updated("2.0"))
    }

    @Test func aQuietUpdateAskingForLessAccessInstalls() async throws {
        let id = "update-less-access"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitchAndEveryWebsite),
            serving: try zippedPackage(version: "2.0", access: twitch),
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }

        await installed.manager.checkForUpdate(id: id, quietly: true)

        #expect(installed.manager.installedRecord(id: id)?.version == "2.0")
        #expect(installed.manager.heldUpdates[id] == nil)
    }

    @Test func aManualUpdateAsksAboutOnlyWhatIsAdded() async throws {
        let id = "update-asks-added"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: #""permissions":["storage"],\#(twitch)"#),
            serving: try zippedPackage(
                version: "2.0",
                access: #""permissions":["storage","cookies"],"host_permissions":["*://*.twitch.tv/*","*://*.example.com/*"]"#
            ),
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }
        let prompts = answerPrompts(with: true)

        await installed.manager.checkForUpdate(id: id)

        #expect(prompts.permissions == [["cookies"]], "storage was already approved")
        #expect(prompts.websites == [["*://*.example.com/*"]], "twitch.tv was already approved")
        #expect(installed.manager.installedRecord(id: id)?.version == "2.0")
        #expect(installed.manager.heldUpdates[id] == nil)
        #expect(installed.manager.updateChecks[id] == .updated("2.0"))
    }

    @Test func aManualUpdateThatIsRefusedStaysOut() async throws {
        let id = "update-refused"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "2.0", access: twitchAndEveryWebsite),
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }
        installed.manager.setHeldUpdate("2.0", id: id)
        let prompts = answerPrompts(with: false)

        await installed.manager.checkForUpdate(id: id)

        #expect(prompts.count == 1)
        #expect(installed.manager.installedRecord(id: id)?.version == "1.0")
        #expect(installed.manager.heldUpdates[id] == nil, "the person answered, so the tag goes")
        #expect(installed.manager.updateChecks[id] == nil)
    }

    @Test func aManualUpdateAskingForNothingNewDoesNotAsk() async throws {
        let id = "update-approved"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "2.0", access: twitch),
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }
        installed.manager.setHeldUpdate("2.0", id: id)
        let prompts = answerPrompts(with: false)

        await installed.manager.checkForUpdate(id: id)

        #expect(prompts.count == 0)
        #expect(installed.manager.installedRecord(id: id)?.version == "2.0")
        #expect(installed.manager.heldUpdates[id] == nil)
    }

    @Test func aHeldUpdateIsForgottenOnceTheStoreNoLongerOffersIt() async throws {
        let id = "update-withdrawn"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "1.0", access: twitch),
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }
        installed.manager.setHeldUpdate("2.0", id: id)

        await installed.manager.checkForUpdate(id: id, quietly: true)

        #expect(installed.manager.heldUpdates[id] == nil)
        #expect(ExtensionManager.savedHeldUpdates(for: .original())[id] == nil, "the saved list forgets it too")
    }

    @Test func anApplePasswordsUpdateStaysHeldAndAsksOnlyForScripting() async throws {
        let id = ExtensionShims.applePasswordsID
        let installedPackage = try applePasswordsPackage()
        let updatePackage = try applePasswordsPackage(version: "3.4.1")
        defer {
            try? FileManager.default.removeItem(at: installedPackage.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: updatePackage.deletingLastPathComponent())
        }
        // `load` reshapes the package before the first run; an off extension keeps that shape on disk.
        let installed = try await install(
            id: id,
            package: try zipped(installedPackage),
            serving: try zipped(updatePackage),
            version: "3.4.0",
            enabled: false,
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }
        #expect(ExtensionShims.prepareApplePasswordsPersistent(
            at: installed.manager.packageURL(for: id)
        ) == .converted)

        await installed.manager.checkForUpdate(id: id, quietly: true)
        #expect(installed.manager.heldUpdates[id] == "3.4.1", "a quiet update is held, as before")
        #expect(installed.manager.installedRecord(id: id)?.version == "3.4.0")

        let prompts = answerPrompts(with: false)
        await installed.manager.checkForUpdate(id: id)
        #expect(prompts.permissions == [["scripting"]])
        #expect(prompts.websites == [[]], "the website it already reaches is not asked about again")
        #expect(installed.manager.installedRecord(id: id)?.version == "3.4.0")
    }

    // MARK: - Held updates

    @Test func aHeldUpdateIsRememberedUntilCleared() {
        let defaults = scratchDefaults()
        defer { ExtensionManager.defaults = .standard }
        manager(defaults).setHeldUpdate("2.0", id: "held")

        let relaunched = manager(defaults)
        #expect(relaunched.heldUpdates == ["held": "2.0"])

        relaunched.setHeldUpdate(nil, id: "held")
        #expect(manager(defaults).heldUpdates.isEmpty)
    }

    @Test func aHeldUpdateBelongsToTheProfileThatHeldIt() {
        let defaults = scratchDefaults()
        defer { ExtensionManager.defaults = .standard }
        let work = Profile(id: UUID(), name: "Work", symbol: "person", color: .gray)
        manager(defaults, profile: .original()).setHeldUpdate("2.0", id: "held")
        manager(defaults, profile: work).setHeldUpdate("3.0", id: "held")

        #expect(manager(defaults, profile: .original()).heldUpdates == ["held": "2.0"])
        #expect(manager(defaults, profile: work).heldUpdates == ["held": "3.0"])

        ExtensionManager.forgetHeldUpdates(for: work)
        #expect(manager(defaults, profile: work).heldUpdates.isEmpty)
        #expect(manager(defaults, profile: .original()).heldUpdates == ["held": "2.0"])
    }

    @Test func aPrivateProfileHoldsUpdatesOnlyInMemory() {
        let defaults = scratchDefaults()
        defer { ExtensionManager.defaults = .standard }
        let privateManager = manager(defaults, profile: .privateBrowsing())

        privateManager.setHeldUpdate("2.0", id: "held")

        #expect(privateManager.heldUpdates == ["held": "2.0"])
        #expect(manager(defaults, profile: .privateBrowsing()).heldUpdates.isEmpty)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("extensions.heldUpdates") })
    }

    @Test func aHeldUpdateThatAnInstallHasPassedIsNotShown() async throws {
        let id = "update-passed"
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "1.0", access: twitch),
            defaults: scratchDefaults()
        )
        defer { installed.tearDown() }
        let record = try #require(installed.manager.installedRecord(id: id))

        installed.manager.setHeldUpdate("2.0", id: id)
        #expect(installed.manager.heldUpdate(for: record) == "2.0")

        installed.manager.setHeldUpdate("1.0", id: id)
        #expect(installed.manager.heldUpdate(for: record) == nil, "version 1.0 is not newer than the installed 1.0")
    }

    @Test func uninstallingForgetsAHeldUpdate() async throws {
        let id = "update-uninstalled"
        let defaults = scratchDefaults()
        let installed = try await install(
            id: id,
            package: try zippedPackage(version: "1.0", access: twitch),
            serving: try zippedPackage(version: "2.0", access: twitchAndEveryWebsite),
            defaults: defaults
        )
        defer { installed.tearDown() }
        installed.manager.setHeldUpdate("2.0", id: id)

        installed.manager.uninstall(id: id)

        #expect(installed.manager.heldUpdates[id] == nil)
        #expect(ExtensionManager.savedHeldUpdates(for: .original()).isEmpty)
    }
}
