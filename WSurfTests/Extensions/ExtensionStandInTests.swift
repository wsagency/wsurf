// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The stand-in block as builds before the end marker wrote it into a service worker.
private let legacyGapsSource = """
    // wsurf-api-gaps
    (() => {
        "use strict";
        try {
            const silent = () => ({ addListener() {}, removeListener() {}, hasListener: () => false });
            const roots = [
                typeof browser === "object" ? browser : null,
                typeof chrome === "object" ? chrome : null,
            ];
            for (const api of new Set(roots)) {
                if (!api) {
                    continue;
                }
                api.privacy ||= { network: {}, services: {}, websites: {} };
            }
        } catch (e) {
        }
    })();
    """

/// The permissions of the official Apple Passwords 3.4.0 package for Chrome.
private let applePasswordsPermissions = [
    "privacy", "declarativeContent", "nativeMessaging", "webNavigation", "storage", "contextMenus", "scripting",
]

/// What the stand-ins do to a package on disk: where they go, where they must not go, and what stays as it was.
struct ExtensionStandInPackageTests {
    private func makePackage(
        manifest: [String: Any],
        named name: String = UUID().uuidString,
        files: [String: String] = [:]
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))
        for (path, text) in files {
            try write(text, to: path, in: directory)
        }
        return directory
    }

    private func write(_ text: String, to path: String, in package: URL) throws {
        let url = package.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func text(_ path: String, in package: URL) throws -> String {
        try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
    }

    private func data(_ path: String, in package: URL) throws -> Data {
        try Data(contentsOf: package.appendingPathComponent(path))
    }

    private let tag = "<script src=\"/\(ExtensionShims.gapsFileName)\"></script>"

    @Test func everyHTMLPageGetsTheStandInsOnceWhetherOrNotTheManifestNamesIt() throws {
        let page = "<!doctype html><html><head><title>T</title></head><body></body></html>"
        let package = try makePackage(
            manifest: ["manifest_version": 3, "action": ["default_popup": "popup.html"]],
            files: [
                "popup.html": page, "panel/side.html": page, "frames/deep/frame.htm": page,
                "docs/ABOUT.HTML": page, "notes.txt": "not a page",
            ]
        )
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(ExtensionShims.ensureGapsApplied(at: package))
        for path in ["popup.html", "panel/side.html", "frames/deep/frame.htm", "docs/ABOUT.HTML"] {
            #expect(try text(path, in: package).contains("<head>" + tag + "<title>"), "\(path)")
        }
        #expect(try text("notes.txt", in: package) == "not a page")
        #expect(try text(ExtensionShims.gapsFileName, in: package) == ExtensionShims.gapsSource)

        let once = try ["popup.html", "panel/side.html", "frames/deep/frame.htm"].map { try text($0, in: package) }
        #expect(ExtensionShims.ensureGapsApplied(at: package))
        let twice = try ["popup.html", "panel/side.html", "frames/deep/frame.htm"].map { try text($0, in: package) }
        #expect(once == twice)
        #expect(once.allSatisfy { $0.components(separatedBy: tag).count == 2 })
    }

    @Test func aPackageWithoutPagesOrAWorkerGetsNothing() throws {
        let package = try makePackage(manifest: ["manifest_version": 3], files: ["content.js": "// nothing"])
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(!ExtensionShims.ensureGapsApplied(at: package))
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent(ExtensionShims.gapsFileName).path))
        #expect(try text("content.js", in: package) == "// nothing")
    }

    @Test func aPageThatIsASymlinkOutOfThePackageIsLeftAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("pkg", isDirectory: true)
        let sibling = root.appendingPathComponent("pkg-evil", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [package, sibling, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try JSONSerialization.data(withJSONObject: [
            "manifest_version": 3, "action": ["default_popup": "popup.html"],
        ]).write(to: package.appendingPathComponent("manifest.json"))
        let secret = "<html><head></head><body>outside the package</body></html>"
        try secret.write(to: outside.appendingPathComponent("secret.html"), atomically: true, encoding: .utf8)
        try secret.write(to: sibling.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        // A declared page, an undeclared one, a directory and a page in a sibling whose name starts with the package's.
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("popup.html"), withDestinationURL: outside.appendingPathComponent("secret.html")
        )
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("other.html"), withDestinationURL: outside.appendingPathComponent("secret.html")
        )
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("evil.html"), withDestinationURL: sibling.appendingPathComponent("page.html")
        )

        #expect(!ExtensionShims.ensureGapsApplied(at: package))
        #expect(try String(contentsOf: outside.appendingPathComponent("secret.html"), encoding: .utf8) == secret)
        #expect(try String(contentsOf: sibling.appendingPathComponent("page.html"), encoding: .utf8) == secret)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent(ExtensionShims.gapsFileName).path))
        for link in ["popup.html", "other.html", "evil.html"] {
            let destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: package.appendingPathComponent(link).path
            )
            #expect(!destination.isEmpty, "\(link) is still a link")
        }
    }

    @Test func aServiceWorkerThatIsASymlinkOutOfThePackageIsLeftAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("pkg", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "manifest_version": 3, "background": ["service_worker": "sw.js"],
        ]).write(to: package.appendingPathComponent("manifest.json"))
        let outside = root.appendingPathComponent("outside.js")
        try "outside();\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("sw.js"), withDestinationURL: outside)

        #expect(!ExtensionShims.ensureGapsApplied(at: package))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside();\n")
    }

    @Test func aWorkerFromAnEarlierBuildPicksUpTheCurrentStandIns() throws {
        let worker = "chrome.runtime.onConnect.addListener(() => {});\n"
        let package = try makePackage(
            manifest: ["manifest_version": 3, "background": ["service_worker": "sw.js"]],
            files: ["sw.js": legacyGapsSource + "\n" + worker]
        )
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(ExtensionShims.ensureGapsApplied(at: package))
        let upgraded = try text("sw.js", in: package)
        #expect(upgraded == ExtensionShims.gapsSource + "\n" + worker)
        #expect(upgraded.components(separatedBy: "// wsurf-api-gaps\n").count == 2)

        #expect(ExtensionShims.ensureGapsApplied(at: package))
        #expect(try text("sw.js", in: package) == upgraded)
    }

    @Test func aWorkerWithACurrentBlockAndAnEmptyBodyIsStable() throws {
        let package = try makePackage(
            manifest: ["manifest_version": 3, "background": ["service_worker": "sw.js"]],
            files: ["sw.js": ""]
        )
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(ExtensionShims.ensureGapsApplied(at: package))
        let once = try text("sw.js", in: package)
        #expect(once == ExtensionShims.gapsSource + "\n")
        #expect(ExtensionShims.ensureGapsApplied(at: package))
        #expect(try text("sw.js", in: package) == once)
    }

    @Test func aBlockWhoseEndCannotBeFoundIsNotTouched() throws {
        let damaged = "// wsurf-api-gaps\n(() => { /* truncated */\nrun();\n"
        let package = try makePackage(
            manifest: ["manifest_version": 3, "background": ["service_worker": "sw.js"]],
            files: ["sw.js": damaged]
        )
        defer { try? FileManager.default.removeItem(at: package) }

        _ = ExtensionShims.ensureGapsApplied(at: package)
        #expect(try text("sw.js", in: package) == damaged)
    }

    @MainActor
    @Test func theStandInsNeverRewriteTheManifestOrChangeWhatTheExtensionAsksFor() async throws {
        let package = try makePackage(
            manifest: [
                "manifest_version": 3, "name": "Asks", "version": "1.0", "description": "Access baseline",
                "permissions": ["storage", "sidePanel", "bookmarks", "privacy", "tabs"],
                "host_permissions": ["https://example.com/*"],
                "background": ["service_worker": "sw.js"],
                "action": ["default_popup": "popup.html"],
                "content_scripts": [["matches": ["https://example.org/*"], "js": ["content.js"]]],
            ],
            files: [
                "sw.js": "chrome.sidePanel.setPanelBehavior({});\n", "popup.html": "<html><head></head></html>",
                "panel.html": "<html><head></head></html>", "content.js": "// content",
            ]
        )
        defer { try? FileManager.default.removeItem(at: package) }
        let manifestBefore = try data("manifest.json", in: package)
        let before = try await WKWebExtension(resourceBaseURL: package)

        #expect(ExtensionShims.ensureGapsApplied(at: package))
        #expect(try data("manifest.json", in: package) == manifestBefore)
        let after = try await WKWebExtension(resourceBaseURL: package)

        #expect(after.requestedPermissions == before.requestedPermissions)
        #expect(after.allRequestedMatchPatterns == before.allRequestedMatchPatterns)
        #expect(ExtensionManager.access(in: after, beyond: before).isEmpty)
        #expect(ExtensionManager.access(in: before, beyond: after).isEmpty)
        #expect(try text("content.js", in: package) == "// content")
    }

    @MainActor
    @Test func theApplePasswordsAdaptationIsUntouchedByTheStandIns() async throws {
        let package = try makePackage(
            manifest: [
                "key": ExtensionShims.applePasswordsPublicKey, "manifest_version": 3, "version": "3.4.0",
                "name": "Apple fixture", "description": "Stand-ins beside the Apple Passwords adaptation",
                "action": ["default_popup": "page_popup.html"],
                "background": ["service_worker": "background.js"],
                "permissions": applePasswordsPermissions,
                "host_permissions": ["*://*/*"],
                "web_accessible_resources": [["matches": ["<all_urls>"], "resources": ["completion_list.html"]]],
            ],
            named: UUID().uuidString + "/" + ExtensionShims.applePasswordsID,
            files: [
                "background.js": """
                function disconnected() {
                    chrome.runtime.lastError?.message;setTimeout((()=>{const e=chrome.runtime.lastError?.message;}),1000);
                }
                async function inject(i,r,e) {
                    await chrome.scripting.executeScript({target:{tabId:i,allFrames:e},files:r.js});
                    return chrome.webNavigation.getAllFrames({tabId:i});
                }
                """,
                "page_popup.html": "<!doctype html><title>Popup</title>",
                "completion_list.html": "<!doctype html><title>Completion</title>",
                "settings.html": "<!doctype html><title>Settings</title>",
            ]
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }

        #expect(ExtensionShims.prepareApplePasswordsPersistent(at: package) == .converted)
        let manifest = try data("manifest.json", in: package)
        let worker = try data("background.js", in: package)
        let adaptation = try data("wsurf-apple-passwords.js", in: package)
        let before = try await WKWebExtension(resourceBaseURL: package)

        #expect(ExtensionShims.ensureGapsApplied(at: package))
        #expect(ExtensionShims.ensureGapsApplied(at: package))
        #expect(try data("manifest.json", in: package) == manifest)
        #expect(try data("background.js", in: package) == worker)
        #expect(try data("wsurf-apple-passwords.js", in: package) == adaptation)
        for page in ["page_popup.html", "completion_list.html", "settings.html"] {
            #expect(try text(page, in: package).components(separatedBy: tag).count == 2, "\(page)")
        }
        #expect(ExtensionShims.prepareApplePasswordsPersistent(at: package) == .alreadyConverted)
        #expect(try data("manifest.json", in: package) == manifest)

        let after = try await WKWebExtension(resourceBaseURL: package)
        #expect(after.hasPersistentBackgroundContent)
        #expect(after.requestedPermissions == before.requestedPermissions)
        #expect(after.allRequestedMatchPatterns == before.allRequestedMatchPatterns)
        #expect(ExtensionManager.access(in: after, beyond: before).isEmpty)
    }
}

