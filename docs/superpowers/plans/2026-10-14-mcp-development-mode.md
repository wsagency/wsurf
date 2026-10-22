# WSurf MCP Development Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved MCP development mode in one PR with six reviewable commits: cross-engine parity repair of the 19 baseline tools, real CSS hover / three element waits / element-and-region screenshots, and the 10 development tools behind native **Allow Development** consent.

**Architecture:** Extend the existing boundaries only: `MCPToolCatalog` (public schema) → `MCPBrowserSession` (grants, envelopes, per-session cleanup index) → `PageDriver` (shared page-operation policy) → `PageRuntime` (DOM/ref extraction) → `BrowserPage` (engine adapter: `ChromiumPage`, WebKit). One development owner per tab, held on `BrowserTab`; temporary layout/emulation state lives on `BrowserPage` and participates in the existing `WebViewContainer` layout path.

**Tech Stack:** Swift 6 / SwiftUI+AppKit, Swift Testing (`@Suite`, `#expect`), `MCP` Swift SDK, WKWebView and Chromium (CEF) via `ChromiumDevTools` CDP. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-08-mcp-development-mode-design.md` (refreshed against `origin/main` `d3cf409`). Executors read both. Section numbers below (`§N`) refer to the spec.

**Base:** `origin/main` `d3cf4097c541dee634428bb86dfe35fe76723019` (confirmed unchanged by coordinator 2026-10-14). Product edits only after the coordinator's `pro-build-retirement` relay confirms the latest main; if main moved, rebase before the first product edit.

## Global Constraints

- 19 baseline tools (requestAccess, listTabs, switchTab, closeTab, newTab, readPage, clickOnPage, typeOnPage, selectOption, hoverOnPage, pressKey, fillFields, inspectControl, setChecked, waitForPage, screenshotPage, scrollPage, goBack, navigate) keep their contract; `fillFields` batch limit stays **32** (never 8).
- Catalog after the PR: 19 + 10 = 29 tools: getDevelopmentInfo, setViewport, emulateDevice, findElements, inspectElement, startDiagnostics, readConsole, readNetwork, reloadPage, resetDevelopment.
- No raw JavaScript, arbitrary CDP, raw HTML, headers, cookies, storage, request/response bodies, or current input values in any output (§1, §4, §5).
- MCP-only: no assistant tool schema is added or changed; `AgentToolkit.Descriptions` is read-only here. No edits to the `AnyLanguageModel` pin or any `import AnyLanguageModel` file.
- No silent engine switch, no downgrade from a device-axis profile to a responsive preset, no “unsupported” for an unfinished adapter (§2, §3).
- Real hover needs an active app with a key window and an on-screen tab; otherwise explicit unavailable. Never activate WSurf, raise a window, or bypass the on-screen/permission checks (§Coordination decisions).
- Screenshot `region` is a structured object `{x,y,width,height}` of finite CSS-pixel numbers; element target (`observationID`+`ref`) and `region` are mutually exclusive; no scroll/stitch/viewport change; the whole-page sensitive-field refusal runs before and after capture even for a crop.
- Fixed ceilings (not settings): viewport 64–4,096 per axis, ≤ 8,388,608 CSS px, ≤ 33,554,432 estimated backing px after zoom/scale; selector ≤ 2,048 UTF-8 bytes; offset 0–10,000; limit 1–100 (default 50); retention per owned tab ≤ 1,024 records and ≤ 2 MiB, record ≤ 8 KiB; inspection ≤ 32 attributes, 64 style props, 16 ancestors, 32 KiB.
- Profiles: `responsive-phone` 390×844, `responsive-tablet` 768×1,024, `responsive-desktop` 1,280×800 (viewport only); `phone` 390×844 DPR 3 touch+mobile, `tablet` 768×1,024 DPR 2 touch+mobile (device-axis; Chromium only; WebKit fails before any mutation). Orientation selects axis order.
- Permission order: check grant + live document identity before work, after every `await`, and before returning/committing. Development ⊇ control, never overrides website restrictions, private browsing, tab liveness, or domain scope.
- Cleanup removes only state still owned by the tab's `DevelopmentOwner`; never restore a stale baseline over a later manual change; temporary state is never written to profile/global preferences.
- No native build, test run, probe or stage run without a Main lease (Pro slot). Tests are authored and statically reviewed locally; the first runnable gate (below) is queued via Main.
- Credential contact points (`BrowserPage.credentialGeneration`, `PageFrameRegistry`, `ChromiumDevTools+FrameEvents.invalidateCredentialContexts`) must be preserved; WebAuthn back/forward and credential-context tests must still pass.
- Every commit carries its own tests plus `MCP.md` and `CHANGELOG.md` updates. SPDX header block on new Swift files copied from `MCPPrivacyTests.swift` lines 1-3.

## Review Focus

Failure modes the spec implies that no scenario pins by itself; each is owned by the task named in brackets.

1. Selector containing a multibyte character at the 2,048-byte boundary, and an invalid CSS selector — expect input error, never an empty match set. [Task 5, Task 2]
2. `waitForPage` `elementHidden` when the document navigates mid-wait — expect termination (stale), never “hidden” against the new document. [Task 2]
3. Client disconnect while a diagnostics read or viewport transition is in flight — expect the tab's development owner released and no late reapplication. [Task 3, Task 4]
4. Clock/volume: 10,000 console events in a burst — expect eviction with loss counters, memory within the 2 MiB cap, and the app responsive. [Task 6]
5. Two tabs sharing a WebKit content controller, one capturing — expect the other tab never hooked and never buffered. [Task 6]

---

## File Ownership and Overlap Table

“Shared” = source-owned by the coordinator (BrowserPage family); the editing worker declares the exact edit to Main **before** touching the file and edits only after Main's go. Sequence column = commit slice.

| File | Slice(s) | Class | Parallel overlap / mitigation |
|---|---|---|---|
| `WSurf/Web/Page/PageNativeInput.swift` | 1, 2 | Shared (PageDriver family) | Assistant callers `PageInteractionTools` (`hover`, `pressKey`, `waitForPage`), `AgentToolkit+PageActions` (`goBack`), `FrameTools` (`pressKey`) keep signatures `hover(ref:in:) async -> String`, `pressKey(_:ref:in:) async -> String` (Main ruling D1). AI-dep worker must not touch these. |
| `WSurf/Web/Page/PageDriver.swift` (`goBack`) | 1 | Shared | Edited only for a probe-reproduced defect. No overlap known; Linen does not touch `PageDriver`. |
| `WSurf/Web/Page/PageInteraction.swift` (`waitForPage`, `screenshot`) | 2 | Shared | `waitForPage` gains conditions (signature unchanged). `screenshot` is a clean cutover to one typed signature; all internal callers migrate in the same commit (`PageComputerInput.computerFrame` line 80, `MCPBrowserSession` line 220, `PageInteractionTests` lines 335/344/371). |
| `WSurf/Web/Page/PageRuntime.swift` | 2, 5 | Shared | One scripted runtime; slice 2 adds `R.elementState`, slice 5 adds `R.findAll`/`R.inspect`. |
| `WSurf/Web/Page/PageComputerInput.swift` | 2 | Shared | Extract the `phase == "move"` branch of `computerMouse` into an internal `PageDriver.movePointer(to:in:window:)` reused by `hover`; computer path behavior unchanged. |
| `WSurf/Web/Engines/BrowserPage.swift` | 1, 3, 4 | Shared | `sendKeyEvent` Bool (1), capability value (3), viewport/emulation (4). Credential generation untouched. Linen does not touch `BrowserPage*.swift`. |
| `WSurf/Web/Engines/ChromiumPage.swift` | 1, 2, 4 | Shared | `sendKeyEvent` Bool, `refreshHistory`/`goBack` only if probe reproduces (1), `capture` crop (2), emulation (4). |
| `WSurf/Web/Engines/ChromiumDevTools.swift` + `ChromiumDevTools+FrameEvents.swift` | 6 | Shared | Add event-switch cases for `Runtime.consoleAPICalled`/`Runtime.exceptionThrown`/`Network.requestWillBeSent`/`loadingFinished`/`loadingFailed` feeding an optional diagnostics sink; do not touch the `prepare()` domain enables (line ~161-164) and do not change `frameNavigated`/`invalidateCredentialContexts`. |
| `WSurf/UI/Shell/WebViewRepresentable.swift` (`WebViewContainer` layout) | 4 | Shared | Credential UI worker does not edit; confirm with Main before edit. |
| `WSurf/Web/Tabs/BrowserTab.swift` (+ new `BrowserTab+Development.swift`) | 3, 4 | Shared | One stored property `developmentOwner` plus one clearing line each in `installEngine` (~540), `close` (~583) and `retire` (~402); everything else in the new extension file. Linen (approved) owns `discardWebContent` → `unloadUntilShown`, `isShown`/`onclose`, `refreshFavicon`: never edit those hunks; if a clearing line collides with one, flag Main first. Real path is `Web/Tabs`, not `Browser`. |
| `WSurf/MCP/MCPToolCatalog.swift` | 2, 3, 4, 5, 6 | MCP-owned | One slice at a time; slices are sequential commits. |
| `WSurf/Web/Page/PageReply.swift`, `FaviconLoader.swift`, `SiteContentGuard`, `PageLifecycle.swift` (`contentProcessDidTerminate`), `BrowserModel` `isShown` wiring | — | **Linen-owned, not touched** | Linen's `evaluateJavaScript(_:within:as:)` / `callAsyncJavaScript(_:arguments:in:within:as:)` overloads call the existing async `BrowserPage` signatures: this plan keeps those signatures unchanged and callable. Linen does not touch `BrowserPage*.swift`, `PageDriver`, `PageFrameRegistry`, `liveView`/`retire`, or engine adapters. Each PR must compile standalone on `d3cf409`; Task 3/4 teardown hooks therefore must not depend on Linen's `isShown`/`unloadUntilShown`. |
| `WSurf/MCP/MCPBrowserSession.swift` | 2, 3, 4, 5, 6 | MCP-owned | Same. Further splitting into new files below keeps it from growing past review size. |
| `WSurf/MCP/MCPAccessConsent.swift` | 3 | MCP-owned | |
| `WSurf/MCP/MCPDevelopmentTools.swift` (new) | 3–6 | MCP-owned | Per-tool handlers extending `MCPBrowserSession`. |
| `WSurf/Web/Page/PageDiagnostics.swift` (new) | 6 | New, page-family | Bounded buffers + sanitizers; no overlap. |
| `WSurf/Web/Page/PageViewport.swift` (new) | 4 | New, page-family | Pure layout/budget math; no overlap. |
| `WSurfTests/Agent/MCPTransportTests.swift`, `MCPPrivacyTests.swift` | 2–6 | MCP-owned tests | Behavior only: real hover effects, waits, crops, consent/ownership/stale/denied outcomes. No permanent assertions on tool-description wording, prompt button titles, schema copy, defaults or catalog counts; schema/catalog smoke checks are throwaway during development. No source-text assertions. |
| `WSurfTests/Web/{PageDriverTests,PageInteractionTests,ChromiumPageTests,PageComputerInputTests,PageDriverConsentGateTests}.swift` | 1, 2 | Shared tests | |
| `WSurfTests/Web/Development*Tests.swift` (new) | 4–6 | New | |
| `MCP.md`, `CHANGELOG.md` | 1–6 | MCP-owned docs | |
| `WSurf/Web/Credentials/*`, `Settings/Pages/Credential*`, `WebAuthnAdapter`, `BrowserApplication`, `WSurf/Agent/*` (AI call sites), Package pins | — | **Not touched** | Credential/vault, import-export, AnyLanguageModel worker own them. |

## Ledger

| Slice | Commit subject | Gate | Status |
|---|---|---|---|
| 0 | docs: spec refresh + this plan (supersedes PR13 docs with provenance) | Main preflight of this plan | plan sent to Main |
| 1 | fix(mcp): delivery receipt and back-navigation freshness | probes reproduce risks; scenarios 9-10 | not started (awaits relay + probe lease) |
| 2 | feat(mcp): real hover, element waits, element/region screenshots | scenario 11 | blocked on 1 |
| 3 | feat(mcp): development consent, tab ownership, getDevelopmentInfo | scenarios 1, 7 | blocked on 2 (MCP-owned files) |
| 4 | feat(mcp): setViewport, emulateDevice, reloadPage, resetDevelopment | scenarios 2, 3, 7 | blocked on 3 + shared hook declaration |
| 5 | feat(mcp): findElements, inspectElement | scenario 4 | blocked on 3 |
| 6 | feat(mcp): startDiagnostics, readConsole, readNetwork | scenarios 5, 6, 8 | blocked on 3 + shared hook declaration |

First runnable verification (native owner only, after Main grants the Pro lease and the base is confirmed `d3cf409`). Pure buffer/selector/DOM component tests (Tasks 5, 6) do not wait for the slice 1 native queue; they run the same way when a lease exists. All commands run from an owned isolated snapshot with its own DerivedData:
1. `export WSURF_BUNDLE_ID_SUFFIX=.mcpdev-<label>-<attempt>` then `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing -project WSurf.xcodeproj -scheme WSurf -destination platform=macOS,arch=arm64 -derivedDataPath <owned-DD> WSURF_BUNDLE_ID_SUFFIX=$WSURF_BUNDLE_ID_SUFFIX CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=` (flags as in `docs/superpowers/plans/2026-10-12-credential-vault-sync.md` step 1; never launches the test host; a compile error naming the new symbol is the RED for a new-API task).
2. `Tools/check-built-identity.py <owned-DD> <the single generated .xctestrun>` must exit 0 before any host launch.
3. `xcodebuild test-without-building -xctestrun <that exact file> -destination platform=macOS,arch=arm64 -parallel-testing-enabled NO -only-testing:WSurfTests/PageInteractionTests -only-testing:WSurfTests/MCPTransportTests` (suites vary per task).
No bare `xcodebuild test` is ever used. The native owner runs these commands; this plan only names them.

## Shared-edit declarations to send Main before editing

- S1 (**approved by Main**): `BrowserPage.sendKeyEvent(_:)` and `ChromiumPage.sendKeyEvent(_:)` return `Bool`, no `@discardableResult`; every consumer handles rejection: `PageNativeInput.pressKey` (line 88), `PageComputerInput` key loop (line 524, throws `PageComputerFailure.unavailable` on false), `WSurfTests/Web/AppHandoffTests.swift` line 759 (`#require`). `ChromiumPage.goBack`/`refreshHistory` and `PageDriver.goBack` change only for a defect the probes reproduced.
- S2: `PageComputerInput.computerMouse` move-branch extraction; `PageInteraction.waitForPage` conditions; `PageInteraction.screenshot` cutover (above); `ChromiumPage.capture` crop; `PageRuntime` element-state helper.
- S3: `BrowserPage.developmentCapabilities` value; `BrowserTab` `developmentOwner` (see ownership authority in Task 3).
- S4: `BrowserPage` viewport override + CDP emulation methods; `WebViewContainer` layout path (`UI/Shell/WebViewRepresentable.swift`); `BrowserTab` reload.
- S6: `ChromiumDevTools` event cases + optional sink (domains stay as `prepare()` enables them); WebKit per-native-page injection (Task 6), no controller-level script or handler removal.

---

## Task 1 (Slice 1): Delivery receipt and back-navigation freshness

**Files:**
- Modify: `WSurf/Web/Engines/BrowserPage.swift` (`sendKeyEvent`, line 427), `WSurf/Web/Engines/ChromiumPage.swift` (`sendKeyEvent` 450; `goBack` 355 / `refreshHistory` 620 only if a probe reproduces), `WSurf/Web/Page/PageNativeInput.swift` (`pressKey` 42, key send line 88), `WSurf/Web/Page/PageDriver.swift` (`goBack` 489, only if reproduced), `WSurf/Web/Page/PageComputerInput.swift` (key loop line 524), `WSurfTests/Web/AppHandoffTests.swift` (line 759 consumer)
- Test: `WSurfTests/Web/PageInteractionTests.swift`, `WSurfTests/Web/ChromiumPageTests.swift`, `WSurfTests/Web/PageDriverTests.swift`
- Docs: `MCP.md`, `CHANGELOG.md`

**Interfaces:**
- Produces: `BrowserPage.sendKeyEvent(_ event: NSEvent) -> Bool` (no `@discardableResult`; true only when the engine responder was actually invoked; false for closed page, no responder, or Chromium not attached) and `ChromiumPage.sendKeyEvent(_:) -> Bool` with the same meaning. Consumers all handle `false`: `PageDriver.pressKey` returns `"The key was not delivered to the page."` if either event is rejected (success text stays `"Sent <key>. Check the resulting page.\n…"`); `PageComputerInput` key loop throws `PageComputerFailure.unavailable`; `AppHandoffTests` line 759 uses `#require`. `PageDriver.goBack(in:) async -> String` changes only for a reproduced defect, then returns `"Went back. …"` only when `webView.goBack()` returned non-nil and the document URL or same-document history position actually changed; otherwise `"Could not go back."`.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Probes (already authored, commit `63373ba`, no adapter change).** `PageInteractionTests`: `pressKeyDeliversKeyDownAndKeyUpToFocusedControl`, `goBackReportsActualNavigation`, `goBackHandlesSameDocumentHistory`, each `@Test(arguments: BrowserEngine.allCases)` through the existing `withPage(engine:url:)` helper and `HTTPFixtureServer`. Add `pressKeyReportsFailureWithoutResponder` (page detached from its window → result must not start with `"Sent "`). No stub-engine tests: the nil-navigation and changed-foreign-target risks are exercised only by the native probes; if they do not reproduce they are recorded as not defects.
- [ ] **Step 2: Run on Pro (native owner, via Main lease; commands in “First runnable verification”) to observe.** Run `-only-testing:WSurfTests/PageInteractionTests/pressKeyDeliversKeyDownAndKeyUpToFocusedControl` and the other probes. Record for each risk: reproduced / not reproduced, app commit, engine. **A risk that does not fail is closed as “not a defect”, its production edit is dropped, and its test stays as a regression guard.** Expected for confirmed risks: FAIL (`"Sent ArrowDown"` with `window.keys` empty, or `"Went back."` with no navigation).
- [ ] **Step 3: Implement for each reproduced root cause only.** Change `sendKeyEvent` to `-> Bool` and migrate every consumer (S1) regardless of probe outcome (approved clean cutover); then, only for reproduced goBack risks: guard a nil `PageNavigation`, await settle, compare pre/post URL + history index; make `ChromiumPage.refreshHistory` awaitable with fetch failure propagated and validate the back target before traversal, keeping `invalidateCredentialContexts` calls intact.
- [ ] **Step 4: Run Step 1 tests plus `ChromiumPageTests`, WebAuthn back/forward tests, `PageDriverConsentGateTests` → PASS.**
- [ ] **Step 5: Update `MCP.md` (goBack/pressKey results) and `CHANGELOG.md`; commit** `git commit -m "fix(mcp): report key delivery and verify back navigation"`.

## Task 2 (Slice 2): Real hover, element waits, element/region screenshots

**Files:**
- Modify: `WSurf/Web/Page/PageNativeInput.swift` (`hover`), `WSurf/Web/Page/PageComputerInput.swift` (extract pointer move), `WSurf/Web/Page/PageInteraction.swift` (`waitForPage`, `screenshot`), `WSurf/Web/Page/PageRuntime.swift`, `WSurf/Web/Engines/BrowserPage.swift` + `ChromiumPage.swift` (`capture` geometry), `WSurf/MCP/MCPToolCatalog.swift`, `WSurf/MCP/MCPBrowserSession.swift`, `MCP.md`, `CHANGELOG.md`
- Test: `WSurfTests/Web/PageInteractionTests.swift`, `WSurfTests/Agent/MCPTransportTests.swift`, `WSurfTests/Agent/MCPPrivacyTests.swift`

**Interfaces:**
- Consumes: Task 1 `sendKeyEvent` contract (unchanged here).
- Produces:
  - `PageDriver.movePointer(to point: CGPoint, modifiers: NSEvent.ModifierFlags, in view: BrowserPage, window: NSWindow) throws` (extracted from `computerMouse` move branch; throws `PageComputerFailure.unavailable`/`.stale`).
  - `PageDriver.hover(ref:in:) async -> String` — same signature; now validates observation + element geometry (rect inside viewport, `elementFromPoint` hit equals target or descendant), calls `movePointer` at the element center, returns `"Hovered. Verify the returned page.\n…snapshot"`; failures: `"Hover needs WSurf to be the active app."`, `"The element is offscreen or covered."`, stale message. Prefix `"Dispatched hover"` is removed from `MCPBrowserSession` success prefixes and replaced by `"Hovered."`.
  - `PageDriver.waitForPage(condition:value:timeout:in:)` — adds `elementVisible`, `elementHidden`, `elementEnabled`; `value` is a CSS selector (≤ 2,048 UTF-8 bytes, invalid selector → `"Invalid selector."`, >1 match → `"The selector matches more than one element."`). `elementHidden` succeeds also on zero matches. Document change mid-wait returns staleMessage.
  - **One screenshot contract, clean cutover** in `WSurf/Web/Page/PageInteraction.swift`: `enum ScreenshotTarget { case viewport; case element(ref: Int); case region(CGRect) }`; `struct ScreenshotCapture { let jpeg: Data; let bounds: CGRect /* CSS px */; let scale: CGFloat }`; `enum ScreenshotFailure: Error, Equatable { case stale, privacy, invalidGeometry, offscreen, captureFailed }`; `static func screenshot(_ target: ScreenshotTarget = .viewport, in view: BrowserPage) async -> Result<ScreenshotCapture, ScreenshotFailure>`. The old `screenshot(in:) -> Data?` is **deleted**, with no convenience overload. Callers migrated in the same commit: `PageComputerInput.computerFrame` (line 80; it shares this capture, so the assistant's computer screenshot also goes through it — this answers the spec §85 open question), `MCPBrowserSession.usePage` (line 220; failure cases map to distinct MCP error texts), `PageInteractionTests` lines 335/344/371. Element and region are mutually exclusive by construction (one enum value); the MCP layer rejects an argument set naming both before calling.
  - `BrowserPage.capture(rect:width:afterScreenUpdates:)` rect is **view points**; the crop converts CSS→view using page zoom and `view.isFlipped`; WebKit via `WKSnapshotConfiguration.rect`, Chromium via CDP clip with `scale`.
  - `MCPToolCatalog.Parameter` gains `type: "number"` (finite Double) and `type: "region"` (object `{x,y,width,height}` numbers, `additionalProperties:false`) implemented like the special-cased `"array"`. `screenshotPage` parameters: `tabID`, optional `observationID`, `ref`, `region`; `observationID` and `ref` are supplied together; `ref` plus `region` → `invalidParams`. `waitForPage.condition` describes all seven conditions. `MCPBrowserSession.usePage` already requires the current observation whenever `ref` is present.

- [ ] **Step 1: Write failing tests.**
  - `PageInteractionTests.hoverTriggersCssHover` (both engines): fixture `<style>#m:hover+#sub{display:block}#sub{display:none}</style><button id=m>Menu</button><div id=sub>Sub</div>`; `hover(ref:1)` then readPage contains `Sub`; assert `getComputedStyle(sub).display == "block"`.
  - `hoverFailsWhenCovered`, `hoverFailsOffscreen`, `hoverFailsWhenAppInactive` (inject inactive via the existing key-window seam; result begins `"Hover needs"`).
  - `waitForPageElementConditions`: ambiguous selector, `elementVisible` after `setTimeout` reveal, `elementHidden` after removal and with zero matches, `elementEnabled` after `disabled=false`, invalid selector, selector of 2,049 bytes (incl. a 3-byte character at the boundary) → input error, navigation mid-wait → staleMessage.
  - `screenshotElementAndRegionBounds` (both engines, with `PageZoom` at 125% and a scrolled fixture): known colored div → decoded bitmap size equals `bounds.size × scale ± 1 px` and center pixel color matches; `screenshotRejectsOffscreenRegion`, `…ZeroArea`, `…NaN`, `…ElementAndRegionTogether`, `…SensitiveFieldRefusesCrop`, `…NavigationDuringCapture`.
  - `MCPTransportTests.screenshotElementAndRegionOverMcp` (behavior through a real session call): element target and region each return an image block with `bounds`/`scale` text; `ref`+`region` together, negative width and an unknown extra key are rejected as errors with no image. No permanent assertion on the schema shape or description text.
