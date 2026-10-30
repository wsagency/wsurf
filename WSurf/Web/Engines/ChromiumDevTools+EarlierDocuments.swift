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

    // MARK: A frame's document that took over its first document's window

    /// What Chromium runs for `script` in each new document: its injection time and frame scope are made here, and a frame's first,
    /// empty document holds it for the document that takes over its window (`waitingForTakeover`). The passkey scripts are the
    /// exception: they follow their window (`WebAuthnScript.followsItsWindow`), and the page's first calls need their answers.
    func registrationSource(_ script: Script) -> String {
        let body = script.mainFrameOnly ? "if (window === window.top) {\n\(script.source)\n}" : script.source
        let timed = script.injectionTime == .atDocumentStart ? body
            : "(() => { const run = () => {\n\(body)\n}; " +
              "if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, {once: true}); " +
              "else queueMicrotask(run); })();"
        guard !script.mainFrameOnly, !WebAuthnScript.followsItsWindow(script.source) else { return timed }
        return Self.waitingForTakeover(timed, inPageWorld: script.worldName.isEmpty)
    }

    /// True in a frame's first, empty document whose frame element names a document to load. A page that reads a new frame's
    /// window at once (Apple's sign-in does) makes Chromium set this document up and run the start scripts in it. A document of
    /// the same origin then takes over its window (HTML's window reuse), and Chromium starts none of its scripts again: what ran
    /// here would stay listening to the empty document. A document of another origin gets a window of its own.
    static let takeoverPending = #"window !== top && location.href === 'about:blank' && (e => !!e && /^i?frame$/.test(e.localName) && "#
        + #"(e.hasAttribute('srcdoc') || !/^\s*(about:blank)?\s*$/i.test(e.getAttribute('src') || '')))(frameElement)"#

    /// `source`, held in such an empty document for the document that takes over its window, where `runStartScriptsAfterTakeover`
    /// runs it. An isolated world notes that it held one, for its binding to report (`isolatedContext`); the page world, which the
    /// page sees, notes nothing.
    static func waitingForTakeover(_ source: String, inPageWorld: Bool) -> String {
        "if (\(takeoverPending)) {\(inPageWorld ? "" : " globalThis.__wsurfStartDeferred = true; ")} else {\n\(source)\n}"
    }

    /// Documents whose bindings reported held start scripts, until `bindDocument` runs them. ponytail: the oldest are forgotten past
    /// 64; a document is reported while its frame binds, so only that many frames binding at once could lose one.
    private static var takenOver: [String] = []

    static func noteTakeover(of documentID: String) {
        guard !takenOver.contains(documentID) else { return }
        takenOver.append(documentID)
        if takenOver.count > 64 {
            takenOver.removeFirst()
        }
    }

    /// The frame's document took over the window of the frame's first, empty document, which held its start scripts: they run now,
    /// once, in registration order and each in its own world, as in a new document (late, so whatever the page did first, they
    /// missed). Only the scripts this session runs in a frame; the passkey scripts already followed the window.
    func runStartScriptsAfterTakeover(frameID: String, documentID: String) async {
        guard let index = Self.takenOver.firstIndex(of: documentID) else { return }
        Self.takenOver.remove(at: index)
        guard !closed, let state = framesByID[frameID], state.documentID == documentID, !state.isMainFrame else { return }
        let held = scripts.filter { !$0.mainFrameOnly && !WebAuthnScript.followsItsWindow($0.source) }
        await runLate(held, in: state.browserFrame, source: registrationSource)
    }

    // MARK: Documents that started before their scripts

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
            await runLate(scripts[ran...].filter { frame.isMainFrame || !$0.mainFrameOnly }, in: frame, source: \.source)
        }
    }

    /// Runs `pending` in `frame`'s current document, in order: each world's `__wsurfSend` shim, relay and bridge before its first
    /// script, and every bound world attached after the last, so what the scripts sent meanwhile goes out then.
    private func runLate(_ pending: [Script], in frame: BrowserFrame, source: (Script) -> String) async {
        var prepared: Set<String> = []
        var bound: [String] = []
        for script in pending {
            if prepared.insert(script.worldName).inserted {
                for (name, setupSource) in setup(for: script.worldName) {
                    await run(setupSource, in: frame, worldName: name)
                    if setupSource == Self.bindingSource {
                        bound.append(name)
                    }
                }
            }
            await run(source(script), in: frame, worldName: script.worldName)
        }
        for name in bound {
            await run("globalThis.__wsurfAttach?.();", in: frame, worldName: name)
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
