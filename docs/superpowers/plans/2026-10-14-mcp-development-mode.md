# WSurf MCP Development Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved MCP development mode in one PR with six reviewable commits: cross-engine parity repair of the 19 baseline tools, real CSS hover / three element waits / element-and-region screenshots, and the 10 development tools behind native **Allow Development** consent.

**Architecture:** Extend the existing boundaries only: `MCPToolCatalog` (public schema) → `MCPBrowserSession` (grants, leases, envelopes) → `PageDriver` (shared page-operation policy) → `PageRuntime` (DOM/ref extraction) → `BrowserPage` (engine adapter: `ChromiumPage`, WebKit). One development lease per tab inside `MCPBrowserSession`; temporary layout/emulation state lives on `BrowserPage` and participates in the existing `WebViewContainer` layout path.

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
- Cleanup removes only state still owned by the lease; never restore a stale baseline over a later manual change; temporary state is never written to profile/global preferences.
- No native build, test run, probe or stage run without a Main lease (Pro slot). Tests are authored and statically reviewed locally; the first runnable gate (below) is queued via Main.
- Credential contact points (`BrowserPage.credentialGeneration`, `PageFrameRegistry`, `ChromiumDevTools+FrameEvents.invalidateCredentialContexts`) must be preserved; WebAuthn back/forward and credential-context tests must still pass.
- Every commit carries its own tests plus `MCP.md` and `CHANGELOG.md` updates. SPDX header block on new Swift files copied from `MCPPrivacyTests.swift` lines 1-3.

## Review Focus

Failure modes the spec implies that no scenario pins by itself; each is owned by the task named in brackets.

1. Selector containing a multibyte character at the 2,048-byte boundary, and an invalid CSS selector — expect input error, never an empty match set. [Task 5, Task 2]
2. `waitForPage` `elementHidden` when the document navigates mid-wait — expect termination (stale), never “hidden” against the new document. [Task 2]
3. Client disconnect while a diagnostics read or viewport transition is in flight — expect lease released and no late reapplication. [Task 3, Task 4]
4. Clock/volume: 10,000 console events in a burst — expect eviction with loss counters, memory within the 2 MiB cap, and the app responsive. [Task 6]
5. Two tabs sharing a WebKit content controller, one capturing — expect the other tab never hooked and never buffered. [Task 6]

---

## File Ownership and Overlap Table

“Shared” = source-owned by the coordinator (BrowserPage family); the editing worker declares the exact edit to Main **before** touching the file and edits only after Main's go. Sequence column = commit slice.

