# WSurf MCP Development Mode

Date: 2026-10-08

Status: Conversational contract approved, including WebKit/device/network limitations. The user additionally approved real hover, element-state waits, and element/region screenshots, and required checking existing MCP behavior on both engines. This revised written specification awaits user review. Product implementation starts only after written-spec approval, implementation-plan review, and selection of an execution method.

## Intent and agreed scope

An external MCP client should test and inspect real pages in WSurf: change responsive dimensions, request supported device emulation, inspect ordinary DOM elements and their layout, perform existing interactions, capture screenshots, and observe console errors and network outcomes.

Extend the existing MCP server and `BrowserPage` boundary. Do not introduce another server, a parallel permission system, or a Chromium-only public automation API. WebKit and Chromium expose their actual capabilities; an unsupported request fails rather than pretending that a screenshot or user-agent string is a different device.

The user accepted a deliberately narrower network view: bounded method, sanitized URL/path, status, timing, and failure metadata, without cookies, authentication headers, or request/response bodies. WebKit page instrumentation is not a complete Network panel. Responsive dimensions are not full device emulation.

### Required outcomes

- Existing MCP operations have one public contract across WebKit and Chromium; repair adapter gaps before layering new development tools on them.
- Real CSS hover, condition-based element waits, and element/region screenshots extend the existing tools rather than creating engine-specific alternatives.
- Explicit native **Allow Development** consent, limited by existing tab/domain grants and website restrictions.
- Actual, measured CSS viewport changes; screenshots and input geometry follow the same page layout.
- Device profiles declare their required axes; all required axes are supported before any changes occur.
- Ordinary DOM discovery and CSS inspection reuse existing document/observation/reference guards.
- Future-event diagnostics expose their coverage, cursor, document identity, and buffer losses.
- One development owner per tab, temporary state, bounded memory, and reliable cleanup without overwriting subsequent manual changes.
- Native build/test on Pro, followed by stage-app verification with real MCP calls on local fixtures before claiming the feature works.

### Non-goals

- Another MCP server, raw JavaScript execution, arbitrary CDP access, raw HTML export, or a second action-reference system.
- Adding browser engines or changing persisted website-engine preferences; engine lifecycle work remains separate.
- Real iOS/Android browser emulation, OS features, or engine switching disguised as a device profile.
- Full DevTools, worker debugging, response-body inspection, HAR export, historical event replay, or disk logging.
- New TypeScript/Effect dependencies or unrelated MCP refactoring.
- Replacing the user's installed app or using production browsing data for verification.

## Existing boundaries and integration

Reuse `MCPBrowserSession` for connection authorization, `PageDriver` for shared page-operation policy and dispatch, `PageRuntime` for DOM observations and references, and `BrowserPage` for engine-specific page behavior. Existing click/type/select/scroll/wait/screenshot tools remain the common interaction surface.

`WebViewContainer` currently derives and reapplies native frames from host layout. A one-time assignment to `BrowserPage.frame` will not implement persistent responsive sizing. Temporary viewport sizing must participate in that layout path, including page zoom, insets, split views, input coordinate conversion, and capture geometry.

`PageRuntime` currently discovers visible interactive controls. Extend its existing reference registration for DOM inspection; do not add unrelated selectors or identifiers to the action path. Existing action tools retain their type and safety checks even when a reference originated from DOM discovery.

`ChromiumDevTools` already has a native CDP connection, but enabling domains is not evidence that console/network events are collected. Add only the subscriptions needed by this contract, attributed to the real target/context/frame. Do not expose the connection as a generic tool.

WebKit script installation and message routing must respect shared content controllers and opener-created views. Global script/handler removal or globally active hooks for unrelated views are not acceptable cleanup mechanisms.

### Ownership split

- MCP owns consent checks, connection identity, tab leases, result validation, bounded buffers, and public response envelopes.
- Page runtime owns reference registration and bounded DOM/CSS extraction for the current document.
- Page/native presentation owns actual layout and reversible overrides. Engine adapters supply supported emulation and diagnostic sources through the existing page boundary.