/// What the stand-in script does once it runs, in a page world with a stubbed extension API.
@MainActor
@Suite(.boundedWebViews)
struct ExtensionStandInRuntimeTests {
    private func run(
        setup: String,
        body: String,
        shim: String = ExtensionShims.gapsSource,
        arguments: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<!doctype html><title>Stand-in test</title>", baseURL: nil)
        try #require(await PageSettle.untilIdle(
            BrowserPage(webKit: view, context: BrowserProfileContext(profile: .privateBrowsing())),
            timeout: .seconds(20)
        ))
        let result = try await view.callAsyncJavaScript(
            setup + "\n" + shim + "\n" + body,
            arguments: arguments, in: nil, contentWorld: .page
        )
        return try #require(result as? [String: Any])
    }

    private func json(_ values: [String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }

    @Test func everyMeasuredMissingEventGetsASilentOneAndNativeOnesStay() async throws {
        let members = ExtensionCompatibility.unsupportedMembers.sorted()
        let list = try json(members)
        let result = try await run(setup: """
        const members = \(list);
        const browser = {};
        for (const member of members) browser[member.split(".")[0]] = {};
        const native = { addListener() {}, removeListener() {}, hasListener: () => true };
        browser.runtime.onSuspend = native;
        """, body: """
        const problems = [];
        for (const member of members) {
            const [namespace, event] = member.split(".");
            const value = browser[namespace][event];
            if (!value || value.hasListener(() => {}) !== (member === "runtime.onSuspend")) problems.push(member);
            else { value.addListener(() => {}); value.removeListener(() => {}); }
        }
        return {
            problems, kept: browser.runtime.onSuspend === native,
            namespaces: Object.keys(browser).sort().join()
        };
        """)
        let namespaces = Set(members.map { String($0.split(separator: ".")[0]) }).sorted().joined(separator: ",")
        #expect((result["problems"] as? [String]) == [])
        #expect(result["kept"] as? Bool == true)
        #expect(result["namespaces"] as? String == namespaces)
    }

    @Test func anEventOnANamespaceWebKitLacksIsNotInvented() async throws {
        let result = try await run(setup: "const browser = {}; const chrome = browser;", body: """
        return { keys: Object.keys(browser).length };
        """)
        #expect(result["keys"] as? Int == 0)
    }

    @Test func managedStorageIsEmptyReadOnlyAndAnswersDefaults() async throws {
        let result = try await run(setup: "const browser = { storage: { local: {} } };", body: """
        const managed = browser.storage.managed;
        const fail = async call => { try { await call(); return null; } catch (error) { return error.message; } };
        const calledBackOnFailure = await new Promise(resolve => managed.set({ a: 1 }, (...args) => resolve(args.length === 1 && args[0] === undefined)));
        return {
            none: Object.keys(await managed.get(null)).length,
            named: Object.keys(await managed.get("policy")).length,
            listed: Object.keys(await managed.get(["policy"])).length,
            defaults: JSON.stringify(await managed.get({ policy: "fallback", nested: { a: 1 } })),
            calledBack: Object.keys(await new Promise(resolve => managed.get("policy", resolve))).length,
            bytes: await managed.getBytesInUse(null),
            keys: (await managed.getKeys()).length,
            set: await fail(() => managed.set({ policy: 1 })),
            remove: await fail(() => managed.remove("policy")),
            clear: await fail(() => managed.clear()),
            calledBackOnFailure,
            listening: managed.onChanged.hasListener(() => {})
        };
        """)
        #expect(result["none"] as? Int == 0)
        #expect(result["named"] as? Int == 0)
        #expect(result["listed"] as? Int == 0)
        #expect(result["defaults"] as? String == #"{"policy":"fallback","nested":{"a":1}}"#)
        #expect(result["calledBack"] as? Int == 0)
        #expect(result["bytes"] as? Int == 0)
        #expect(result["keys"] as? Int == 0)
        for call in ["set", "remove", "clear"] {
            #expect(result[call] as? String == "This is a read-only store.", "\(call)")
        }
        #expect(result["calledBackOnFailure"] as? Bool == true)
        #expect(result["listening"] as? Bool == false)
    }

    @Test func aRealManagedStorageIsKeptAndWithoutStorageThereIsNone() async throws {
        let result = try await run(setup: """
        const managed = { get: async () => ({ policy: 1 }) };
        const browser = { storage: { managed } };
        const chrome = { runtime: {} };
        """, body: """
        return { kept: browser.storage.managed === managed, none: "storage" in chrome };
        """)
        #expect(result["kept"] as? Bool == true)
        #expect(result["none"] as? Bool == false)
    }

    @Test func aDeclaredAPIWebKitDropsFailsWithoutThrowing() async throws {
        let result = try await run(setup: """
        const tabs = { query: async () => [] };
        const browser = {
            tabs,
            runtime: { getManifest: () => ({ permissions: [
                "sidePanel", "bookmarks", "system.cpu", "downloads", "tabs", "activeTab", "https://example.com/*", "<all_urls>"
            ] }) }
        };
        """, body: """
        let failure;
        try { await browser.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }); }
        catch (error) { failure = error.message; }
        const calledBack = await new Promise(resolve => browser.bookmarks.getTree(value => resolve(value === undefined)));
        browser.bookmarks.onCreated.addListener(() => {});
        const awaited = await Promise.resolve(browser.sidePanel);
        return {
            failure, calledBack,
            silent: browser.bookmarks.onCreated.hasListener(() => {}) === false,
            awaited: awaited === browser.sidePanel,
            nested: typeof browser.system.cpu.getInfo,
            downloads: "downloads" in browser,
            activeTab: "activeTab" in browser,
            patterns: Object.keys(browser).sort().join(),
            tabsKept: browser.tabs === tabs
        };
        """)
        #expect(result["failure"] as? String == "sidePanel.setPanelBehavior() isn't supported in WSurf.")
        #expect(result["calledBack"] as? Bool == true)
        #expect(result["silent"] as? Bool == true)
        #expect(result["awaited"] as? Bool == true)
        #expect(result["nested"] as? String == "function")
        #expect(result["downloads"] as? Bool == false)
        #expect(result["activeTab"] as? Bool == false)
        #expect(result["patterns"] as? String == "bookmarks,runtime,sidePanel,system,tabs")
        #expect(result["tabsKept"] as? Bool == true)
    }

    @Test func anUndeclaredAPIStaysMissing() async throws {
        let result = try await run(setup: """
        const storage = { local: {}, managed: {} };
        const browser = { storage, runtime: { getManifest: () => ({ permissions: ["storage"] }) } };
        """, body: """
        return { sidePanel: "sidePanel" in browser, bookmarks: "bookmarks" in browser, storageKept: browser.storage === storage };
        """)
        #expect(result["sidePanel"] as? Bool == false)
        #expect(result["bookmarks"] as? Bool == false)
        #expect(result["storageKept"] as? Bool == true)
    }

    @Test(arguments: [true, false])
    func privacyExistsOnlyForExtensionsThatAskForIt(declared: Bool) async throws {
        let result = try await run(setup: """
        const browser = { runtime: { getManifest: () => ({ permissions: \(declared ? #"["privacy"]"# : "[]") }) } };
        """, body: """
        return {
            present: "privacy" in browser,
            setting: browser.privacy ? browser.privacy.services.passwordSavingEnabled === undefined : null
        };
        """)
        #expect(result["present"] as? Bool == declared)
        if declared {
            #expect(result["setting"] as? Bool == true)
        }
    }

    @Test func aNativePrivacyAPIIsKept() async throws {
        let result = try await run(setup: """
        const nativePrivacy = { services: { passwordSavingEnabled: {} } };
        const browser = { privacy: nativePrivacy, runtime: { getManifest: () => ({ permissions: ["privacy"] }) } };
        """, body: "return { kept: browser.privacy === nativePrivacy, setting: Boolean(browser.privacy.services.passwordSavingEnabled) };")
        #expect(result["kept"] as? Bool == true)
        #expect(result["setting"] as? Bool == true)
    }

    @Test func browserAndChromeEachGetTheirOwnStandIns() async throws {
        let result = try await run(setup: """
        const permissions = ["sidePanel"];
        const browser = { runtime: { getManifest: () => ({ permissions }) } };
        const chrome = { runtime: { getManifest: () => ({ permissions }) } };
        """, body: """
        return {
            both: typeof browser.sidePanel.open === "function" && typeof chrome.sidePanel.open === "function",
            separate: browser.sidePanel !== chrome.sidePanel
        };
        """)
        #expect(result["both"] as? Bool == true)
        #expect(result["separate"] as? Bool == true)
    }

    /// Apple Passwords 3.4.0 guards `declarativeContent` and then builds rules with it. A stand-in would pass the
    /// guard and fail inside it, so the namespace has to stay absent. Its other guarded events must still pass.
    @Test func theApplePasswordsGuardsGoOnWorking() async throws {
        let permissions = try json(applePasswordsPermissions)
        let result = try await run(setup: """
        const calls = [];
        const browser = {
            webNavigation: { onCompleted: { addListener() {} } },
            runtime: { getManifest: () => ({ permissions: \(permissions) }) }
        };
        const chrome = browser;
        """, body: """
        let failure = null;
        try {
            chrome.declarativeContent && chrome.declarativeContent.onPageChanged.removeRules(void 0, () => calls.push("rules"));
            chrome.runtime.onSuspend && chrome.runtime.onSuspend.addListener(() => {});
            chrome.runtime.onSuspendCanceled && chrome.runtime.onSuspendCanceled.addListener(() => {});
            chrome.runtime.onUpdateAvailable && chrome.runtime.onUpdateAvailable.addListener(() => {});
            chrome.webNavigation.onTabReplaced.addListener(() => {});
            chrome.webNavigation.onHistoryStateUpdated.addListener(() => {});
            chrome.privacy.services.passwordSavingEnabled && calls.push("saving");
        } catch (error) { failure = error.message; }
        return {
            failure, calls: calls.length,
            declarativeContent: "declarativeContent" in chrome,
            nativeMessaging: "nativeMessaging" in chrome,
            privacy: Object.keys(chrome.privacy).sort().join()
        };
        """)
        #expect(result["failure"] is NSNull)
        #expect(result["calls"] as? Int == 0)
        #expect(result["declarativeContent"] as? Bool == false)
        #expect(result["nativeMessaging"] as? Bool == false)
        #expect(result["privacy"] as? String == "network,services,websites")
    }

    @Test func theStandInsRunWithinTheBackgroundScriptShimToo() async throws {
        let result = try await run(setup: """
        const browser = { runtime: { getManifest: () => ({ permissions: ["sidePanel"] }) } };
        """, body: """
        return { sidePanel: typeof browser.sidePanel.open, notifications: typeof browser.notifications.create };
        """, shim: ExtensionShims.source)
        #expect(result["sidePanel"] as? String == "function")
        #expect(result["notifications"] as? String == "function")
    }

    // MARK: - Security boundary

    /// A stand-in call may be made with any name and any arguments. It must reach no native API, no WSurf message
    /// handler and no network, and it must leave every native function as it was.
    @Test func callingAStandInReachesNoPrivilegedCode() async throws {
        let result = try await run(setup: """
        const touched = [];
        const spy = name => (...args) => { touched.push(name); return Promise.resolve("native"); };
        const nativeFunctions = {
            "tabs.create": spy("tabs.create"), "tabs.executeScript": spy("tabs.executeScript"),
            "runtime.sendMessage": spy("runtime.sendMessage"), "runtime.sendNativeMessage": spy("runtime.sendNativeMessage"),
            "runtime.connectNative": spy("runtime.connectNative"), "permissions.request": spy("permissions.request"),
            "permissions.contains": spy("permissions.contains"), "scripting.executeScript": spy("scripting.executeScript"),
            "storage.local.get": spy("storage.local.get"), "storage.local.set": spy("storage.local.set"),
        };
        const names = ["sidePanel", "bookmarks", "history", "management", "identity", "tabGroups", "topSites", "system.cpu"];
        const browser = {
            tabs: { create: nativeFunctions["tabs.create"], executeScript: nativeFunctions["tabs.executeScript"] },
            runtime: {
                getManifest: () => ({ permissions: [...names, "storage", "nativeMessaging", "scripting", "permissions"] }),
                sendMessage: nativeFunctions["runtime.sendMessage"], sendNativeMessage: nativeFunctions["runtime.sendNativeMessage"],
                connectNative: nativeFunctions["runtime.connectNative"],
            },
            permissions: { request: nativeFunctions["permissions.request"], contains: nativeFunctions["permissions.contains"] },
            scripting: { executeScript: nativeFunctions["scripting.executeScript"] },
            storage: { local: { get: nativeFunctions["storage.local.get"], set: nativeFunctions["storage.local.set"] } },
        };
        const chrome = browser;
        const before = Object.keys(browser).sort();
        const guard = (name, value) => { try { Object.defineProperty(globalThis, name, { value, configurable: true, writable: true }); } catch (e) {} };
        guard("fetch", spy("fetch"));
        guard("XMLHttpRequest", function () { touched.push("XMLHttpRequest"); });
        guard("postMessage", spy("postMessage"));
        guard("webkit", { messageHandlers: new Proxy({}, { get(target, key) { touched.push("webkit." + String(key)); return { postMessage() { touched.push("post"); } }; } }) });
        """, body: """
        const leaks = [];
        const call = async (label, run) => {
            try {
                const value = await run();
                if (value !== undefined && value !== "") leaks.push(label + " resolved " + JSON.stringify(value));
            } catch (error) {
                if (!(error instanceof Error)) leaks.push(label + " threw a non-error");
            }
        };
        for (const name of names) {
            const api = name.split(".").reduce((object, key) => object[key], browser);
            for (const method of ["create", "getAll", "open", "remove", "update", "getTree", "search", "get", "set", "launch", "then"]) {
                if (typeof api[method] === "function") {
                    await call(name + "." + method + " promise", () => api[method]({ url: "https://example.com", tabId: 1 }));
                    await call(name + "." + method + " callback", () => new Promise(resolve => api[method]({}, resolve)));
                }
            }
            for (const event of ["onChanged", "onCreated", "onRemoved", "onClicked"]) {
                api[event].addListener(() => {}); api[event].hasListener(() => {}); api[event].removeListener(() => {});
            }
            for (const inherited of ["constructor", "toString", "hasOwnProperty", "valueOf", "__proto__", "toJSON", "then"]) {
                void api[inherited];
            }
        }
        await browser.storage.managed.get(null);
        const after = Object.keys(browser).sort();
        const expected = [...new Set([...before, ...names.map(name => name.split(".")[0])])].sort();
        return {
            touched, leaks,
            nativeKept: ["tabs.create", "runtime.sendMessage", "runtime.sendNativeMessage", "permissions.request", "scripting.executeScript"]
                .every(key => key.split(".").reduce((object, part) => object[part], browser) === nativeFunctions[key]),
            topLevel: after.join() === expected.join(),
            extra: after.filter(key => !expected.includes(key))
        };
        """)
        #expect((result["touched"] as? [String]) == [], "\(result["touched"] ?? "")")
        #expect((result["leaks"] as? [String]) == [], "\(result["leaks"] ?? "")")
        #expect(result["nativeKept"] as? Bool == true)
        #expect(result["topLevel"] as? Bool == true, "\(result["extra"] ?? "")")
    }

    /// The names come from the extension's own manifest. A name that is a property of every object must not turn
    /// into a write on `Object`, on a prototype or on a native API.
    @Test func aManifestNameCannotWriteToPrototypesOrNativeAPIs() async throws {
        let result = try await run(setup: """
        const hostile = [
            "constructor", "constructor.polluted", "prototype.polluted", "toString", "hasOwnProperty.polluted",
            "valueOf.polluted", "then", "then.polluted", "isPrototypeOf", "x..y", ".x", "x.", "Capital", "a-b", "a_b", "__proto__", "__proto__.polluted",
        ];
        const snapshot = () => [Object.getOwnPropertyNames(Object.prototype).sort().join(), Object.getOwnPropertyNames(Object).sort().join(),
            Object.getOwnPropertyNames(Function.prototype).sort().join(), Object.getOwnPropertyNames(Array.prototype).sort().join()].join("|");
        const before = snapshot();
        const nativeConstructor = ({}).constructor;
        const browser = { runtime: { getManifest: () => ({ permissions: hostile }) } };
        """, body: """
        return {
            unchanged: snapshot() === before,
            polluted: ({}).polluted === undefined && Object.polluted === undefined && Function.polluted === undefined,
            constructorKept: browser.constructor === nativeConstructor,
            thenless: (await Promise.resolve(browser)) === browser && browser.then === undefined,
            keys: Object.keys(browser).sort().join()
        };
        """)
        #expect(result["unchanged"] as? Bool == true)
        #expect(result["polluted"] as? Bool == true)
        #expect(result["constructorKept"] as? Bool == true)
        #expect(result["thenless"] as? Bool == true)
        #expect(result["keys"] as? String == "runtime")
    }

    @Test func aManifestThatIsNotWhatItShouldBeChangesNothing() async throws {
        let result = try await run(setup: "const apply = new Function(\"browser\", \"chrome\", shim);", body: """
        const shapes = [undefined, null, "sidePanel", 7, { sidePanel: true }, [1, null, {}, ["bookmarks"]]];
        const apis = shapes.map(permissions => ({ runtime: { getManifest: () => ({ permissions }) } }));
        apis.push({ runtime: { getManifest: () => undefined } });
        apis.push({ runtime: { getManifest: () => null } });
        apis.push({ runtime: { getManifest: () => { throw new Error("no manifest"); } } });
        apis.push({ runtime: {} });
        apis.push({});
        for (const api of apis) apply(api, undefined);
        return { keys: apis.map(api => Object.keys(api).join()) };
        """, shim: "", arguments: ["shim": ExtensionShims.gapsSource])
        #expect((result["keys"] as? [String]) == Array(repeating: "runtime", count: 10) + [""])
    }

    /// The script is a fixed text. It must not name any way out of the page, so a later edit that adds one fails here.
    @Test func theStandInScriptNamesNoWayOutOfThePage() {
        let source = ExtensionShims.gapsSource
        let forbidden = [
            "webkit", "messageHandlers", "eval(", "Function(", "import(", "importScripts", "fetch", "XMLHttpRequest",
            "WebSocket", "postMessage", "sendMessage", "sendNativeMessage", "connectNative", "connect(", "permissions.request",
            "permissions.contains", "executeScript", "scripting", "tabs.create", "tabs.query", "localStorage", "indexedDB", "document", "location.", "navigator",
            "window.", "self.", "globalThis", "setTimeout", "setInterval", "Reflect.set", "defineProperty", "setPrototypeOf",
        ]
        #expect(forbidden.filter { source.contains($0) } == [])
        // The only thing it asks the extension API is the manifest's permission names.
        #expect(source.components(separatedBy: "getManifest").count == 2)
    }

    @Test func theNamespacesThatStayAbsentAreTheOnesOtherCodeRelyOn() {
        for name in ["downloads", "declarativeContent", "nativeMessaging", "activeTab", "identity.email"] {
            #expect(ExtensionShims.gapsSource.contains("\"\(name)\""), "\(name)")
        }
    }
}