| File | Slice(s) | Class | Parallel overlap / mitigation |
|---|---|---|---|
| `WSurf/Web/Page/PageNativeInput.swift` | 1, 2 | Shared (PageDriver family) | Assistant callers `PageInteractionTools`, `AgentToolkit+PageActions`, `FrameTools` use `hover`/`pressKey`; keep signatures `hover(ref:in:) async -> String`, `pressKey(_:ref:in:) async -> String`. AI-dep worker must not touch these. |
| `WSurf/Web/Page/PageDriver.swift` (`goBack`) | 1 | Shared | Linen page-robustness patches (separate tree): rebase conflict only in `goBack`; declare. |
| `WSurf/Web/Page/PageInteraction.swift` (`waitForPage`, `screenshot`) | 2 | Shared | Add parameters with defaults; existing assistant call sites (`PageInteractionTests`) compile unchanged. |
| `WSurf/Web/Page/PageRuntime.swift` | 2, 5 | Shared | One scripted runtime; slice 2 adds `R.elementState`, slice 5 adds `R.findAll`/`R.inspect`. |
| `WSurf/Web/Page/PageComputerInput.swift` | 2 | Shared | Extract the `phase == "move"` branch of `computerMouse` into an internal `PageDriver.movePointer(to:in:window:)` reused by `hover`; computer path behavior unchanged. |
| `WSurf/Web/Engines/BrowserPage.swift` | 1, 3, 4 | Shared | `sendKeyEvent` receipt (1), capability hook (3), viewport/emulation (4). Credential generation untouched. |
| `WSurf/Web/Engines/ChromiumPage.swift` | 1, 2, 4 | Shared | `sendKeyEvent` receipt, `refreshHistory`/`goBack` freshness (1), `capture` crop (2), emulation (4). |
| `WSurf/Web/Engines/ChromiumDevTools.swift` (+`+FrameEvents`) | 6 | Shared | Add Runtime/Network subscription gating only; do not change `frameNavigated`/`invalidateCredentialContexts`. |
| `WSurf/Web/WebViewRepresentable.swift` (`WebViewContainer` layout) | 4 | Shared | Credential UI worker does not edit; verify with Main before edit. |
| `WSurf/Browser/BrowserTab.swift` (page lifecycle/final dispatch) | 3, 4 | Shared | Lease-teardown additions only, as a **new** `releaseDevelopmentState(reason:)` call placed in the existing close/page-replacement paths. Linen (approved) owns `discardWebContent` → `unloadUntilShown`, the `isShown` closure/nil `onclose`, and `refreshFavicon` weak capture: never edit those hunks; if a teardown call site falls inside one, flag Main before editing. |
| `WSurf/MCP/MCPToolCatalog.swift` | 2, 3, 4, 5, 6 | MCP-owned | One slice at a time; slices are sequential commits. |
| `WSurf/Web/Page/PageReply.swift`, `FaviconLoader.swift`, `SiteContentGuard`, `PageLifecycle.swift` (`contentProcessDidTerminate`), `BrowserModel` `isShown` wiring | — | **Linen-owned, not touched** | Linen's `evaluateJavaScript(_:within:as:)` / `callAsyncJavaScript(_:arguments:in:within:as:)` overloads call the existing async `BrowserPage` signatures: this plan keeps those signatures unchanged and callable. Linen does not touch `BrowserPage*.swift`, `PageDriver`, `PageFrameRegistry`, `liveView`/`retire`, or engine adapters. Each PR must compile standalone on `d3cf409`; Task 3/4 teardown hooks therefore must not depend on Linen's `isShown`/`unloadUntilShown`. |
| `WSurf/MCP/MCPBrowserSession.swift` | 2, 3, 4, 5, 6 | MCP-owned | Same. Further splitting into new files below keeps it from growing past review size. |
| `WSurf/MCP/MCPAccessConsent.swift` | 3 | MCP-owned | |
| `WSurf/MCP/MCPDevelopmentLease.swift` (new) | 3 | MCP-owned | |
| `WSurf/MCP/MCPDevelopmentTools.swift` (new) | 3–6 | MCP-owned | Per-tool handlers extending `MCPBrowserSession`. |
| `WSurf/Web/Page/PageDiagnostics.swift` (new) | 6 | New, page-family | Bounded buffers + sanitizers; no overlap. |
| `WSurf/Web/Page/PageViewport.swift` (new) | 4 | New, page-family | Pure layout/budget math; no overlap. |
| `WSurfTests/Agent/MCPTransportTests.swift`, `MCPPrivacyTests.swift` | 2–6 | MCP-owned tests | Catalog-set assertions use `MCPToolCatalog.entries`, no literal counts except the one in Task 3. |
| `WSurfTests/Web/{PageDriverTests,PageInteractionTests,ChromiumPageTests,PageComputerInputTests,PageDriverConsentGateTests}.swift` | 1, 2 | Shared tests | |
| `WSurfTests/Web/Development*Tests.swift` (new) | 4–6 | New | |
| `MCP.md`, `CHANGELOG.md` | 1–6 | MCP-owned docs | |
| `WSurf/Web/Credentials/*`, `Settings/Pages/Credential*`, `WebAuthnAdapter`, `BrowserApplication`, `WSurf/Agent/*` (AI call sites), Package pins | — | **Not touched** | Credential/vault, import-export, AnyLanguageModel worker own them. |

## Ledger