Use direct extensions of these boundaries. No new general-purpose automation framework or duplicate engine abstraction is needed. The engine session has not confirmed a shared implementation interface; this spec does not claim that coordination occurred or modify its worktree.

### Cross-engine parity comes first

The 2026-10-08 source review used the task branch updated from `origin/main` at `30069a1`, including the Linen migration. This review found adapter/result-contract risks, not a completed native parity test. In particular, the current batch form limit is 32 fields; do not reintroduce the earlier eight-field limit.

| Existing tools | Required shared behavior and source-review findings |
|---|---|
| `requestAccess`, `listTabs`, `newTab`, `switchTab`, `closeTab` | Same tab/window/origin grant and private-page rules. These route through shared browser/session logic; that does not prove the page engine is ready after a tab transition. |
| `readPage`, `clickOnPage`, `typeOnPage`, `selectOption`, `fillFields`, `inspectControl`, `setChecked`, `waitForPage`, `scrollPage` | Shared runtime through WebKit isolated-world evaluation or Chromium CDP isolated contexts. Verify actual DOM effects and observation freshness on both. Synthetic value/click events and inaccessible cross-origin frames are shared limitations, not evidence of a Chromium-only defect. |
| `pressKey`, `hoverOnPage`, `screenshotPage` | Native implementations differ. Chromium key forwarding can return without delivery while the driver reports “Sent”; hover currently only dispatches DOM events on both engines; WebKit snapshots and Chromium CDP capture need common geometry and explicit failure outcomes. |
| `navigate`, `goBack` | Preserve origin consent and report the actual navigation outcome. Chromium history refresh is asynchronous and suppresses fetch failure; stale cached history must not authorize a different current back destination. The shared back driver ignores a nil navigation result before reporting “Went back”. |

Root-cause anchors: `PageNativeInput.swift` (`hover`, `pressKey`), `ChromiumPage.swift` (`becomeFirstResponder`, `sendKeyEvent`, `capture`, `refreshHistory`), `BrowserPage.swift` (native forwarding, history, capture), and `PageDriver.swift` (`goBack`). Do not fix each MCP caller separately or suppress failures. Confirm affected native behavior with fixtures, then repair the shared operation boundary and the deficient engine adapter.

Native dispatch must expose whether it actually accepted/delivered an event; a dropped event is an error, not successful text. Accepted delivery does not prove a page-level effect: return a fresh observation, and acceptance fixtures must assert focus, key events, and resulting page state. Refresh and validate a trusted navigation target before authorizing history traversal; guard document/engine changes through the transition.

The common baseline and the three approved tool upgrades are required on both engines. `getDevelopmentInfo` reports the actual engine/runtime and operation capabilities for the granted tab, with supported, limited, or unsupported status and a concrete reason where needed. Capability metadata is operational data, not a grant. Keep one stable public tool catalog; never switch engines silently or use “unsupported” to hide an unfinished common adapter. Legitimate differences remain explicit for advanced device axes and diagnostic coverage.

Engine replacement invalidates observations, in-flight work, and capability snapshots even if the URL is unchanged. Engine-specific capability discovery must not weaken existing grant, frame, private-browsing, or action-consent checks.


## 1. Permission contract

`requestAccess` gains optional `development: true`. Omission or `false` preserves current behavior. When requested, the native prompt additionally offers **Allow Development**, explaining that DOM inspection and console/error output can disclose additional private site data. Connecting or discovering tools never grants access.

Development permission includes existing control permission but cannot override website restrictions, profile isolation, private-browsing restrictions, tab liveness, or the current grant's domain scope. Existing Read Only and Allow Control choices do not grant development data access.

`getDevelopmentInfo` needs the existing read grant and returns operational metadata, not DOM content or diagnostic records. Every other new development tool requires development permission. State-changing operations also obey the existing control/on-screen requirements where applicable; development mode is not a bypass for background native input.

