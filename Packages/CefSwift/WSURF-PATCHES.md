# WSurf patches to CefSwift

This folder is a vendored copy of CefSwift with the small patches listed here. Everything else is upstream, unchanged.

| | |
|---|---|
| Upstream | https://github.com/Rajaniraiyn/CefSwift |
| Revision | `59cad64e124b8efdb6b2ee811963097bb6e689e8` (2026-10-02, "Bump CEF to 154.0.32+g682c378+chromium-154.0.8037.58 (#19)") |
| License | MIT (`LICENSE`, Copyright 2026 Rajaniraiyn). The vendored CEF headers keep the BSD 3-Clause license in `Sources/CCef/LICENSE.CEF.txt`. Both files are as upstream. |
| Vendored | 2026-10-28, with the owner's approval (0.1.17 performance plan, item 9) |
| Not copied | `.github/` (upstream's three workflows cannot run from a subfolder) and `Examples/` (a separate sample package) |
| CEF framework | Not part of the package. `Package.swift` has no `binaryTarget`; `Tools/embed-chromium.sh` runs the package's `cef download` command, which fills the gitignored `.cef/` folder. `CEF_VERSION.json` names the build. |

The Git history keeps an unmodified copy as its own commit (`chore(deps): vendor CefSwift 59cad64 unmodified into Packages/CefSwift`).
`git diff <that commit>..HEAD -- Packages/CefSwift` lists every patch.

## Patches

### 1. `Sources/CefKit/CefMessagePump.swift`: no repeating timer while Chromium is idle

- **What.** The pump is rewritten around these rules.
  1. CEF's `on_schedule_message_pump_work(delay_ms)` is honoured: an immediate request runs the loop now; a delayed request replaces the earlier delayed one and runs the loop when it is due (capped at one minute, because CEF asks for a huge delay when nothing is scheduled). An immediate request leaves a pending delayed one alone. Upstream clamped every delay to 33 ms.
  2. Each pass that a request caused starts a busy window: the loop also runs every 33 ms, until 0.5 s after the last request (0.1 s when no browser is alive). Requests alone are not enough. Measured with only exact requests and a 1 s safety net, a warm Chromium page load took 2 to 3 s instead of 0.2 to 0.4 s, and the first tab of a session several seconds more.
  2a. Each pass that ran 2 ms or more starts or extends the busy window too, whatever caused it. CEF cuts a pass short after about 10 ms and then asks for nothing more while the rest of its work waits: it expects the embedder to come back on its own. Without this rule, work queued on CEF's UI thread when the busy window ended stayed there: with no browser alive it never ran, and nothing posted later ran either (CEF still thought a pass was due), so a new disk profile never loaded; with a browser alive only the 1 s safety net ran it, about 10 ms a second. That stopped every Chromium page load in the last 48 minutes of the 0.1.17 gate's serial part 1. `CefMessagePumpTests` reproduces it with the real framework (40 tasks of 5 ms each on CEF's UI thread: 8 ran, then none). Idle passes take well under 1 ms, so an idle runtime still schedules nothing.
  3. The safety-net timer runs the loop once a second (0.25 s tolerance) while at least one browser is alive. Upstream ran a repeating 33 ms timer from `initialize` until quit.
  4. With no browser alive, five seconds after the last browser closed (or after `start()`), the safety net stops. With no request in the last 0.1 s either, no timer repeats. CEF does not ask for delayed work it finds during a pass (no delayed request was seen in a whole test run), so with no browser alive a Chromium timer waits until the next request or browser.
  5. A request that arrives while the loop is already running (a nested loop, such as a modal dialog) is run again as soon as the outer pass returns. Upstream dropped it and relied on the 33 ms timer.

  Timers come from an injectable `TimerSource` and the loop from an injectable closure, so `CefMessagePumpTests` (in WSurf's `WSurfTests/Web/`) drives the pump without a run loop or a CEF framework.
- **Why.** The 33 ms timer cost the host 32 to 34 wakeups a second for the rest of any session that used Chromium, with the window hidden and every Chromium tab closed (`PA07` of the 0.1.17 performance audit).
- **Re-applying.** Replace the file with the patched one. The rest of the package calls only `start()`, `stop()`, `scheduleWork(delayMilliseconds:)` and `performWork()`, and `CefAppHandlers.swift` constructs nothing new. If upstream changes those four, port by hand.

### 2. `Sources/CefKit/CefRuntime.swift`: tell the pump which browsers are alive

- **What.**
  - New public `CefRuntime.externalBrowserDidOpen()` and `externalBrowserDidClose()`. They count a browser that the app made with raw CEF calls, which `CefBrowser` never sees.
  - `registerBrowser(_:)` and `unregisterBrowser(id:)` call the same counter when the registry really changes, so browsers made through `CefBrowser` are counted without the app doing anything.
- **Why.** WSurf owns its browser lifetimes (`ChromiumPage`, `ChromiumClient`) and does not use the registry. Without the count the pump cannot tell an idle runtime from a busy one.
- **Re-applying.** Three small edits in `registerBrowser`, `unregisterBrowser` and the two new methods next to them.

### 3. D4 (out-of-process Chromium), part 1: `Sources/CefKit/CefRemoteProtocol.swift`, `CefRemoteRequests.swift`, `CefRemoteLifecycle.swift`

- **What.** Three new files, no change to an upstream file. They are the shared logic of the Chromium service that D4 adds (`plans/d4-phase2-plan.md`, D4-1), with no XPC connection, no service and no CEF call in them.
  - `CefRemoteProtocol.swift`: the message vocabulary (`CefRemote.Key`, `Op`, `Event`) and `CefRemoteMessage`, a typed wrapper over a libxpc dictionary. Protocol version 1: `hello` carries it, and a mismatch is refused (`checkProtocolVersion()`, `setRefusal(_:)`). `historyChanged` carries the native history; `collapseHistory(keeping:ifEntriesAre:)` has the answer `landed`, `refused` or `skipped`, decided by `CefRemote.collapseVerdict`.
  - `CefRemoteRequests.swift`: the table of requests WSurf waits on. Each ends exactly once, on its reply, on an interruption, or on its timeout (5 s default). A late reply is dropped. The timer is injected.
  - `CefRemoteLifecycle.swift`: `CefRemoteLinger` (the idle service leaves after the linger, 60 s by default; at once under memory pressure while no browser is open) and `CefRemoteRelaunchPolicy` (relaunch at once after a death; 3 deaths in 30 s is a crash loop until the person reloads). Time comes in from outside.
- **Why.** WSurf must never wait on the service, and every awaited request must end. Keeping this logic free of XPC and CEF lets `WSurfTests/Web/ChromiumRemoteProtocolTests.swift` test it without a service. Nothing uses the files yet; the default build only compiles them.
- **Re-applying.** Copy the three files. They import only Foundation, `os` and XPC.

### 3. The out-of-process Chromium service (D4), part 2: the service executable and `mainBundlePath`

Part 1 (the shared protocol) is a separate entry; this is the bundle part, D4-2.

- **What.**
  - `Package.swift`: a new executable product and target, `wsurf-chromium-service`, which depends on `CCefAppKit` only for now. Its `main.swift` is a stub (`CEFApplication.install()`, activation policy `.prohibited`, `xpc_main`, and a plain-XPC `ping` that answers with its pid). It does not start CEF.
  - `Sources/CefKit/CefConfiguration.swift` and `CefRuntime.swift`: `CefConfiguration.mainBundlePath` maps to CEF's `main_bundle_path`, which an XPC service needs because its browser process is not the top-level app.
- **Why.** CEF's browser process moves out of WSurf's process into `WSurf Chromium.xpc` (the D4 plan). `Tools/embed-chromium.sh` builds the product like `cef-helper` and assembles the `.xpc`, only for a build with `WSURF_CHROMIUM_OOP_BUILD=YES`.
- **Re-applying.** Add the product and target back to `Package.swift`, restore the `Sources/wsurf-chromium-service/` folder, and add the one property and its two lines in `CefRuntime.swift` (`set` and `clear`).

### 3. The out-of-process Chromium service (D4), part 3: CEF in the service

D4-4a (`plans/d4-phase2-plan.md`). The service now starts CEF and keeps its own lifecycle.

- **What.**
  - `Package.swift`: the service depends on `CefKit` and `CCef` now, and compiles with the define `WSURF_SERVICE_DEBUG_OPS`. `Tools/embed-chromium.sh` builds the service in release, where `#if DEBUG` is off, so the debug ops (`debug.abort`, `stats`, `exitOnHello`, `askHost`, `memoryPressure`, `stubBrowser`) have their own define. It is always on in phase 2, which builds only ad hoc and never Release. D4-S, which lets the service be signed, must make it conditional so that no signed service has the ops.
  - `Sources/wsurf-chromium-service/`: `main.swift` (the stub is gone; connections go to `ServiceHost`), new `ServiceHost.swift` (hello with the protocol check, CEF start, request contexts, the linger and memory pressure through `CefRemoteLinger`, closing everything on a lost control connection, `askHost`) and new `Native.swift`.
  - `Sources/CefKit/CefRemoteProtocol.swift`: the `debug.memoryPressure` and `debug.stubBrowser` ops, and the keys and answer words of `debug.stats` and `debug.askHost`.
- **Why.** CEF's browser process lives in the service. The service never reads the keychain (mock keychain, until D4-S), and CEF's log goes to `/dev/null` unless WSurf names a file.
- **Re-applying.** Restore the folder, the two Package.swift settings and the protocol constants.

### 3. The out-of-process Chromium service (D4), part 4: windowless browsers

D4-4b (`plans/d4-phase2-plan.md`). The service now makes and drives browsers.

- **What.**
  - `Sources/wsurf-chromium-service/RemoteClientHandlers.swift` (new): a browser's CEF client, its six handlers (life span, load, display, request, render for geometry only, find) and the rule for their lifetime. The handlers are made before the browser, are constants, and are released only when CEF destroys the client; each owns a `BrowserBox` that points to the browser weakly, so no path from the browser to its client leads back to it.
  - `Sources/wsurf-chromium-service/RemoteBrowser.swift` (new): create and close, the browser ops (load, reload, back and forward when native history allows, stop, zoom, mute, find), the state events, CDP (the DevTools observer forwards results and events byte for byte; the service's own commands use ids from `CefRemote.serviceCommandBase` and never reach WSurf), `historyChanged` and the checked `collapseHistory`.
  - `ServiceHost.swift`: browser dispatch behind the one-host gate, `on_before_browse` through `askHost` on the control connection, the input and frames connections bound to the host's process.
  - `Native.swift`: the callback allocation helpers.
  - `Sources/CefKit/CefRemoteProtocol.swift`: `debug.stats` keys for the live browser and handler counts, the DEBUG creation flags (`fail`, `hold`; compiled only under `WSURF_SERVICE_DEBUG_OPS`), `CefRemote.noNativeEntry`, and `CefRemote.allowedNavigationSchemes` / `allowsNavigation(to:)`, the one scheme allowlist that both the service (every frame, no round trip) and WSurf's in-process `ChromiumClient.on_before_browse` apply.
- **Why.** The ids of `historyChanged` are Chromium's navigation-entry ids, which only CDP (`Page.getNavigationHistory`) carries; CEF's navigation-entry visitor has none, but is the only synchronous read and the only source of `has_post_data`. The service therefore merges the two, and checks a collapse against the last list it sent.
- **Re-applying.** Restore the three files, the `ServiceHost` dispatch and the protocol constants.

### 3. The out-of-process Chromium service (D4), part 5: frames

D4-7 (`plans/d4-phase2-plan.md`). The service's windowless browsers now put their frames on WSurf's frames connection.

- **What.**
  - `Sources/wsurf-chromium-service/FramePresenter.swift` (new): one per browser. `on_accelerated_paint` copies CEF's pooled IOSurface on the GPU (Metal blit) into a ring of `CefRemote.frameRingSize` (3) surfaces per element (page, popup), and the copy, never CEF's own surface, goes out with `IOSurfaceCreateXPCObject` and the entry timestamp. `on_paint` (the CPU path) fills a ring surface the same way. The ring is built by the first frame and **freed while the browser is hidden** (`browser.visibility`), and while no frames connection is attached nothing is copied.
  - `RemoteBrowser.swift`: the shared-texture window info (`shared_texture_enabled`), `browser.visibility` (hidden: `was_hidden` and the ring freed; parked: frames dropped; shown again: an invalidate, because a still page paints nothing of its own), `hidden` at creation, the ring freed at close.
  - `RemoteClientHandlers.swift`: the render handler's `on_paint`, `on_accelerated_paint`, `on_popup_show`, `on_popup_size`.
  - `ServiceHost.swift`: `sendFrame` and `sendPopup` on the frames connection; the input and frames connections attach only after a hello that got `ok` (a refused hello, as a non-canonical root, leaves no host for them), from the host's process, replace an earlier connection of their kind (which is cancelled), and drop with the control connection; a frames connection that attaches makes every shown browser paint again (`requestFrame`).
  - `Sources/CefKit/CefRemoteProtocol.swift`: `Key.timestamp`, the `debug.stats` keys of a browser's ring and frame counts, `DebugCreate.cpuPaint` (DEBUG: the memory path), `CefRemote.frameRingSize`, and the popup event's rectangle keys.
- **Why.** The spike's ring kept up to 4 surfaces of about 17 MB for every tab, hidden ones included (about 93 MB a tab); the plan frees it while hidden. A frames connection that was refused must not look attached to WSurf: the client sends the frames and input hellos with a reply and drops a refused connection (`ChromiumRemote.sideHelloRefused`, `sideRefusals`).
- **Re-applying.** Restore the presenter, the render handler's paint and popup callbacks, `visibility`, `sendFrame`/`sendPopup`, the side-connection rules and the protocol constants.

### Outside the package

- `WSurf/Web/Engines/ChromiumPage.swift`: one call to `externalBrowserDidOpen()` after the browser is created and registered (`materialize()`), one call to `externalBrowserDidClose()` where `didClose()` releases the browser.
- `WSurfTests/Web/CefMessagePumpTests.swift`: the pump's unit tests.
- Patch 3 (D4-2): `Tools/embed-chromium.sh` (the `.xpc`, only with `WSURF_CHROMIUM_OOP_BUILD=YES`), `Tools/check-built-identity.py`, `Tools/run-chromium-oop-tests.sh`, the Embed Chromium phase's `outputPaths` in `WSurf.xcodeproj`, `WSurf/Web/Engines/ChromiumServiceBundle.swift` and the framework and helper paths in `ChromiumRuntime.swift`, and `WSurfTests/Web/ChromiumServiceBundleTests.swift`.
- Patch 3 (D4-4a): `WSurfTests/Web/ChromiumServiceHostTests.swift`.
- Patch 3 (D4-4b): `WSurfTests/Web/ChromiumServiceBrowserTests.swift`, and `WSurfTests/Helpers/ChromiumServiceClient.swift` (the raw XPC test client of D4-4a's suite, moved out of it and shared).
- Patch 3 (D4-5): `WSurf/Web/Engines/ChromiumRemote.swift` (`ChromiumOOP`: the guard and the per-process latch; `ChromiumRemote`: the connections, the hello, relaunch and the crash-loop cap), the latch check in `ChromiumRuntime.ensureInitialized`, the SwiftLint rule `no_sync_xpc_reply` in `.swiftlint.yml`, and `WSurfTests/Web/ChromiumRemoteClientTests.swift`. In CefKit only comments changed, and `CefRemoteRelaunchPolicy.recordDeath(at:serviceWasInUse:)` has no default for `serviceWasInUse` any more. In the service, `ServiceHost` refuses a hello whose root is not canonical (`realpath(root) == root`) and compares a context's or the hello's cache path as the `realpath` of its nearest existing ancestor plus the components below it, before it creates anything (`isInside`); `CefRemote.leavingError` is the one text of its "leaving" refusals.
- Patch 3 (D4-7): `WSurfTests/Web/ChromiumServiceFramesTests.swift`; `WSurf/Web/Engines/ChromiumRemote.swift` sends the frames and input hellos with a reply and drops a connection the service refused (`sideHelloRefused`), with its unit test and one gated test in `ChromiumRemoteClientTests`.

## Updating CefSwift

1. Fetch the new upstream revision and replace this folder with `git archive` of it (leave out `.github/` and `Examples/`). Commit that unmodified.
2. Re-apply the two patches above in a second commit. Keep this file's table and patch list current.
3. Update the revision in `NOTICE` and the version in `Tools/make-acknowledgements.swift`, then run `swift Tools/make-acknowledgements.swift` and commit `WSurf/Support/Acknowledgements.json` if it changed.
4. Run the Chromium suites and the idle measurement (host wakeups with every Chromium tab closed must stay under 5 a second).