| Slice | Commit subject | Gate | Status |
|---|---|---|---|
| 0 | docs: spec refresh + this plan (PR13 base) | Main preflight of this plan | plan sent to Main |
| 1 | fix(mcp): delivery receipt and back-navigation freshness | probes reproduce risks; scenarios 9-10 | not started (awaits relay + probe lease) |
| 2 | feat(mcp): real hover, element waits, element/region screenshots | scenario 11 | blocked on 1 |
| 3 | feat(mcp): development consent, lease, getDevelopmentInfo | scenarios 1, 7 | blocked on 2 (MCP-owned files) |
| 4 | feat(mcp): setViewport, emulateDevice, reloadPage, resetDevelopment | scenarios 2, 3, 7 | blocked on 3 + shared hook declaration |
| 5 | feat(mcp): findElements, inspectElement | scenario 4 | blocked on 3 |
| 6 | feat(mcp): startDiagnostics, readConsole, readNetwork | scenarios 5, 6, 8 | blocked on 3 + shared hook declaration |

First runnable verification (once Main grants the Pro lease and relay confirms main): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -scheme WSurf -destination 'platform=macOS' -only-testing:WSurfTests/PageInteractionTests -only-testing:WSurfTests/MCPTransportTests` on an owned isolated snapshot. Scheme and flags: copy from the established Pro build invocation, not guessed here.

## Shared-edit declarations to send Main before editing

- S1: `BrowserPage.sendKeyEvent(_:)` / `ChromiumPage.sendKeyEvent(_:)` Void → `Bool` (all callers in `PageNativeInput`, `PageComputerInput`); `ChromiumPage.goBack`/`refreshHistory`; `PageDriver.goBack`.
- S2: `PageComputerInput.computerMouse` move-branch extraction; `PageInteraction.waitForPage`/`screenshot` new defaulted params; `ChromiumPage.capture` crop; `PageRuntime` element-state helper.
- S3: `BrowserPage` capability hook (read-only value type); `BrowserTab` teardown hook.
- S4: `BrowserPage` viewport override + CDP emulation methods; `WebViewContainer` layout path; `BrowserTab` reload.
- S6: `ChromiumDevTools` Runtime/Network subscribe-on-demand; WebKit page-world script install/remove scoped to one `BrowserPage`.

---

## Task 1 (Slice 1): Delivery receipt and back-navigation freshness

**Files:**
- Modify: `WSurf/Web/Engines/BrowserPage.swift` (`sendKeyEvent`, line ~427), `WSurf/Web/Engines/ChromiumPage.swift` (`sendKeyEvent` ~450, `goBack` ~355, `refreshHistory` ~620), `WSurf/Web/Page/PageNativeInput.swift` (`pressKey` ~42), `WSurf/Web/Page/PageDriver.swift` (`goBack` ~489), `WSurf/Web/Page/PageComputerInput.swift` (key callers)
- Test: `WSurfTests/Web/PageInteractionTests.swift`, `WSurfTests/Web/ChromiumPageTests.swift`, `WSurfTests/Web/PageDriverTests.swift`
- Docs: `MCP.md`, `CHANGELOG.md`

**Interfaces:**
- Produces: `BrowserPage.sendKeyEvent(_ event: NSEvent) -> Bool` (`@discardableResult`; true only when the engine view accepted/forwarded the event; false for closed page, no responder, nil view, or Chromium not attached). `ChromiumPage.sendKeyEvent(_:) -> Bool` same semantics. `PageDriver.pressKey` returns `"The key was not delivered to the page."` when either event returns false; success text stays `"Sent <key>. Check the resulting page.\n…"`. `PageDriver.goBack(in:) async -> String` returns `"Went back. …"` only when `webView.goBack()` returned non-nil and the navigation completed with a changed document URL or same-document history position; otherwise `"Could not go back."`.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write failing probes (before any adapter change).** In `PageInteractionTests`, add `@Test(arguments: engines) func pressKeyDeliversKeyDownUp` using `HTTPFixtureServer` page `<input id=a onkeydown="document.body.dataset.d=(document.body.dataset.d||'')+'d'" onkeyup="document.body.dataset.d+= 'u'">`; focus via `PageDriver.pressKey("ArrowDown", ref:1, in:)` and `#expect(dataset.d == "du")` on both WebKit and Chromium (parameterize with the engine factory already used in `ChromiumPageTests`). Add `pressKeyReportsFailureWithoutResponder` (page removed from window → result does not start with `"Sent "`). In `PageDriverTests` add `goBackReportsNoNavigation` (history empty → `"There is no page to go back to."`), `goBackFailsWhenNavigationNil` (stub engine whose `goBack()` returns nil → `"Could not go back."`), and `goBackRejectsChangedForeignTarget` (history list mutated to a different origin between check and traversal → no `"Went back."`).
- [ ] **Step 2: Run on Pro (via Main lease) to observe.** Run `-only-testing:WSurfTests/PageInteractionTests/pressKeyDeliversKeyDownUp` etc. Record for each risk: reproduced / not reproduced, app commit, engine. **A risk that does not fail is closed as “not a defect”, its production edit is dropped, and its test stays as a regression guard.** Expected for confirmed risks: FAIL (`"Sent ArrowDown"` with dataset empty, or `"Went back."` with nil navigation).
- [ ] **Step 3: Implement for each reproduced root cause only.** `sendKeyEvent` returns the engine's real acceptance; `pressKey` aborts on false; `PageDriver.goBack` guards a nil `PageNavigation`, awaits settle, and compares pre/post URL + history index; `ChromiumPage.goBack` validates the back target against a refreshed history (`refreshHistory` made awaitable, fetch failure propagated, not suppressed) before authorizing traversal, while keeping `invalidateCredentialContexts` calls intact.
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
  - `PageDriver.screenshot(in:target:region:) async -> ScreenshotResult?` with `struct ScreenshotResult { let jpeg: Data; let bounds: CGRect /* CSS px */; let scale: CGFloat }`, `enum ScreenshotTarget { case viewport, element(ref: Int), region(CGRect) }`. Existing `screenshot(in:)` stays as a viewport convenience returning `Data?` for current test callers.
  - `BrowserPage.capture(rect:width:afterScreenUpdates:)` rect is **view points**; the crop converts CSS→view using page zoom and `view.isFlipped`; WebKit via `WKSnapshotConfiguration.rect`, Chromium via CDP clip with `scale`.
  - `MCPToolCatalog.Parameter` gains `type: "number"` (finite Double) and `type: "region"` (object `{x,y,width,height}` numbers, `additionalProperties:false`); schema + `validate` handled like the existing special-cased `"array"`. `screenshotPage` parameters: `tabID`, optional `observationID`, optional `ref`, optional `region`. `waitForPage.condition` description lists all seven conditions.
  - `MCPBrowserSession.usePage`: `usesRef` also true when `arguments["ref"] != nil` (already) — screenshot with `ref` therefore requires the current observation; `observationID` and `ref` must be supplied together; with `region` → `invalidParams`.