- [ ] **Step 2: Run on Pro → FAIL** (hover does not trigger `:hover`; unknown wait condition; region rejected). Throwaway schema/catalog smoke is allowed during development, not committed.
- [ ] **Step 3: Implement** the interfaces above. Element visibility rule lives once in `PageRuntime` as `R.elementState(selector) -> {count, visible, enabled}` (rendered rect nonempty, `visibility != hidden`, `display != none`, opacity > 0 is not required; enabled adds `disabled`, `inert`, `aria-disabled="true"`, and disabled-fieldset ancestry). Screenshot target geometry comes from `R` (`getBoundingClientRect`, `devicePixelRatio`) and is revalidated after capture against the same document.
- [ ] **Step 4: Run Step 1 tests + `PageComputerInputTests` (move-branch extraction must not change computer behavior) → PASS.**
- [ ] **Step 5: Update `MCP.md` tool table (hover wording: real pointer, CSS `:hover` works) and catalog instructions text at `MCPToolCatalog.swift` line ~20 that currently says hover “dispatches handlers only”; `CHANGELOG.md`; commit** `git commit -m "feat(mcp): real hover, element waits, element and region screenshots"`.

## Task 3 (Slice 3): Development consent, tab ownership, capability reporting

**Files:**
- Create: `WSurf/MCP/MCPDevelopmentTools.swift` (envelope + per-tool handlers as an `extension MCPBrowserSession`)
- Modify: `WSurf/MCP/MCPAccessConsent.swift`, `WSurf/MCP/MCPBrowserSession.swift`, `WSurf/MCP/MCPToolCatalog.swift`, `WSurf/Web/Engines/BrowserPage.swift` (capability value), `WSurf/Web/Tabs/BrowserTab.swift` (`developmentOwner` storage, `pageGeneration` read access, clearing lines in `installEngine`/`close`/`retire`), `MCP.md`, `CHANGELOG.md`
- Create: `WSurf/Web/Tabs/BrowserTab+Development.swift`
- Test: `WSurfTests/Agent/MCPPrivacyTests.swift`, `WSurfTests/Agent/MCPTransportTests.swift`, `WSurfTests/Agent/MCPDevelopmentOwnershipTests.swift` (new; includes the two-connection fixture)

