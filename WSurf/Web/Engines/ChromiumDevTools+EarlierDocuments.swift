// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

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

    /// What Chromium runs for `script` in each new document: its injection time and frame scope are made here. A script that runs in
    /// frames, in one of WSurf's isolated worlds, runs as one instance per document (`instanceSource`); the passkey scripts follow
    /// their window themselves (`WebAuthnScript.followsItsWindow`), and a page-world script runs as written.
    func registrationSource(_ script: Script) -> String {
        let perDocument = !script.mainFrameOnly && !script.worldName.isEmpty && !WebAuthnScript.followsItsWindow(script.source)
        let body = script.mainFrameOnly ? "if (window === window.top) {\n\(script.source)\n}"
            : perDocument ? Self.instanceSource(script.source) : script.source
        guard script.injectionTime != .atDocumentStart else { return body }
        return "(() => { const run = () => {\n\(body)\n}; " +
            "if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, {once: true}); " +
            "else queueMicrotask(run); })();"
    }

    /// `source` as one instance per document of its window. A page that reads a new frame's window at once (Apple's sign-in does)
    /// makes Chromium set up the frame's first, empty document and run the start scripts in it, as in any document the page can use.
    /// A document of the same origin can then take over that window (HTML's window reuse), and Chromium starts none of its scripts
    /// again, so WSurf runs them there (`runStartScriptsAfterTakeover`). A run for the window's newer document retires the instance
    /// of the earlier one first: the globals it defined go, and the listeners it put on the window fall silent (a listener added to
    /// the window while it ran answers only while it is the live instance; none of these scripts removes one). A second run for the
    /// same document does nothing. The record (`__wsurfStartRuns`) is in WSurf's isolated world, which the page cannot reach.
    static func instanceSource(_ source: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in source.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3
        }
        return instanceTemplate
            .replacingOccurrences(of: "WSURF_KEY", with: String(hash, radix: 16))
            .replacingOccurrences(of: "/*WSURF_SOURCE*/", with: source)
    }

    private static let instanceTemplate = #"""
        (() => {
          const runs = globalThis.__wsurfStartRuns ??= new Map();
          const earlier = runs.get('WSURF_KEY');
          if (earlier && earlier.document === document) return;
          if (earlier) {
            earlier.alive = false;
            for (const name of earlier.globals) delete globalThis[name];
          }
          const run = {document, alive: true, globals: []};
          const before = new Set(Object.getOwnPropertyNames(globalThis));
          const events = EventTarget.prototype, listen = events.addEventListener;
          events.addEventListener = function (type, listener, options) {
            const target = this ?? globalThis;
            if (target === globalThis && listener) {
              const inner = listener;
              listener = function (event) {
                if (run.alive) return typeof inner === 'function' ? inner.call(this, event) : inner.handleEvent(event);
              };
            }
            return listen.call(target, type, listener, options);
          };
          try {
        /*WSURF_SOURCE*/
          } finally {
            events.addEventListener = listen;
            run.globals = Object.getOwnPropertyNames(globalThis).filter(name => !before.has(name));
            runs.set('WSURF_KEY', run);
          }
        })();
        """#

    /// Documents whose bindings reported start scripts that ran for an earlier document of their window, until `bindDocument` runs
    /// them again. ponytail: the oldest are forgotten past 64; a document is reported while its frame binds, so only that many frames
    /// binding at once could lose one.
    private static var takenOver: [String] = []

    static func noteTakeover(of documentID: String) {
        guard !takenOver.contains(documentID) else { return }
        takenOver.append(documentID)
        if takenOver.count > 64 {
            takenOver.removeFirst()
        }
    }

    /// The frame's document took over the window of the frame's first, empty document, whose start scripts ran for that document:
    /// each per-document script runs again now, once, for this one, in registration order and each in its own world, as in a new
    /// document (late, so whatever the page did first, it missed), and retires the empty document's instance. The passkey scripts
    /// follow the window, and the binding shims, the page bridge and the page relay serve the window's current document.
    func runStartScriptsAfterTakeover(frameID: String, documentID: String) async {
        guard let index = Self.takenOver.firstIndex(of: documentID) else { return }
        Self.takenOver.remove(at: index)
        guard !closed, let state = framesByID[frameID], state.documentID == documentID, !state.isMainFrame else { return }
        let perDocument = scripts.filter { !$0.mainFrameOnly && !$0.worldName.isEmpty && !WebAuthnScript.followsItsWindow($0.source) }
        await runLate(perDocument, in: state.browserFrame, source: registrationSource)
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