- [ ] **Step 1: Write failing tests.**
  - `PageInteractionTests.hoverTriggersCssHover` (both engines): fixture `<style>#m:hover+#sub{display:block}#sub{display:none}</style><button id=m>Menu</button><div id=sub>Sub</div>`; `hover(ref:1)` then readPage contains `Sub`; assert `getComputedStyle(sub).display == "block"`.
  - `hoverFailsWhenCovered`, `hoverFailsOffscreen`, `hoverFailsWhenAppInactive` (inject inactive via the existing key-window seam; result begins `"Hover needs"`).
  - `waitForPageElementConditions`: ambiguous selector, `elementVisible` after `setTimeout` reveal, `elementHidden` after removal and with zero matches, `elementEnabled` after `disabled=false`, invalid selector, selector of 2,049 bytes (incl. a 3-byte character at the boundary) → input error, navigation mid-wait → staleMessage.
  - `screenshotElementAndRegionBounds` (both engines, with `PageZoom` at 125% and a scrolled fixture): known colored div → decoded bitmap size equals `bounds.size × scale ± 1 px` and center pixel color matches; `screenshotRejectsOffscreenRegion`, `…ZeroArea`, `…NaN`, `…ElementAndRegionTogether`, `…SensitiveFieldRefusesCrop`, `…NavigationDuringCapture`.
  - `MCPTransportTests.catalogExposesRegionSchema`: `screenshotPage` schema has `region` as object with four `number` properties, `additionalProperties == false`; `validate` rejects `region` with `Double.nan`-equivalent (non-finite JSON is not representable → reject strings), negative width, extra key.