Check permission and live page identity before work, after asynchronous work, and before returning data or committing state. Diagnostic ingestion checks the source frame/origin and current grant; a denied source is not buffered for later release. A permitted parent frame does not authorize a forbidden child frame.

All page-supplied text and events are untrusted. Diagnostic URLs, stacks, and DOM inspection output are not observed-link provenance and cannot authorize navigation, consent, additional access, or filesystem operations.

## 2. Public MCP tools

Parameters retain existing tab ID and MCP error conventions. Results distinguish successful observation, unsupported capability, invalid input, stale document/observation/cursor, permission denial, ownership conflict, and page disappearance. Do not return an empty successful result for any of these failures.

| Tool | Contract |
|---|---|
| `getDevelopmentInfo(tabID)` | Actual engine, measured viewport/zoom/device metrics, active owned overrides, supported profiles/axes, and diagnostic coverage. Owner is reported as none/self/another client, not another connection's identity. |
| `setViewport(tabID, width, height)` | Establish a temporary responsive CSS viewport and return requested and measured dimensions after native layout settles. Clear this owner's device-emulation axes transactionally rather than leaving conflicting mobile overrides active. |
| `emulateDevice(tabID, profile, orientation)` | Resolve a fixed profile, check every required axis, then apply the temporary configuration. Return profile requirements, applied axes, and actual measured metrics. |
| `findElements(tabID, selector, offset, limit)` | Bounded CSS-selector discovery of ordinary DOM elements. Return the current observation/document identity, registered refs, summaries, geometry, and pagination metadata. |
| `inspectElement(tabID, observationID, ref)` | Validate the existing observation/reference guards, then return a bounded DOM/CSS inspection for that live element. |
| `startDiagnostics(tabID)` | Acquire the tab's development lease if free and begin future-event capture. Return the epoch/document, starting cursor, and actual coverage. No automatic reload. |
| `readConsole(tabID, cursor, limit)` | Read this owner's bounded console/error stream and return the next cursor, epoch/document, coverage, truncation, and drop information. |
| `readNetwork(tabID, cursor, limit)` | Read this owner's bounded network metadata stream using the same cursor semantics. |
| `reloadPage(tabID)` | Reload the granted live page through existing lifecycle behavior; retain owned development configuration only while the new document remains authorized. |
| `resetDevelopment(tabID)` | Stop capture, clear buffers, and remove only this connection's current overrides. An already-reset state is an explicit idempotent result; another client's state is never reset. |

DOM reads need development consent but do not acquire an exclusive lease. Exclusive ownership covers development mutations, capture, and reading the owner's capture buffers. Existing permitted interactions are not a new global tab lock.

### Extensions to existing tools

Retain the existing permissions: hover requires control and an on-screen tab; waits and screenshots require read access. Development consent is still required when an operation uses an arbitrary DOM-inspection reference rather than an existing ordinary control reference.

- `hoverOnPage(tabID, observationID, ref)` must use real engine pointer movement/hit-testing so CSS `:hover` can change. Reuse native input facilities behind `BrowserPage`, validate the observed target and its current geometry immediately before dispatch, and return a fresh observation. Do not substitute `dispatchEvent`, a CSS class, or forced styling. Offscreen, covered, detached, or denied targets fail explicitly. No claim that moving the pointer necessarily opened an application tooltip.
- `waitForPage` retains existing conditions and adds `elementVisible`, `elementHidden`, and `elementEnabled`. These conditions use the existing `value` parameter as a bounded CSS selector. Require an unambiguous match; hidden also succeeds when no matching element remains. “Visible” uses shared rendered-element geometry/visibility rules, not absence of occlusion; “enabled” additionally checks disabled/inert/ARIA-disabled state. Preserve the bounded timeout and cancellation. Permission/document changes terminate the wait rather than matching a new unauthorized document; success returns a fresh observation. No arbitrary JavaScript predicate.
- `screenshotPage` retains viewport capture by default and accepts either an element target (`observationID`, `ref`) or a viewport-relative CSS-pixel `region` (`x`, `y`, `width`, `height`), never both. Require finite coordinates, positive dimensions, and a nonempty area fully inside the current viewport; do not silently scroll, stitch, or change viewport. Offscreen elements are rejected so the client can explicitly scroll and obtain a fresh observation. Normalize CSS/view/backing-pixel geometry through the engine boundary, retain image-size budgets, and return capture bounds and scale. Keep the existing whole-page sensitive-field refusal before and after capture even for a crop; cropping must not bypass it. Invalid geometry, stale target, privacy denial, and native capture failure remain distinguishable.

