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

### 3. D4 spike only (branch `spike/chromium-oop`, never merged): CEF in an XPC service

- **What.**
  - `Sources/CefKit/CefConfiguration.swift` and `CefRuntime.swift`: new `mainBundlePath` (CEF's `main_bundle_path`), cleared with the other settings strings.
  - `Sources/CefKit/CefRemoteProtocol.swift` (new): the message vocabulary that WSurf and the service share, and `CefCursorType.fromRemote(_:)`.
  - `Sources/wsurf-chromium-service/` (new executable target `wsurf-chromium-service`): the XPC service's executable. `Tools/embed-chromium.sh` builds it and assembles `Contents/XPCServices/WSurf Chromium.xpc`.
- **Why.** CEF in an `.xpc` bundle must be told where WSurf's main bundle, framework and helper are (`framework_dir_path`, `browser_subprocess_path`, `main_bundle_path`); upstream sets only the first two.
- **Re-applying.** Not applicable while it is a spike. If phase 2 adopts it, patch 3 gets a real entry.

### Outside the package

- `WSurf/Web/Engines/ChromiumPage.swift`: one call to `externalBrowserDidOpen()` after the browser is created and registered (`materialize()`), one call to `externalBrowserDidClose()` where `didClose()` releases the browser.
- `WSurfTests/Web/CefMessagePumpTests.swift`: the pump's unit tests.

## Updating CefSwift

1. Fetch the new upstream revision and replace this folder with `git archive` of it (leave out `.github/` and `Examples/`). Commit that unmodified.
2. Re-apply the two patches above in a second commit. Keep this file's table and patch list current.
3. Update the revision in `NOTICE` and the version in `Tools/make-acknowledgements.swift`, then run `swift Tools/make-acknowledgements.swift` and commit `WSurf/Support/Acknowledgements.json` if it changed.
4. Run the Chromium suites and the idle measurement (host wakeups with every Chromium tab closed must stay under 5 a second).