- [ ] **Step 2: Run on Pro → FAIL** (`"Dispatched hover"`; unknown condition; extra argument rejected).
- [ ] **Step 3: Implement** the interfaces above. Element visibility rule lives once in `PageRuntime` as `R.elementState(selector) -> {count, visible, enabled}` (rendered rect nonempty, `visibility != hidden`, `display != none`, opacity > 0 is not required; enabled adds `disabled`, `inert`, `aria-disabled="true"`, and disabled-fieldset ancestry). Screenshot target geometry comes from `R` (`getBoundingClientRect`, `devicePixelRatio`) and is revalidated after capture against the same document.
- [ ] **Step 4: Run Step 1 tests + `PageComputerInputTests` (move-branch extraction must not change computer behavior) → PASS.**
- [ ] **Step 5: Update `MCP.md` tool table (hover wording: real pointer, CSS `:hover` works) and catalog instructions text at `MCPToolCatalog.swift` line ~20 that currently says hover “dispatches handlers only”; `CHANGELOG.md`; commit** `git commit -m "feat(mcp): real hover, element waits, element and region screenshots"`.

## Task 3 (Slice 3): Development consent, lease, capability reporting

**Files:**
- Create: `WSurf/MCP/MCPDevelopmentLease.swift`, `WSurf/MCP/MCPDevelopmentTools.swift`
- Modify: `WSurf/MCP/MCPAccessConsent.swift`, `WSurf/MCP/MCPBrowserSession.swift`, `WSurf/MCP/MCPToolCatalog.swift`, `WSurf/Web/Engines/BrowserPage.swift` (capability hook), `WSurf/Browser/BrowserTab.swift` (teardown hook), `MCP.md`, `CHANGELOG.md`
- Test: `WSurfTests/Agent/MCPPrivacyTests.swift`, `WSurfTests/Agent/MCPTransportTests.swift`, `WSurfTests/Agent/MCPDevelopmentLeaseTests.swift` (new)

**Interfaces:**
- Produces:
  - `MCPAccessConsent.Access` gains `.development` (superset of `.control`); `MCPAccessConsent.share(client:pages:development:in:) async -> Access?` — the extra alert button **Allow Development** only when `development == true`, with text that DOM inspection and console output can disclose private data.
  - `requestAccess` optional boolean parameter `development` (default absent == false → current behavior byte-for-byte).
  - `AssistantPageCapability` gains `.development` check in `MCPBrowserSession.permits(_:capability:)`; `.development` implies read+control grant AND `Grant.access == .development`.
  - `actor`-free `@MainActor final class MCPDevelopmentLease { let tab: UUID; let connection: UUID; let pageGeneration: ObjectIdentifier; var viewport: AppliedViewport?; var emulation: AppliedEmulation?; var diagnostics: DiagnosticsEpoch?; func owns(page: BrowserPage, connection: UUID) -> Bool; func release(reason: ReleaseReason) }` and `MCPBrowserSession.leases: [UUID: MCPDevelopmentLease]` (per tab). `ReleaseReason`: `.reset, .disconnect, .grantDowngrade, .tabClosed, .profileChanged, .pageDestroyed, .engineReplaced`. Cleanup path is internal and needs no permission.
  - `BrowserPage.developmentCapabilities: DevelopmentCapabilities` (value type: `engine: String`, `viewport: Support`, `deviceAxes: [String: Support]`, `diagnostics: [String: Support]`), `enum Support { case supported, limited(String), unsupported(String) }`; filled in Tasks 4/6; here WebKit/Chromium return exact runtime/engine and responsive-viewport status only.
  - Tool `getDevelopmentInfo(tabID)`: read grant; returns engine, runtime, measured `innerWidth/innerHeight`, zoom, owner (`none|self|other`), capability matrix. No DOM content.
  - Shared envelope `MCPDevelopmentTools.result(kind:…)` where `kind ∈ {ok, unsupported, invalidInput, stale, denied, ownershipConflict, pageGone}`; errors set `isError: true`; no empty success.
  - Lease teardown wired: session `revoke()`, grant downgrade, `BrowserTab` close/profile change/page replacement call `releaseLease(for:reason:)`.