All three extensions use the same semantics on WebKit and Chromium. Their fixture cases and native input/capture proof are prerequisites for declaring baseline parity.


### Bounded inputs and output

Use fixed safety ceilings, not user-editable settings:

- Viewport dimensions: integer CSS pixels, 64–4,096 per axis, at most 8,388,608 CSS pixels. Reject layouts/emulation exceeding 33,554,432 estimated backing pixels after zoom/scale before allocating or applying them.
- Selector: at most 2,048 UTF-8 bytes. Offset: nonnegative integer up to 10,000. Limit: 1–100, default 50. Invalid CSS is an input error, not an empty match set.
- Diagnostic read limit: 1–100, default 50. Cursor is opaque, scoped to connection/tab/stream/epoch, and validated before use.
- Combined console/network retention per owned tab: at most 1,024 records and 2 MiB of serialized data. Evict oldest records; expose loss counters. Individual records: at most 8 KiB, with bounded messages/URLs/stacks and explicit truncation flags.
- Inspection: at most 32 selected attributes, 64 allowlisted style properties, 16 ancestor summaries, and 32 KiB serialized output. Bound extraction before constructing large results, not only after serialization.

Do not install listeners or build diagnostic records while capture is disabled. Do not retain native event payloads, remote objects, response bodies, or entire DOM trees just to generate these summaries.

## 3. Viewport and device semantics

`setViewport` means the document's actual `window.innerWidth` and `window.innerHeight`, not window size, an image resize, or a fabricated response. Measure after host layout settles. Account for native geometry, tab zoom, insets, and split layout without persistently changing user settings. If the requested CSS dimensions cannot be obtained within the safety budget, roll back and report failure with measured dimensions.

A requested viewport may exceed the available presentation area. Native presentation must preserve the real requested page size rather than squeezing it back into the host. Input conversion and screenshots use the actual page geometry; native input outside the visible presentation area remains unavailable rather than clicking outside the app.

Responsive presets use only viewport dimensions. Initial profiles are `responsive-phone` (390 × 844), `responsive-tablet` (768 × 1,024), and `responsive-desktop` (1,280 × 800). Portrait/landscape selects the short/long-axis ordering; responsive orientation does not claim a physical screen-orientation override.

Device-axis profiles are `phone` (390 × 844, DPR 3, touch enabled, mobile viewport) and `tablet` (768 × 1,024, DPR 2, touch enabled, mobile viewport). Portrait/landscape selects the dimensions. Their required axes are viewport metrics, DPR, touch, and mobile viewport behavior. They do not change user-agent identity or claim a real mobile OS, Safari, or Android Chrome. Report actual CSS layout/visual viewport metrics, which can differ from device metrics on a mobile page without a viewport meta tag.

WebKit can offer responsive presets through native layout. Its inspected public implementation does not provide DPR/touch/mobile overrides; device-axis profiles therefore fail before changing anything. Chromium implementation must wire and exercise its available native CDP axes. Unsupported capability is reserved for an engine/runtime limitation established by native verification, not an adapter left unimplemented. Advertise device-axis profiles only after their native hooks and actual behavior are exercised; a protocol method's existence alone does not establish support in WSurf's embedded runtime.