/// A real extension in WebKit's own extension controller: the point of the stand-ins is that it starts.
@MainActor
@Suite(.boundedWebViews, .serialized)
struct ExtensionStandInWebKitTests {
    /// Records every way an extension can ask WSurf for something. A stand-in call must produce none of them.
    @MainActor
    private final class Delegate: NSObject, WKWebExtensionControllerDelegate {
        var events: [String] = []

        func webExtensionController(
            _ controller: WKWebExtensionController,
            connectUsing port: WKWebExtension.MessagePort,
            for extensionContext: WKWebExtensionContext,
            completionHandler: @escaping ((any Error)?) -> Void
        ) {
            events.append("connect:" + (port.applicationIdentifier ?? ""))
            completionHandler(NSError(domain: "ExtensionStandInTests", code: 1))
        }

        func webExtensionController(
            _ controller: WKWebExtensionController,
            sendMessage message: Any,
            toApplicationWithIdentifier applicationIdentifier: String?,
            for context: WKWebExtensionContext,
            replyHandler: @escaping (Any?, (any Error)?) -> Void
        ) {
            events.append("message")
            replyHandler(nil, NSError(domain: "ExtensionStandInTests", code: 1))
        }

        func webExtensionController(
            _ controller: WKWebExtensionController,
            openNewTabUsing configuration: WKWebExtension.TabConfiguration,
            for extensionContext: WKWebExtensionContext,
            completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
        ) {
            events.append("tab")
            completionHandler(nil, NSError(domain: "ExtensionStandInTests", code: 1))
        }