- Consumes: Task 2 catalog `number` type (not needed here); `MCPBrowserSession.permits/onScreen`.

- [ ] **Step 1: Write failing tests.** `MCPPrivacyTests`: `omittedDevelopmentKeepsExistingPrompt` (same prompt buttons, result access ≤ control); `readOnlyAndControlCannotCallDevelopmentTool` (`getDevelopmentInfo` works with read; a development-only tool name stub returns denied); `deniedSiteStaysDenied`; `revocationDuringPendingWork` (revoke between await points → no data returned). `MCPDevelopmentLeaseTests`: `secondConnectionGetsConflictBeforeMutation`, `releaseOnDisconnect/TabClose/EngineReplaced`, `lateResultFromOldGenerationIsRejected`. `MCPTransportTests`: `catalogHas29ToolsAfterSlice6` — (this literal assertion lands in Task 6; here assert `getDevelopmentInfo` ∈ catalog and baseline names ⊂ catalog).
- [ ] **Step 2: Run on Pro → FAIL.**
- [ ] **Step 3: Implement** (consent alert, lease, envelope, tool). `usePage` gains `capability: .development` path; keep the single `PageAutomationGuard` scope pattern.
- [ ] **Step 4: Run MCP suites → PASS; existing `MCPTransportTests` catalog equality asserts keep passing.**
- [ ] **Step 5: Update `MCP.md` (consent, getDevelopmentInfo, leases) + `CHANGELOG.md`; commit** `git commit -m "feat(mcp): development consent, lease and capability reporting"`.

## Task 4 (Slice 4): Viewport, device emulation, reload, reset

**Files:**
- Create: `WSurf/Web/Page/PageViewport.swift`
- Modify: `WSurf/Web/WebViewRepresentable.swift` (`WebViewContainer` layout), `WSurf/Web/Engines/BrowserPage.swift`, `WSurf/Web/Engines/ChromiumPage.swift`, `WSurf/Browser/BrowserTab.swift`, `WSurf/MCP/MCPDevelopmentTools.swift`, `WSurf/MCP/MCPToolCatalog.swift`, `MCP.md`, `CHANGELOG.md`
- Test: `WSurfTests/Web/DevelopmentViewportTests.swift` (new), `WSurfTests/Agent/MCPDevelopmentLeaseTests.swift`