No silent downgrade from a device-axis profile to a responsive preset. Capability reports enumerate the precise axes and profiles supported by the current engine/page. Changing engines invalidates capabilities and the old lease; never carry overrides into a different engine instance.

## 4. DOM and CSS inspection

`findElements` uses CSS selectors, traversing the current top-level document, accessible same-origin frames, and open shadow roots through the existing runtime traversal convention. It does not pierce cross-origin frames or closed roots. Report these coverage limits rather than representing inaccessible content as inspected. No arbitrary XPath, expression evaluation, or JavaScript selector callback.

Each returned ref is registered by the existing reference mechanism and bound to the tab, live document, observation, and element signature. Inspection rejects stale observations, detached/replaced elements, or references belonging to another observation/connection. Navigation, reload, profile change, or engine replacement invalidate the relevant observations. DOM mutation cannot silently retarget an old ref to a similar new element.

Inspection contains:

- Tag, safe ID/class/role metadata, bounded accessible name/state metadata, and selected non-sensitive attributes.
- Bounding rect in CSS pixels, relevant scroll geometry, and computed box model: margin, border, padding, box sizing, and content dimensions.
- Computed display, position, overflow, visibility, opacity, flex/grid layout, typography, color, and sizing properties from a fixed allowlist.
- Bounded ancestor summaries sufficient to explain common layout constraints.

This is DOM-derived accessibility information, not a promise of the complete native accessibility tree. It excludes raw HTML, arbitrary attribute dumps, hidden field contents, credentials, current input values, cookies, storage, and object/property evaluation. Reuse existing sensitive-field masking and restrict extraction rather than trying to redact a full DOM export afterward.

Reading DOM metadata does not relax the existing click/type/select guards or turn non-interactive inspection refs into arbitrary native input targets. Existing interaction and screenshot tools keep their original permissions, safety checks, and engine limitations.

## 5. Diagnostic data and coverage

Capture starts explicitly and observes future events. The start response identifies the beginning of the capture epoch; repeated start by the same owner returns the current active epoch without clearing unread data. A client wanting a fresh capture calls reset and start. No automatic reload and no invented pre-start history.

Console records include stream sequence, timestamp, document identity, level/event kind, bounded primitive message/error text, and sanitized source location/stack when available. Do not enumerate remote objects or invoke arbitrary page getters/custom stringification to serialize logged objects. Opaque objects are represented as omitted objects, not dumps.

Console strings can themselves contain private data; **Allow Development** explicitly warns about this. Neither bounded output nor URL sanitization is a guarantee of complete secret removal from arbitrary page text. The tool never directly reads browser credentials, cookies, storage, or secret form fields to enrich a diagnostic.

Network records include sequence, timestamp, document identity, method, sanitized origin/path, native request correlation when available, status when observed, duration when available, outcome/failure category, and source/coverage. Missing status/timing is explicitly unknown, never a synthetic 0 or success. Strip URL userinfo, query, and fragment before retention and again at output validation. Do not collect headers, cookies, request/response bodies, or body snippets in the development buffer.

### Engine-specific sources

| Source | Allowed coverage and limitations |
|---|---|
| Chromium native CDP target | Relevant Runtime console/exception and Network request/response/completion/failure events attributed to the actual page/frame/context. Declare worker and other-target exclusions. Do not expose arbitrary CDP messages. |
| WebKit page console/error instrumentation | Hooks in `WKContentWorld.page`, plus page error/unhandled-rejection events where observable. Hooks are forgeable/bypassable by page code and can miss early events, workers, inaccessible frames, or disabled JavaScript. |
| WebKit fetch/XHR instrumentation | Future page-level requests observed by installed hooks; status/failure only when actually available. Preserve application fulfillment/rejection and XHR/console behavior; diagnostic failures do not suppress site errors. |
| WebKit Resource Timing/navigation metadata | Supplemental resource/nav information with privacy and attribution limits. It is not complete HTTP visibility and may lack response status or failure detail. |