        func webExtensionController(
            _ controller: WKWebExtensionController,
            openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
            for extensionContext: WKWebExtensionContext,
            completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
        ) {
            events.append("window")
            completionHandler(nil, NSError(domain: "ExtensionStandInTests", code: 1))
        }

        func webExtensionController(
            _ controller: WKWebExtensionController,
            openOptionsPageFor extensionContext: WKWebExtensionContext,
            completionHandler: @escaping ((any Error)?) -> Void
        ) {
            events.append("options")
            completionHandler(NSError(domain: "ExtensionStandInTests", code: 1))
        }

        func webExtensionController(
            _ controller: WKWebExtensionController,
            promptForPermissions permissions: Set<WKWebExtension.Permission>,
            in tab: (any WKWebExtensionTab)?,
            for extensionContext: WKWebExtensionContext,
            completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
        ) {
            events.append("permissions")
            completionHandler([], nil)
        }

        func webExtensionController(
            _ controller: WKWebExtensionController,
            promptForPermissionToAccess urls: Set<URL>,
            in tab: (any WKWebExtensionTab)?,
            for extensionContext: WKWebExtensionContext,
            completionHandler: @escaping (Set<URL>, Date?) -> Void
        ) {
            events.append("urls")
            completionHandler([], nil)
        }