**Interfaces:**
- Produces:
  - `MCPAccessConsent.Access` gains `.development` (superset of `.control`); `MCPAccessConsent.share(client:pages:development:in:) async -> Access?` — the extra alert button **Allow Development** only when `development == true`, with text that DOM inspection and console output can disclose private data.
  - `requestAccess` optional boolean parameter `development` (default absent == false → current behavior byte-for-byte).
  - `AssistantPageCapability` gains `.development` check in `MCPBrowserSession.permits(_:capability:)`; `.development` implies read+control grant AND `Grant.access == .development`.
  - **Ownership authority is the tab, not the session.** All sessions reach a tab through the shared `BrowserModel`, and `BrowserTab` already owns `page`, `pageGeneration`, `isClosed`, `assistantAccess` and `retire`, so one tab-level slot enforces one owner across clients. In `BrowserTab+Development.swift`: `final class DevelopmentOwner { let connection: UUID; let pageGeneration: Int; let documentID: String; var teardown: ((DevelopmentReleaseReason) -> Void)? }`; `enum DevelopmentAcquisition { case acquired(DevelopmentOwner), alreadyOwned(DevelopmentOwner), conflict }`; `enum DevelopmentRelation { case none, own, other }`; `enum DevelopmentReleaseReason { case reset, disconnect, grantDowngrade, tabClosed, profileChanged, pageDestroyed, engineReplaced }`; `extension BrowserTab { func acquireDevelopment(connection: UUID) -> DevelopmentAcquisition` (**synchronous on `@MainActor`, no `await` between check and set ⇒ atomic**, so two sessions racing yield exactly one `acquired`); `func developmentRelation(of connection: UUID) -> DevelopmentRelation`; `func releaseDevelopment(_ owner: DevelopmentOwner, reason: DevelopmentReleaseReason)` (no-op unless `owner` is still the current slot, calls `owner.teardown`) }`. Stored in `BrowserTab`: `private(set) var developmentOwner: DevelopmentOwner?`; `pageGeneration` (currently `private var`, line 206) becomes `private(set)`. `installEngine`, `close` and `retire` each call `releaseDevelopment(_, reason:)` for the current owner (`.engineReplaced`, `.tabClosed`, `.pageDestroyed`). `MCPBrowserSession` keeps only `developmentTabs: Set<UUID>` as an index for cleanup on `revoke()`/disconnect/grant downgrade; it never decides ownership.
  - **Document/async identity reuses existing primitives, not `ObjectIdentifier(page)`.** `documentID` is the main-frame document identity already kept by `PageFrameRegistry` (main frame `documentID`, used by `PageObservation.documentID`; re-read the accessor at `PageFrameRegistry.swift` ~630-650 at then-current main) and the frame revisions/`credentialGeneration` invalidation stay as the invalidation source. Lifetime of viewport/emulation state = `pageGeneration`; diagnostics and element refs are additionally scoped to `documentID`. Every `await` completion revalidates `tab.developmentOwner === owner && tab.pageGeneration == owner.pageGeneration` and, for document-scoped work, the current main-frame `documentID`, before committing or returning.
  - `MCPAccessConsent.Access` gains `.development` (superset of `.control`); `MCPAccessConsent.share(client:pages:development:in:) async -> Access?`; the session's injected `consent` closure gains the same `development: Bool` third parameter and every existing construction site in `WSurfTests/Agent` is migrated. The extra alert choice **Allow Development** exists only when `development == true` and warns that DOM inspection and console output can disclose private data.
  - `requestAccess` optional boolean `development` (absent/false → existing behavior). `AssistantPageCapability` gains `.development` in `MCPBrowserSession.permits(_:capability:)`; `.development` implies read+control and `Grant.access == .development`.
  - `BrowserPage.developmentCapabilities: DevelopmentCapabilities` (value type: `engine: String`, `viewport: Support`, `deviceAxes: [String: Support]`, `diagnostics: [String: Support]`), `enum Support { case supported, limited(String), unsupported(String) }`; filled in Tasks 4/6; here WebKit/Chromium return exact runtime/engine and responsive-viewport status only.
  - Tool `getDevelopmentInfo(tabID)`: read grant; returns engine, runtime, measured `innerWidth/innerHeight`, zoom, owner (`none|self|other`), capability matrix. No DOM content.
  - Shared envelope `MCPDevelopmentTools.result(kind:…)` where `kind ∈ {ok, unsupported, invalidInput, stale, denied, ownershipConflict, pageGone}`; errors set `isError: true`; no empty success.
  - Teardown: `revoke()`, grant downgrade and disconnect call `tab.releaseDevelopment(owner, reason:)` for each tab in `developmentTabs`; tab close/profile change/engine replacement reach the same call from the tab side (above). `owner.teardown` removes only what that owner applied.
- Consumes: `MCPBrowserSession.permits/onScreen`; no dependency on Task 2 catalog types.

- [ ] **Step 1: Write failing tests (behavior only).** `MCPPrivacyTests`: `omittedDevelopmentCannotYieldDevelopmentAccess` (consent closure called with `development == false`; the resulting grant is never `.development` and a development tool is denied); `readOnlyAndControlCannotCallDevelopmentTool`; `deniedSiteStaysDenied`; `revocationDuringPendingWork` (revoke between await points → no data returned). `MCPDevelopmentOwnershipTests` (two-session fixture: two `MCPBrowserSession` on one `BrowserModel` and one tab, both granted `.development` through the injected consent closure): `secondSessionGetsConflictBeforeMutation` (A owns; B's mutating call returns an ownership-conflict error and the page is unchanged), `concurrentAcquireYieldsOneOwner` (`async let` both; exactly one `acquired`), `ownerReportedAsOtherNotIdentity`, `releaseOnDisconnectTabCloseEngineReplace`, `lateCompletionAfterReleaseIsRejected`. No assertions on prompt text, button titles or catalog contents.
- [ ] **Step 2: Run on Pro → FAIL.**
- [ ] **Step 3: Implement** (consent alert, tab owner, envelope, tool). `usePage` gains `capability: .development` path; keep the single `PageAutomationGuard` scope pattern.
- [ ] **Step 4: Run the MCP suites → PASS (existing transport/privacy tests unchanged except the consent-closure signature migration).**
- [ ] **Step 5: Update `MCP.md` (consent, getDevelopmentInfo, ownership) + `CHANGELOG.md`; commit** `git commit -m "feat(mcp): development consent, tab ownership and capability reporting"`.

## Task 4 (Slice 4): Viewport, device emulation, reload, reset

**Files:**
- Create: `WSurf/Web/Page/PageViewport.swift`
- Modify: `WSurf/UI/Shell/WebViewRepresentable.swift` (`WebViewContainer` layout), `WSurf/Web/Engines/BrowserPage.swift`, `WSurf/Web/Engines/ChromiumPage.swift`, `WSurf/Web/Tabs/BrowserTab.swift` (reload path only), `WSurf/MCP/MCPDevelopmentTools.swift`, `WSurf/MCP/MCPToolCatalog.swift`, `MCP.md`, `CHANGELOG.md`
- Test: `WSurfTests/Web/DevelopmentViewportTests.swift` (new), `WSurfTests/Agent/MCPDevelopmentOwnershipTests.swift`

**Interfaces:**
- Consumes: Task 3 `DevelopmentOwner`/`BrowserTab.acquireDevelopment`, envelope, `DevelopmentCapabilities`.
- Produces:
  - `PageViewport` pure helpers: `struct ViewportRequest { width: Int; height: Int }`, `static func validate(_:zoom:scale:) -> Result<ViewportRequest, ViewportError>` (64…4096, ≤ 8,388,608 CSS px, ≤ 33,554,432 backing px), `static let profiles: [String: Profile]` with the five spec profiles, `Profile.dimensions(orientation:) -> (Int, Int)`.
  - `BrowserPage.developmentViewport: CGSize?` (nil == normal layout, never persisted); `WebViewContainer` layout uses it instead of host bounds when non-nil, with input/capture conversion following; `func applyViewport(_ size: CGSize?) async throws -> MeasuredViewport` (`innerWidth/innerHeight/devicePixelRatio`) — measures after layout; rolls back and throws with measured dims on budget miss.
  - Chromium: `ChromiumPage.applyDeviceEmulation(_ profile: Profile?) async throws` using `Emulation.setDeviceMetricsOverride` + `setTouchEmulationEnabled` + `setEmitTouchEventsForMouse`/mobile flag; clearing via `clearDeviceMetricsOverride`. A completion whose owner/page generation no longer matches is dropped. `developmentCapabilities.deviceAxes` advertises `dpr/touch/mobile` as `.supported` **only after** the Task 4 native probe test passes on the embedded runtime; otherwise report `.unsupported(reason)` observed by the probe.
  - WebKit: responsive presets via `developmentViewport`; `emulateDevice(phone|tablet)` returns `unsupported` before mutation.
  - Tools: `setViewport(tabID, width: integer, height: integer)`, `emulateDevice(tabID, profile: string, orientation: string)` (`profile ∈ responsive-phone|responsive-tablet|responsive-desktop|phone|tablet`, `orientation ∈ portrait|landscape`), `reloadPage(tabID)` (uses `BrowserPage.reload()`; keeps owned config only if the new document is still authorized, else releases the owner), `resetDevelopment(tabID)` (idempotent; removes only this owner's values via compare-then-restore against last applied). Mutations acquire through `tab.acquireDevelopment(connection:)` before any native change.
- [ ] **Step 1: Write failing tests.** `DevelopmentViewportTests`: validation table (63/64/4096/4097, area, backing budget; pure, runnable without the native queue), `setViewportMeasuresInnerWidth` (390×844 → `window.innerWidth == 390`, breakpoint `@media (max-width:400px)` active, both engines), `viewportSurvivesZoomInsetSplit`, `screenshotAndInputGeometryFollowViewport`, `phoneProfileFailsBeforeMutationOnWebKit` (no state change, owner slot still empty), `phoneProfileAppliesAxesOnChromium` (DPR 3, `ontouchstart` present, mobile viewport meta honored), `emulateThenSetViewportClearsDeviceAxes`, `manualZoomAfterOverrideNotOverwrittenByReset`, `staleCompletionAfterResetNotReapplied`, `reloadKeepsOwnedConfigOnlyWhileAuthorized`, `resetIsIdempotentAndNeverTouchesOtherClient`.
- [ ] **Step 2: Run on Pro → FAIL.**
- [ ] **Step 3: Implement.** Layout participation: reuse the one frame-derivation function in `WebViewContainer`; do not assign `BrowserPage.frame` directly. Serialize transitions with one in-flight `Task` per owner; cancel it from `owner.teardown`.
- [ ] **Step 4: Run Step 1 tests + `PageZoom` tests → PASS.**
- [ ] **Step 5: Update `MCP.md` (profiles table, limits) + `CHANGELOG.md`; commit** `git commit -m "feat(mcp): viewport, device emulation, reload and reset"`.

## Task 5 (Slice 5): findElements, inspectElement

**Files:**
- Modify: `WSurf/Web/Page/PageRuntime.swift`, `WSurf/Web/Page/PageObservation.swift`, `WSurf/MCP/MCPDevelopmentTools.swift`, `WSurf/MCP/MCPToolCatalog.swift`, `MCP.md`, `CHANGELOG.md`
- Test: `WSurfTests/Web/DevelopmentInspectionTests.swift` (new), `WSurfTests/Agent/MCPPrivacyTests.swift`

**Interfaces:**
- Consumes: Task 3 consent (`.development`), existing `window.__wsurfRefs` registration, `PageDriver.validateObservation`.
- Produces: `PageDriver.findElements(selector:offset:limit:in:) async -> String` and `PageDriver.inspectElement(ref:in:) async -> String`; JS helpers `R.findAll(selector, offset, limit)` (open-shadow + same-origin-frame traversal using the existing `R.walk` convention; `querySelectorAll` inside `try` → `"Invalid selector."`) and `R.inspect(el)` building the bounded result (≤ 32 attributes, 64 allowlisted style props, 16 ancestors, 32 KiB) **before** serialization. Tools: `findElements(tabID, selector: string, offset: integer ≥ 0 ≤ 10,000 optional, limit: integer 1…100 optional)`, `inspectElement(tabID, observationID, ref)`. Output includes `observationID`, document identity, refs, summaries, geometry, `{offset, limit, returned, hasMore}`, and coverage (`crossOriginFrames: skipped`, `closedShadowRoots: skipped`). Refs from `findElements` are inspectable but remain **rejected by click/type/select/fill/press/hover** unless the element is an ordinary control already registered by `readPage` (existing `resolve(kinds:)` guard unchanged).
- Note: `Parameter.minimum` currently defaults to 1; offset needs `minimum: 0` (already supported) and `maximum` 100,000 stays above the 10,000 ceiling → add `maximum` property to `Parameter` (default 100,000) so offset ≤ 10,000 and limit ≤ 100 are enforced in schema and `validate`.

- [ ] **Step 1: Write failing tests.** `findElementsReturnsPaginatedMetadata` (150 `<li>` → limit 100 returns hasMore, offset pages); `selectorBoundaries` (2,048 ASCII ok; 2,049 bytes and a multibyte-at-boundary case → invalidParams; `"div["` → `"Invalid selector."`, not empty success); `inspectNonInteractiveBoxModelFlexGrid`; `inspectRejectsReplacedElement` (element removed and re-added with same markup → stale); `inspectRejectsAfterNavigation`; `inspectOmitsSecrets` (password value, `type=hidden`, inline raw HTML, cross-origin frame content absent from output; assert absence of the fixture secret string); `findRefNotUsableForClick`; `inspectBoundedOutput` (page with 500 attributes, 40 ancestors → counts at the ceilings, serialized ≤ 32 KiB); `developmentConsentRequired` (read/control grant → denied).
- [ ] **Step 2: Run on Pro → FAIL.**
- [ ] **Step 3: Implement** helpers and tools. Reuse sensitive-field masking (`R.isSensitiveField`); allowlist style properties as a single Swift constant mirrored into the script.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: `MCP.md` + `CHANGELOG.md`; commit** `git commit -m "feat(mcp): DOM discovery and bounded element inspection"`.

## Task 6 (Slice 6): startDiagnostics, readConsole, readNetwork

**Files:**
- Create: `WSurf/Web/Page/PageDiagnostics.swift`
- Modify: `WSurf/Web/Engines/ChromiumDevTools+FrameEvents.swift` (event cases + optional sink; `ChromiumDevTools.swift` `prepare()` untouched), `WSurf/Web/Engines/BrowserPage.swift` (per-native-page WebKit hook install/remove; `developmentCapabilities.diagnostics`), `WSurf/MCP/MCPDevelopmentTools.swift`, `WSurf/MCP/MCPToolCatalog.swift`, `MCP.md`, `CHANGELOG.md`
- Test: `WSurfTests/Web/DevelopmentDiagnosticsTests.swift` (new), `WSurfTests/Agent/MCPTransportTests.swift`

**Interfaces:**
- Consumes: Task 3 `DevelopmentOwner` (teardown, `documentID`) and release reasons.
- Produces:
  - `PageDiagnostics.Buffer` — `struct Record { seq: UInt64; timestamp: Date; documentID: String; stream: Stream; body: [String: Value] }`, `enum Stream { console, network }`, `final class Buffer { init(maxRecords: 1_024, maxBytes: 2 * 1_048_576, maxRecordBytes: 8 * 1_024); func append(_:) ; func read(stream:cursor:limit:) throws -> Page /* records, nextCursor, dropped, truncated */ ; func clear() }`. Cursor is an opaque string `base64(connection|tab|stream|epoch|seq)` validated on read; foreign/malformed/expired-epoch → `.invalidCursor`; behind-eviction → data + `dropped` count.
  - `PageDiagnostics.sanitize(url:) -> String?` strips userinfo, query, fragment (applied at ingestion and again at output).
  - **Chromium sink, not domain toggling.** `ChromiumDevTools.prepare()` (lines 161-164) already enables `Page`/`Runtime`/`Security`/`Network` for the page's whole life because other operations depend on them; this work never enables or disables a domain. `ChromiumDevTools` gains `var diagnosticsSink: ((ChromiumDiagnosticEvent) -> Void)?` and `+FrameEvents` dispatch cases for `Runtime.consoleAPICalled`, `Runtime.exceptionThrown`, `Network.requestWillBeSent`, `Network.loadingFinished`, `Network.loadingFailed` and the existing `Network.responseReceived`, each returning immediately when the sink is nil (no record is built, nothing retained). Events carry the real frame/context and the owner's `documentID`; frames outside the grant are dropped before the sink; header and body fields are never read.
  - **WebKit per-native-page injection, never the shared content controller.** `BrowserPage.installScript` (line 618) adds a `WKUserScript` to `webKit.configuration.userContentController`, which opener-created views share (`BrowserTab+WebKitDelegates.swift` `createWebViewWith`), so it is not used. Hooks are injected with `evaluateJavaScript(_, in: nil, contentWorld: .page)` on this page's own `WKWebView` for the **current document only**; the page-world `postMessage` target is registered with `BrowserPage.addScriptMessageHandler`, whose `handlers` dictionary routes by emitting view, so a sibling view on the same controller has no handler and its messages are dropped. Each message is checked against the native page, frame, owner and `documentID` before buffering. On document change the owner re-injects only if the new document is still authorized, and the gap before injection is declared (early events, workers, inaccessible frames, JavaScript disabled, isolated-world exclusion). Cleanup = `removeScriptMessageHandler` for this page plus an uninstall script that restores `console`/`fetch`/`XMLHttpRequest` wrappers only if the current function is still the owned wrapper; no `removeAllUserScripts`, no controller-wide handler removal.
  - Tools: `startDiagnostics(tabID)` (acquires the tab owner; repeat by same owner returns active epoch without clearing), `readConsole(tabID, cursor?: string, limit?: 1…100)`, `readNetwork(tabID, cursor?, limit?)`; every response carries `engine, sources, gaps, epoch, documentID, nextCursor, dropped, truncated`. Unknown status/timing is `null` + `"unknown"` outcome, never 0.
  - Document change: clear buffers, bump epoch, invalidate old cursors, reattach hooks to the new authorized document; denied destination stops capture and releases the tab owner.
- [ ] **Step 1: Write failing tests.** Pure, runnable without the native queue: `bufferEvictsOldestWithLossCounters`, `bufferHonoursByteCapAndRecordTruncation`, `cursorForeignMalformedExpiredRejected`, `sanitizeStripsUserinfoQueryFragment`, `burst10kEventsBoundedMemory` (≤ 1,024 records, ≤ 2 MiB, loss counters). Native fixtures: `consoleErrorAndNetworkOutcomes` (known `console.error`, 200, 404 and aborted fetch on both engines → records with declared coverage; zero pre-start history; no headers/bodies/URL secret/object dump); `webKitHooksPreservePageBehavior` (promise rejection, XHR callbacks, console still reach the page); `captureDisabledOwnsNothing` (before start and after reset: the Chromium sink is nil and builds no record, the WebKit page has no installed hook/handler, and existing CDP operations — evaluate, navigation events, credential-context invalidation — still work with their domains untouched); `sharedControllerSiblingUnhooked` (WebKit: popup created with `window.open` through the opener path shares the controller; its `console.error` is never buffered and its `console.error` is still the native function, while the owner page is hooked); `oldGenerationEventRejected`; `reloadStartsNewEpochOldCursorInvalid`; `forbiddenChildFrameNotBuffered`. No catalog-count or schema assertions.
- [ ] **Step 2: Run on Pro → FAIL.**
- [ ] **Step 3: Implement.** Buffer mutations and eviction on `@MainActor`; ingestion functions are `nonisolated` only if they take immutable values. No disk writes or `Logger` with record content.
- [ ] **Step 4: Run all new suites + `MCPTransportTests` + WebAuthn/credential-context tests → PASS.**
- [ ] **Step 5: `MCP.md` (diagnostics coverage table, limits) + `CHANGELOG.md`; commit** `git commit -m "feat(mcp): console and network diagnostics"`.

## Native stage verification (after Task 6; Main lease required)

Scenarios 1–12 of §7 run on Pro (owned isolated snapshot, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, Debug build) then a stage app on Air (`WSURF_STAGE=1`, separate `WSURF_STAGE_HOME`) driven by a real external MCP client against local fixtures only. Record app commit, engine/runtime, observed result per scenario in the PR description. No installed-app replacement, deploy, or production data.

## Self-Review

- **Spec coverage:** §1 consent → Task 3; §2 tools → Tasks 2–6 (10 development tools plus the three extensions; the catalog is advertised only once each tool has a handler, never partially); §3 viewport/devices → Task 4; §4 inspection → Task 5; §5 diagnostics → Task 6; §6 lifecycle → Tasks 3, 4, 6 (teardown tests); §7 scenarios 1-12 → tests above + stage section; scenarios 9-10 → Task 1 (+9 on every baseline tool: Task 1 Step 1 extends the existing fixture suite with one MCP-end-to-end row per baseline tool **recorded in the PR table; failures there become Task 1 fixes only if a native run reproduces them**); §8 slicing → six tasks, one implementation PR (see Publication ruling).
- **Types:** `DevelopmentOwner`, `DevelopmentAcquisition`, `DevelopmentRelation`, `DevelopmentReleaseReason` (Task 3), `Support`/`DevelopmentCapabilities` (Task 3), `ScreenshotTarget`/`ScreenshotCapture`/`ScreenshotFailure` (Task 2), `PageViewport.Profile` (Task 4), `PageDiagnostics.Buffer`/`ChromiumDiagnosticEvent` (Task 6) are defined once and reused with the same names.
- **Rulings recorded:** see “Preflight rulings”. No open decisions remain.

## Preflight rulings (internal Main preflight of this plan; not new user approval)

| Ruling | Effect on this plan |
|---|---|
| S1 approved | `sendKeyEvent -> Bool`, no `@discardableResult`, every consumer migrated (`PageNativeInput`, `PageComputerInput`, `AppHandoffTests`). |
| goBack / `refreshHistory` | Changed only for defects reproduced by the Task 1 native probes. |
| D1 approved | `PageDriver.hover` signature unchanged; assistant shares the native hover, no schema change. |
| Verification identity | Native owner runs owned-suffix `build-for-testing` → `Tools/check-built-identity.py` → `test-without-building -xctestrun`; bare `xcodebuild test` forbidden. |
| Ownership | Tab-level `DevelopmentOwner` with synchronous acquire; session holds only a cleanup index; two-connection fixture; document epoch reuses `PageFrameRegistry` document id + `pageGeneration`. |
| Screenshot | One `ScreenshotTarget`/`ScreenshotCapture`/`ScreenshotFailure` cutover; old `screenshot(in:)` deleted; all callers migrated. |
| WebKit diagnostics | Per-native-page, current-document injection and per-page handler; never shared controller scripts; shared-controller sibling test required. |
| Chromium diagnostics | Subscribe via optional sink on existing domains; never enable/disable `Page`/`Runtime`/`Security`/`Network`. |
| Tests | No permanent wording, prompt-button, catalog-count, schema-copy or default assertions; transport acceptance/error/security/real hover/effects kept. |
| Pro | Reserved to DevOps; pure buffer/selector/DOM/viewport-validation component TDD may run independently of the slice-1 native queue, never advertising a partial catalog. No Pro run until Main grants the lease. |
| Publication (user-level ruling relayed by Main) | PR13 stays docs-only on `feature/mcp-takeover-20261010`: no retitle, force-push or expansion. This code publishes as a **new, distinct implementation PR** from `feature/mcp-spec-refresh-20261014`, linking PR13, and may include the superseding updated spec + this plan with provenance. Full scope unchanged; no extra user gate. No publication until own review and native gates pass (internal-engine/IE first; afterwards readiness independent of AI macro approval). |