**Interfaces:**
- Consumes: Task 3 lease + envelope + `DevelopmentCapabilities`.
- Produces:
  - `PageViewport` pure helpers: `struct ViewportRequest { width: Int; height: Int }`, `static func validate(_:zoom:scale:) -> Result<ViewportRequest, ViewportError>` (64…4096, ≤ 8,388,608 CSS px, ≤ 33,554,432 backing px), `static let profiles: [String: Profile]` with the five spec profiles, `Profile.dimensions(orientation:) -> (Int, Int)`.
  - `BrowserPage.developmentViewport: CGSize?` (nil == normal layout, never persisted); `WebViewContainer` layout uses it instead of host bounds when non-nil, with input/capture conversion following; `func applyViewport(_ size: CGSize?) async throws -> MeasuredViewport` (`innerWidth/innerHeight/devicePixelRatio`) — measures after layout; rolls back and throws with measured dims on budget miss.
  - Chromium: `ChromiumPage.applyDeviceEmulation(_ profile: Profile?) async throws` using `Emulation.setDeviceMetricsOverride` + `setTouchEmulationEnabled` + `setEmitTouchEventsForMouse`/mobile flag; clearing via `clearDeviceMetricsOverride`. A completion whose lease generation no longer matches is dropped. `developmentCapabilities.deviceAxes` advertises `dpr/touch/mobile` as `.supported` **only after** the Task 4 native probe test passes on the embedded runtime; otherwise report `.unsupported(reason)` observed by the probe.
  - WebKit: responsive presets via `developmentViewport`; `emulateDevice(phone|tablet)` returns `unsupported` before mutation.
  - Tools: `setViewport(tabID, width: integer, height: integer)`, `emulateDevice(tabID, profile: string, orientation: string)` (`profile ∈ responsive-phone|responsive-tablet|responsive-desktop|phone|tablet`, `orientation ∈ portrait|landscape`), `reloadPage(tabID)` (uses `BrowserPage.reload()`; keeps owned config only if the new document is still authorized, else releases), `resetDevelopment(tabID)` (idempotent; removes only this lease's values via compare-then-restore against last applied).
- [ ] **Step 1: Write failing tests.** `DevelopmentViewportTests`: validation table (63/64/4096/4097, area, backing budget), `setViewportMeasuresInnerWidth` (390×844 → `window.innerWidth == 390`, breakpoint `@media (max-width:400px)` active, both engines), `viewportSurvivesZoomInsetSplit`, `screenshotAndInputGeometryFollowViewport`, `phoneProfileFailsBeforeMutationOnWebKit` (no state change, lease not acquired), `phoneProfileAppliesAxesOnChromium` (DPR 3, `ontouchstart` present, mobile viewport meta honored), `emulateThenSetViewportClearsDeviceAxes`, `manualZoomAfterOverrideNotOverwrittenByReset`, `staleCompletionAfterResetNotReapplied`, `reloadKeepsOwnedConfigOnlyWhileAuthorized`, `resetIsIdempotentAndNeverTouchesOtherClient`.
- [ ] **Step 2: Run on Pro → FAIL.**
- [ ] **Step 3: Implement.** Layout participation: reuse the one frame-derivation function in `WebViewContainer`; do not assign `BrowserPage.frame` directly. Serialize transitions with one in-flight `Task` per lease; cancel on release.
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
- Modify: `WSurf/Web/Engines/ChromiumDevTools.swift` (Runtime/Network subscribe-on-demand), `WSurf/Web/Engines/BrowserPage.swift` (WebKit page-world hook install/remove; `developmentCapabilities.diagnostics`), `WSurf/MCP/MCPDevelopmentTools.swift`, `WSurf/MCP/MCPToolCatalog.swift`, `MCP.md`, `CHANGELOG.md`
- Test: `WSurfTests/Web/DevelopmentDiagnosticsTests.swift` (new), `WSurfTests/Agent/MCPTransportTests.swift`

**Interfaces:**
- Consumes: Task 3 lease (`diagnostics: DiagnosticsEpoch?`) and teardown reasons.
- Produces:
  - `PageDiagnostics.Buffer` — `struct Record { seq: UInt64; timestamp: Date; documentID: String; stream: Stream; body: [String: Value] }`, `enum Stream { console, network }`, `final class Buffer { init(maxRecords: 1_024, maxBytes: 2 * 1_048_576, maxRecordBytes: 8 * 1_024); func append(_:) ; func read(stream:cursor:limit:) throws -> Page /* records, nextCursor, dropped, truncated */ ; func clear() }`. Cursor is an opaque string `base64(connection|tab|stream|epoch|seq)` validated on read; foreign/malformed/expired-epoch → `.invalidCursor`; behind-eviction → data + `dropped` count.
  - `PageDiagnostics.sanitize(url:) -> String?` strips userinfo, query, fragment (applied at ingestion and again at output).
  - `ChromiumDevTools.subscribeDiagnostics(page:sink:) -> Token` / `unsubscribe(Token)`: enables `Runtime`/`Network` only while a token exists; events attributed to the real target/context/frame; denied-origin frames dropped without buffering; no header/body fields read.
  - WebKit: page-world (`WKContentWorld.page`) console/error/unhandledrejection/fetch/XHR hooks installed per `BrowserPage` as a `WKUserScript` plus per-page handler; removal restores wrappers only if the current function is still the owned wrapper; never touches other views of a shared content controller; messages validated against native page, frame, lease generation before buffering. Declared coverage lists active sources and gaps (early events, workers, inaccessible frames, JS disabled, isolated-world exclusion).
  - Tools: `startDiagnostics(tabID)` (acquires lease; repeat by same owner returns active epoch without clearing), `readConsole(tabID, cursor?: string, limit?: 1…100)`, `readNetwork(tabID, cursor?, limit?)`; every response carries `engine, sources, gaps, epoch, documentID, nextCursor, dropped, truncated`. Unknown status/timing is `null` + `"unknown"` outcome, never 0.
  - Document change: clear buffers, bump epoch, invalidate old cursors, reattach hooks to the new authorized document; denied destination stops capture and releases lease.
- [ ] **Step 1: Write failing tests.** `bufferEvictsOldestWithLossCounters` and `bufferHonoursByteCapAndRecordTruncation` (pure, no native); `cursorForeignMalformedExpiredRejected`; `sanitizeStripsUserinfoQueryFragment`; native fixture `consoleErrorAndNetworkOutcomes` (known `console.error`, 200, 404 and aborted fetch both engines → records with declared coverage; zero pre-start history; no headers/bodies/URL secret/object dump); `webKitHooksPreservePageBehavior` (promise rejection, XHR callbacks, console still reach page); `noHooksWhileDisabled` (before start and after reset: no script, handler or CDP domain enabled); `sharedContentControllerSecondTabUnhooked`; `burst10kEventsBoundedMemory`; `oldGenerationEventRejected`; `reloadStartsNewEpochOldCursorInvalid`; `forbiddenChildFrameNotBuffered`; `catalogHas29Tools` (literal `MCPToolCatalog.entries.count == 29` and the 10 names).
- [ ] **Step 2: Run on Pro → FAIL.**
- [ ] **Step 3: Implement.** Buffer mutations and eviction on `@MainActor`; ingestion functions are `nonisolated` only if they take immutable values. No disk writes or `Logger` with record content.
- [ ] **Step 4: Run all new suites + `MCPTransportTests` + WebAuthn/credential-context tests → PASS.**
- [ ] **Step 5: `MCP.md` (diagnostics coverage table, limits) + `CHANGELOG.md`; commit** `git commit -m "feat(mcp): console and network diagnostics"`.

## Native stage verification (after Task 6; Main lease required)

Scenarios 1–12 of §7 run on Pro (owned isolated snapshot, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, Debug build) then a stage app on Air (`WSURF_STAGE=1`, separate `WSURF_STAGE_HOME`) driven by a real external MCP client against local fixtures only. Record app commit, engine/runtime, observed result per scenario in the PR description. No installed-app replacement, deploy, or production data.

## Self-Review

- **Spec coverage:** §1 consent → Task 3; §2 tools → Tasks 2–6 (29 total, asserted in Task 6); §2 extensions → Task 2; §3 viewport/devices → Task 4; §4 inspection → Task 5; §5 diagnostics → Task 6; §6 lifecycle → Tasks 3, 4, 6 (teardown tests); §7 scenarios 1-12 → tests above + stage section; scenarios 9-10 → Task 1 (+9 on every baseline tool: Task 1 Step 1 extends the existing fixture suite with one MCP-end-to-end row per baseline tool **recorded in the PR table; failures there become Task 1 fixes only if a native run reproduces them**); §8 slicing → six tasks, one PR.
- **Types:** `Support`, `DevelopmentCapabilities`, `MCPDevelopmentLease`, envelope `kind`, `ScreenshotResult`, `PageViewport.Profile` are defined once (Tasks 2–4) and reused with the same names in Tasks 5–6.
- **Open decision for Main preflight (D1):** `PageDriver.hover` signature is kept, so the in-app assistant gets real hover too (spec §85 accepts this). If Main wants assistant hover unchanged, split to `PageDriver.hoverPointer` and keep `hover` — otherwise no action.
- **Open decision (D2):** Task 1 `sendKeyEvent -> Bool` changes a `BrowserPage` API (shared). Alternative is a separate `sendKeyEventReceipt`; plan assumes the single signature change with `@discardableResult` — needs Main approval per S1.