        func webExtensionController(
            _ controller: WKWebExtensionController,
            promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
            in tab: (any WKWebExtensionTab)?,
            for extensionContext: WKWebExtensionContext,
            completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
        ) {
            events.append("patterns")
            completionHandler([], nil)
        }
    }

    private func fixture(files: [String: String], manifest: [String: Any]) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-standin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        for (path, text) in files {
            let url = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return package
    }

    private func load(_ package: URL, delegate: Delegate) async throws -> (WKWebExtensionController, WKWebExtensionContext) {
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        controller.delegate = delegate
        let webExtension = try await WKWebExtension(resourceBaseURL: package)
        let context = WKWebExtensionContext(for: webExtension)
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        try controller.load(context)
        return (controller, context)
    }

    private let worker = """
    // Chrome-only APIs, used the way an extension written for Chrome uses them: unguarded, at the top level.
    chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
    chrome.bookmarks.onCreated.addListener(() => {});
    chrome.windows.onBoundsChanged.addListener(() => {});
    chrome.runtime.onSuspendCanceled.addListener(() => {});
    chrome.webNavigation.onHistoryStateUpdated.addListener(() => {});
    chrome.webNavigation.onTabReplaced.addListener(() => {});
    chrome.privacy.services.passwordSavingEnabled && chrome.privacy.services.passwordSavingEnabled.get({});
    chrome.storage.managed.get(null).then(policy => { self.policyKeys = Object.keys(policy).length; });
    // Calls that try to reach the app through a stand-in. None may arrive.
    chrome.sidePanel.open({ tabId: 1 }).catch(() => {});
    chrome.bookmarks.create({ title: "x", url: "https://example.com/" }).catch(() => {});
    chrome.management.setEnabled("someone-else", true).catch(() => {});
    chrome.tabGroups.update(1, { title: "x" }).catch(() => {});
    // The extension's other features still run: this one reaches WSurf, which the test observes.
    chrome.runtime.connectNative("com.example.started");
    """