Page console/fetch namespaces are not shared with WebKit's isolated content worlds. An isolated-world hook must not be reported as observing page console/fetch. Install hooks only for the authorized page, and never alter unrelated views just because they share a content controller.

Do not claim historical coverage from old performance entries. Deduplicate supplemental resource timing against hook/native records where correlation is reliable; otherwise label the sources rather than counting a resource twice as two complete requests. Omit unsupported values instead of guessing.

Every start/read response includes engine, active sources, limitations/gaps, epoch/document identity, and dropped/truncated counts. Zero buffered records means only zero observed records under that declared coverage, not no errors or no network failures.

### Cursor and document transitions

Each stream has monotonically increasing sequence numbers within a capture epoch. A cursor identifies the next position for that stream. Missing cursor starts from the oldest retained record; subsequent reads return the next cursor. A cursor behind eviction returns available data plus an explicit gap/drop count. A foreign, malformed, or expired-epoch cursor is an error.

Document change clears prior-document buffers, invalidates old cursors, and starts a new document epoch if the lease and grant still authorize capture. Never merge old and new document records under one identity. Reattach page hooks only to the newly authorized document; report installation/transition gaps, including missed early events. Navigation into a denied scope stops capture and releases owned state.

Late callbacks from the old document/engine/connection are rejected by native identity/generation checks. Page-supplied document identifiers alone are not trustworthy attribution.

## 6. Lifecycle, ownership, and rollback

The lease is per tab and bound to its connection, profile, and concrete page/engine generation. `setViewport`, `emulateDevice`, and `startDiagnostics` acquire it when free. A different client gets an ownership conflict before any changes. Reading one owner's buffers is not permitted through another connection's grant.

Track the baseline and last applied owned values. Failed application rolls back the values it actually changed; return failure rather than leaving half a device profile enabled. Validate all required axes and budgets before beginning the transition. Serialize competing native transitions and discard stale asynchronous completions so reset/revocation cannot be followed by an old operation reapplying an override.

Reset, disconnect, grant downgrade/revocation, tab close, profile change, page destruction, and engine replacement stop subscriptions/hooks, clear buffers, invalidate relevant observations/cursors, and release the lease. Cleanup occurs internally even when the former client no longer has permission to call reset.

Remove only state still owned by that lease. If the user or another valid operation subsequently changed a value, do not restore a stale baseline over it. Removing viewport constraints restores normal layout using the current window/split/inset/zoom state, not a saved obsolete frame rectangle. Temporary settings are not written to profile/global preferences.

Restore WebKit wrappers only if the current function is still the owned wrapper; do not overwrite a later page wrapper. Shared handler/script cleanup must preserve unrelated pages and existing app bridges. Late or forged script messages are checked against the native page, frame, current owner, permission, and generation before any buffering.

## 7. Verification and acceptance

This document describes acceptance work; no product implementation, native build, or stage-app verification is claimed yet. The existing read-only research establishes integration constraints, not runtime proof of new tools.

Build/test the full app on Pro with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, using an owned isolated source/build snapshot. Preserve Pro's established checkout/builds. Copy the result to an owned stage app on Air, using `WSURF_STAGE=1` and a separate `WSURF_STAGE_HOME`. Use a real external MCP client and fresh stage UI evidence.

Stage isolation must include the MCP endpoint, not just browsing storage. Current `LocalMCPEndpoint.path` is `/tmp/wsurf-mcp-<uid>/browser.sock` regardless of `WSURF_STAGE_HOME`; a second app can conflict with, or a relay can connect to, the normal app. Runtime inspection on 2026-10-08 found the normal running WSurf process owning this socket and another task's stage app running. Neither was stopped, granted access, nor used for parity actions. Pro's Xcode 27.0/Swift 6.4 toolchain was reachable; no whole-app parity result is claimed from that check.

