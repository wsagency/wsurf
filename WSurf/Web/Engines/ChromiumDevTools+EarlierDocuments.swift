// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// A pop-up's first document starts before WSurf attaches to the browser CEF made for it: the opener's renderer creates it at
/// `window.open`, and a pop-up of another site commits its own while the scripts are still being registered. A frame of another
/// site that was already running when its session attached missed them too. Without holding the load (a pop-up that is never shown
/// would wait), those documents get the scripts late, once: a pop-up's session registers, before its scripts and after each one, a
/// mark of how many are registered (`markNewDocuments`), which every new document keeps, and `runScriptsInEarlierDocuments` runs
/// in each current document only the scripts its mark says it lacks, then marks it complete. No document runs a script twice.
extension ChromiumDevTools {
    private static let markWorld = WKContentWorld.world(name: "WSurfRegistered")

    /// Every document made from now on records that the first `registered` scripts ran in it.
    func markNewDocuments(registered: Int) async throws {
        _ = try await register("globalThis.__wsurfRegistered = \(registered);", worldName: worldName(Self.markWorld))
    }

    /// Script by script, in registration order and each in its own world, as a new document runs them: an isolated world's
    /// `__wsurfSend` shim before its first script, the page world's relay and bridge before the first page-world script, and every
    /// such world bound after the last script, so what the scripts sent meanwhile goes out then (the shims and relays run only
    /// once in a document). A script that throws stops none after it. Late is late for scripts that must run before the page's own
    /// code: the passkey page script (`WebAuthnScript.page`), the notification and geolocation stand-ins and the development
    /// diagnostics hook miss whatever the page did before them.
    func runScriptsInEarlierDocuments() async {
        guard let current = try? await frames() else { return }
        // A frame of another site belongs to its own session, which runs its own scripts there.
        for frame in current.sorted(by: { $0.isMainFrame && !$1.isMainFrame }) where session(for: frame) === self {
            guard !closed,
                  let ran = try? await evaluate("globalThis.__wsurfRegistered ?? 0", in: frame, world: Self.markWorld) as? Int,
                  ran < scripts.count,
                  (try? await evaluate("globalThis.__wsurfRegistered = \(scripts.count)", in: frame, world: Self.markWorld)) != nil
            else { continue }
            var prepared: Set<String> = []
            var bound: [String] = []
            for script in scripts[ran...] where frame.isMainFrame || !script.mainFrameOnly {
                if prepared.insert(script.worldName).inserted {
                    for (name, source) in setup(for: script.worldName) {
                        await run(source, in: frame, worldName: name)
                        if source == Self.bindingSource {
                            bound.append(name)
                        }
                    }
                }
                await run(script.source, in: frame, worldName: script.worldName)
            }
            for name in bound {
                await run("globalThis.__wsurfAttach?.();", in: frame, worldName: name)
            }
        }
    }

    /// What a new document gets from `installBinding` ahead of `worldName`'s scripts, as (world, source) pairs in order. Each guards
    /// against a second run.
    private func setup(for worldName: String) -> [(String, String)] {
        guard needsBinding(worldName) else { return [] }
        guard worldName.isEmpty else { return [(worldName, Self.bindingSource)] }
        return [(Self.pageBridgeWorld, Self.bindingSource), (Self.pageBridgeWorld, pageBridgeSource), ("", pageRelaySource)]
    }

    private func run(_ source: String, in frame: BrowserFrame, worldName: String) async {
        let world = worldName.isEmpty ? WKContentWorld.page : WKContentWorld.world(name: worldName)
        _ = try? await evaluate("(() => {\ntry {\n" + source + "\n} catch {}\n})()", in: frame, world: world)
    }
}