    private let workerManifest: [String: Any] = [
        "manifest_version": 3, "name": "Stand-in worker", "version": "1.0",
        "description": "Starts a worker that uses APIs WebKit lacks.",
        "permissions": ["webNavigation", "privacy", "sidePanel", "bookmarks", "management", "tabGroups", "storage", "nativeMessaging"],
        "background": ["service_worker": "sw.js"],
    ]

    @Test func aWorkerThatUsesAPIsWebKitLacksStartsAndRunsItsOtherFeatures() async throws {
        let package = try fixture(files: ["sw.js": worker], manifest: workerManifest)
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(ExtensionShims.ensureGapsApplied(at: package))
        let delegate = Delegate()
        let (controller, context) = try await load(package, delegate: delegate)
        defer { try? controller.unload(context) }

        try await context.loadBackgroundContent()
        let reached = await waitUntil(timeout: .seconds(20)) { !delegate.events.isEmpty }
        #expect(reached, "the worker never got past the APIs WebKit lacks")
        try await Task.sleep(for: .seconds(1))
        #expect(delegate.events == ["connect:com.example.started"], "a stand-in call must not reach WSurf")
        #expect(context.errors.isEmpty, "\(context.errors.map(\.localizedDescription))")
    }

    /// The control: the worker is the same, and the only difference is that no stand-ins were written. It reaches
    /// its first line and then dies at `chrome.sidePanel`, so it never connects. WebKit may not even finish
    /// `loadBackgroundContent` for a worker that died, so the test does not wait for it.
    @Test func theSameWorkerWithoutTheStandInsDiesAtTheFirstMissingAPI() async throws {
        let probe = """
        chrome.runtime.connectNative("probe.sidepanel." + (typeof chrome.sidePanel === "undefined" ? "missing" : "native"));
        """
        let package = try fixture(files: ["sw.js": probe + "\n" + worker], manifest: workerManifest)
        defer { try? FileManager.default.removeItem(at: package) }
        let delegate = Delegate()
        let (controller, context) = try await load(package, delegate: delegate)
        defer { try? controller.unload(context) }

        let start = Task { try? await context.loadBackgroundContent() }
        defer { start.cancel() }
        let probed = await waitUntil(timeout: .seconds(20)) { !delegate.events.isEmpty }
        try #require(probed)
        guard delegate.events[0] == "connect:probe.sidepanel.missing" else {
            return // A WebKit that has the side panel natively no longer needs this stand-in; the control proves nothing.
        }
        try await Task.sleep(for: .seconds(2))
        #expect(!delegate.events.contains("connect:com.example.started"))
    }