Before a real MCP stage run, isolate the stage server and relay to the same owned endpoint derived from the stage home, preserving owner-only directory/socket permissions and lock checks. Keep the production endpoint unchanged. Stage preferences and website storage must also be task-scoped rather than shared with another stage; the current fixed stage preference suite is not adequate evidence of that isolation. This is verification infrastructure for the requested feature, not authorization to connect a probe to production tabs.

Local fixture pages provide responsive breakpoints, ordinary/non-interactive elements, nested/open-shadow content, replaceable elements, secret fields, controlled console/error events, and successful/404/failed requests. Exercise actual behavior, not only capability strings or mocked event forwarding.

Required scenarios:

1. Existing clients omitting `development` retain their prompt/permission behavior. Read Only/Allow Control cannot acquire developer data; denied sites/frames remain denied. Revocation during pending work prevents data return or state reapplication.
2. Set representative phone/tablet/desktop viewport sizes. Observe actual `innerWidth`/`innerHeight`, breakpoint layout, and screenshot/input geometry, including tab zoom, insets, split layout, and constrained host presentation.
3. WebKit responsive profiles work; a device-axis profile fails before mutation. On Chromium, verify each advertised emulation axis using actual page/native measurements, orientation dimensions, and mobile viewport-meta behavior. No profile is advertised from an unexercised stub.
4. Inspect a non-interactive element's box model/flex/grid styles and DOM accessibility metadata. Replace/navigate the element and prove old observation/ref rejection. Secret field values, raw HTML, and inaccessible frame contents do not appear.
5. Start capture, trigger a known console error and HTTP 404/failed request via fixture actions, then read real records with declared coverage. Confirm no pre-start history, forbidden frame records, headers/bodies, URL secrets, or raw object dumps. Verify page promise rejection/XHR/console behavior remains intact under WebKit hooks.
6. Exercise pagination, eviction, truncation, stale/foreign cursors, reload/document transition, and late old-generation events. Unknown HTTP data and coverage gaps stay explicit rather than becoming fake successes.
7. Use two clients to prove ownership conflicts and buffer isolation. Reset/disconnect/revoke/profile/engine/tab teardown release capture and overrides. A subsequent manual zoom/layout/wrapper change is not overwritten by cleanup.
8. With capture disabled, no diagnostic subscriptions/hooks remain active. Verify bounded memory under sustained events and absence of diagnostic disk/history persistence.
9. Run every existing tool from the parity table against the same local fixture contract on WebKit and Chromium before testing the new development tools. Record app commit, actual engine/runtime, observed result, and failure reason; tool discovery, shared source code, or a capability flag alone is not a pass.
10. For `pressKey`, check actual focus, delivered keydown/up, and resulting DOM state, including focus loss and missing native responder. For `goBack`, check completed destination, same-document history, absent history, and a changed/foreign-origin back destination; no false “Sent”/“Went back” result after a rejected operation.
11. Open a CSS-only hover menu, wait for an asynchronously visible/enabled element and for removal, and capture a known element/region on each engine. Verify image bounds/content with zoom, scroll, insets and split panes; ambiguous selectors, stale observations, invalid/offscreen crops, sensitive fields, and navigation during capture must fail safely.
12. Prove that stage relay discovery and actions reach only the owned stage server while the normal app remains running and untouched. Changing engine with an unchanged URL rejects old refs/capabilities and late operation results.

Keep permanent tests for plausible consumer-visible permission, stale-reference, lifecycle, cursor, and bound violations. Use real stage smoke scenarios for native layout, engine axes, and coverage; source-text, copied-value, or mock-forwarding assertions are not substitutes. Update affected MCP documentation/schema examples with the implementation, without adding compatibility shims or a second convention.

Integration remains a PR to `main` after review and required CI. Stage verification does not authorize release deployment or installed-app replacement.

## References

- [Apple: WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld) — page versus isolated JavaScript namespaces.
- [Chromium DevTools Protocol: Emulation](https://chromedevtools.github.io/devtools-protocol/1-3/Emulation) — protocol operations, not proof of embedded-runtime support.