    @Test func pagesThatReadMissingAPIsLoadWhetherOrNotTheManifestNamesThem() async throws {
        let script = """
        const saving = chrome.privacy.services.passwordSavingEnabled;
        chrome.sidePanel.open({}).catch(() => { document.documentElement.dataset.rejected = "yes"; });
        chrome.storage.managed.get(null).then(() => { document.documentElement.dataset.ready = String(saving === undefined); });
        """
        let page = #"<!doctype html><html><head><script src="page.js"></script></head><body></body></html>"#
        let package = try fixture(
            files: ["options.html": page, "panel/side.html": page.replacingOccurrences(of: "page.js", with: "../page.js"), "page.js": script],
            manifest: [
                "manifest_version": 3, "name": "Page test", "version": "1.0",
                "description": "Opens pages that read missing APIs.",
                "permissions": ["privacy", "sidePanel", "storage"],
                "options_ui": ["page": "options.html"],
            ]
        )
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(ExtensionShims.ensureGapsApplied(at: package))
        let (controller, context) = try await load(package, delegate: Delegate())
        defer { try? controller.unload(context) }

        for path in ["options.html", "panel/side.html"] {
            let view = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
            view.load(URLRequest(url: context.baseURL.appendingPathComponent(path)))
            var state: [String: String] = [:]
            let loaded = await waitUntil(timeout: .seconds(20)) {
                let value = try? await view.evaluateJavaScript(
                    "JSON.stringify({ready: document.documentElement.dataset.ready ?? null, rejected: document.documentElement.dataset.rejected ?? null})"
                ) as? String
                state = (try? JSONSerialization.jsonObject(with: Data((value ?? "{}").utf8)) as? [String: String]) ?? [:]
                return state["ready"] != nil && state["rejected"] != nil
            }
            #expect(loaded, "\(path)")
            #expect(state["ready"] == "true", "\(path)")
            #expect(state["rejected"] == "yes", "\(path)")
        }
        #expect(context.errors.isEmpty, "\(context.errors.map(\.localizedDescription))")
    }
}
