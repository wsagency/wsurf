# Linen upstream migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate every behavior, feature and maintenance change in the pinned 31-commit Linen range into WSurf without losing deployed fork functionality or user data.

**Architecture:** Adapt the upstream implementations at WSurf's existing BrowserPage, persistence, settings, download and MCP boundaries. Introduce profile-owned contexts and an application window registry in one atomic multiwindow cutover, extending ownership to CEF rather than replacing it with WebKit. Keep a versioned full-SHA migration journal, with separate evidence for every part of mixed commits.

**Tech Stack:** Swift 6/Swift Testing, SwiftUI/AppKit, WebKit, CefSwift/CCef, GRDB, MCP Swift SDK, AnyLanguageModel, Vision/CoreML, Xcode 27.0 on native Pro.

**Spec:** `docs/superpowers/specs/2026-10-06-linen-upstream-migration-design.md` — read it alongside this plan. **Journal:** `docs/upstream-migrations.md` — authoritative 31-item manifest and atomic window file inventory.

## Global Constraints

- Every task, including documentation and configuration, uses a `feature/<short-name>` branch in the project-root `.worktrees/` directory; `/.worktrees/` stays gitignored. OMP automatically supplies the separate task worktree. Detect and reuse it; do not create a second worktree or switch the shared checkout.
- Develop on the Air; native app build and tests run through SSH alias `pro` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Verified toolchain: Xcode 27.0 (`27A266a`), Swift 6.4 (`swiftlang-6.4.0.34.1`). Do not alter global `xcode-select` or fake SwiftUI macros on the Air.
- Minimum runtime remains macOS 26, Apple silicon; this migration's native build toolchain floor is Xcode 27.0. Swift 6 isolation and concurrency checks remain enabled.
- Keep WSurf identity `io.wsagency.wsurf`, WSurf App Support/database/Keychain identifiers, `WSURF_*` environment variables, stage isolation, MCP socket/config namespaces, update feed, signing and release gates. Merge localization keys; never replace the WSurf catalog, project or package lockfile with Linen's file.
- Preserve CefSwift revision `59cad64e124b8efdb6b2ee811963097bb6e689e8`. Resolve AnyLanguageModel 0.15.1 (`c4a1acdbc8a2a9f967fada82208798b3a719a458`) and swift-collections 1.7.1 (`98ef3c98609a1e31b7e157b5b619579001a789d6`), retain other required packages, and regenerate WSurf acknowledgements.
- CI keeps coverage floor **24.0%**, existing performance budgets, watchdog and WSurf release protection. SwiftLint becomes **0.65.1**, archive SHA-256 `c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0`.
- Clean cutover: migrate all affected callers; remove obsolete singleton routing and dead code. Do not add legacy-global compatibility aliases, a second permission store or a second download pipeline.
- Each adapted behavior has a versioned journal entry linking full upstream SHA, task, adaptation, WSurf implementation commits, PR and actual verification. Planning entries must not claim implementation or deployment.
- Integrate only through reviewed PRs to `main` with required CI. Release/deployment uses the exact PR-merged, CI-passing main commit. Replacing `/Applications/WSurf.app` on the Air additionally requires explicit user deployment approval.

## Review Focus

1. **Private windows sharing the private Profile UUID:** cookies, grants, CEF context and delayed cleanup must remain isolated — T09 `privateCEFContextsSurviveOtherWindowClose`.
2. **Queued session writes and sidebar undo after live transfer:** no tab resurrection, stale-owner mutation or lost Favorites/pins — T09 `transferPreservesForkStateAndRejectsStaleUndo` and `retiredWindowRejectsQueuedWrites`.
3. **Iframe app handoff while top-level navigation is pending/redirecting:** remember the requesting origin only; ambiguity cannot create durable permission — T06 `cefExternalApprovalUsesSourceFrame`.
4. **Cancellation/navigation/grant revocation halfway through a form:** no writes to replacement document and no replay of verified refs — T11 `formFillStopsAtDocumentOrGrantBoundary`.
5. **Provider rate limit after a browser action and subsequent profile focus change:** action executes once, original context remains bound, no extra summary on pause — T09 `concurrentTurnsKeepProfileSettings` and T12 `rateLimitAfterActionDoesNotReplayOrSummarize`.

---

## Baseline, sequencing and task completion protocol

Research baseline is deployed **`4d33cb93ed22a92ffa2db0d5fc8109b5e4a78557`**, not the dirty shared checkout. At planning time remote main was `11ab647c184bb2f0a13b65e3a589b5a1baa29f2e`, one formatting-only commit later. T00 preserves that delta and checks for subsequent main changes. Source and artifact proof is in the spec; no new app build/test is claimed by these planning documents.

All 31 upstream commits are assumed thoroughly tested. Existing behavioral test imports below prove the **WSurf port**, not a new audit of upstream. Additional permanent tests are limited to uncertain fork boundaries. Do not retain wording/source-text/wiring/mock-echo assertions; delete them instead of re-pinning them. Temporary native/pipe/fixture probes are removed after evidence is recorded.

Execution order: T00 → T01 → T02–T08 → **T09 atomic cutover** → T10–T15 → T16 → T17. T02–T08 have independent behavior slices, but share the journal/catalog and some test fixtures; use one integration owner. T11 and T12 split the mixed form/retry commit; T02/T03/T04/T09/T13 jointly cover the entire mixed idle/startup commit. Never mark either mixed commit verified after only one slice passes. T09's internal order is sequential; it is not a collection of independently shippable scaffolds.

For **every implementation task**, adapt the named upstream behavior test or add the named fork regression before changing implementation; run that selected test to capture the expected missing/old behavior, apply the minimal port, then run its affected suites once. Exercise its actual WSurf path as specified, update relevant docs/changelog and journal evidence, and commit only that task's files. A test failure is a diagnosis input, never grounds to narrow assertions or suppress errors.

Commit trailers use full upstream SHA(s): `Upstream-Commit: <40-hex>` and `Migration-Task: Tnn`. After the code commit exists, update the journal with its real SHA in the next evidence commit; never invent a self-referential journal commit ID. PR/body links journal tasks; merge/deploy records name the actual main/build commit.

### Native check commands used by task steps

Create an owned Pro build snapshot, not a modification of `~/projects/wsurf`. In the execution feature worktree, assign these once:

```bash
TASK_ROOT="$(git rev-parse --show-toplevel)"
PRO_ROOT="$(ssh pro 'mktemp -d /tmp/wsurf-linen-XXXXXXXX')"
ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes pro \
  'hostname && xcode-select -p && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift --version'
ssh pro "mkdir -p '$PRO_ROOT/source'"
rsync -a --delete --exclude=.git --exclude=.worktrees --exclude=build --exclude=DerivedData --exclude=.build \
  "$TASK_ROOT/" "pro:$PRO_ROOT/source/"
```

Resync only this newly created owned snapshot after source changes; `--delete` removes obsolete source files there, never in Pro's established checkout or another task's directory. This temporary shell function is a documentation shortcut, not a new repository build framework:

```bash
native() {
  ssh pro "cd '$PRO_ROOT/source' && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild test \
    -project WSurf.xcodeproj -scheme WSurf -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath '$PRO_ROOT/DD' -disableAutomaticPackageResolution \
    -skipMacroValidation -skipPackagePluginValidation -parallel-testing-enabled NO \
    $* CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="
}
```

T01 first resolves packages with `xcodebuild -resolvePackageDependencies -project WSurf.xcodeproj -scheme WSurf -derivedDataPath "$PRO_ROOT/DD" -onlyUsePackageVersionsFromResolvedFile` on Pro from the snapshot. If creating the new lock requires resolution, perform that explicit update first and freeze the committed result before checks. Every task's `native -only-testing:...` command below expects its **named behavioral assertions** to pass and `** TEST SUCCEEDED **`; inspect xcresult/logs for actual discovered cases, not an empty selection. Use unique result bundles under the owned Pro root for evidence. No hosted OCR exclusions on Pro.

## T00 — Execution isolation, baseline delta and journal

**Files:** Modify `docs/upstream-migrations.md` and these plan/spec files only when recording actual preflight changes; preserve `AGENTS.md`, `CONTRIBUTING.md`, `.gitignore` workflow rules already added by the planning task.

**Interfaces:** Consumes the pinned deployed/upstream SHAs in the spec. Produces an OMP-owned `feature/linen-upstream-migration` worktree based on current `origin/main`, a checked baseline delta and an execution record keyed by T00. No application API changes.

- [ ] Detect OMP's worktree and feature branch; verify the project-root `.worktrees/` is ignored using `git check-ignore -v .worktrees/ignore-probe/`. Do not create another worktree or alter the dirty shared checkout.
- [ ] Fetch current main in the execution worktree and compare it to `4d33cb9`; retain known `11ab647` formatting. Record any further delta and adapt affected task/file decisions before code changes. Never reset current main back to deployed source.
- [ ] Pin the upstream clone/range to the full manifest; verify exactly 31 unique SHAs. Keep open draft upstream iCloud PR #2 out of scope because its commit is already inherited, not one of these 31.
- [ ] Create the owned Pro snapshot with the commands above; save toolchain and commit/range provenance in the execution record. Preserve existing Pro source/DerivedData.
- [ ] Commit the execution record; do not label any planned item applied or deployed.

## T01 — Xcode/dependencies, OCR and upstream fixture maintenance

**Upstream:** `53fbb4c`, `853ce9b`, `231d2ec`, `4367b14`, `f0eba22`, `a05a577`, `9b59c83`, `ce63cda`.

**Files:**
- Modify `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/workflows/tip.yml`, `WSurf.xcodeproj/project.pbxproj`, `WSurf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, `CONTRIBUTING.md`, `WSurf/Support/Acknowledgements.json`.
- Modify `WSurf/Agent/AgentContextCompactor.swift`, `WSurf/Agent/AnyLanguageModelAgent.swift`, `WSurf/Agent/Providers/OpenAI/OpenAIMCP.swift`, `WSurf/Agent/Providers/OpenAI/OpenAIUtilityModel.swift`, `WSurf/Agent/Attachments/AttachmentImporter.swift`.
- Create `WSurfTests/Helpers/InteractiveWebViewConfiguration.swift`; modify `WSurfTests/Helpers/ComputerWorkflowFixture.swift` and `WSurfTests/Web/{PageActivityMonitorTests,PageComputerInputTests,PageDriverTests,PageInteractionTests,PageSettleTests,ContactAutofillScriptTests,PasswordAutofillScriptTests,PaymentCardScriptTests}.swift`.
- Modify `WSurfTests/Agent/{AgentContextBoundaryTests,AgentContextCompactionTests,OpenAICompatibilityTests,AttachmentTests}.swift`, `WSurfTests/Web/BrowserPerformanceTests.swift`, `WSurfTests/Extensions/ExtensionPageAssetsTests.swift`.

**Interfaces:** `interactiveWebViewConfiguration() -> WKWebViewConfiguration` sets inactive scheduling `.none`, without changing production configuration. `AttachmentImporter.recognize(_: CGImage, availableComputeDevices: [MLComputeDevice] = MLComputeDevice.allComputeDevices) throws -> String`. Preserve `AgentContextCompactor.isContextWindowError(_ error: any Error) -> Bool` as the single classifier used by the runner.

- [ ] Adapt upstream context-overflow tests for session/OpenAI/Responses overflow; assert one preceding browser action and recovered checkpoint, but zero compactions for `server_error`/`insufficient_quota`. Structured utility results round-trip `Café`, `東京`, quotes and empty arrays. Native OCR CPU fallback must read `INVOICE` and `42` with `availableComputeDevices: []`.
- [ ] Update package minimum/pins to spec values without dropping CefSwift or overwriting WSurf project/lock origin hash. Use `GeneratedContent(json: Data)` and central classification for `context_length_exceeded`; regenerate acknowledgements via `Tools/make-acknowledgements.swift` against the resolved Pro packages and copy only that generated WSurf file back.
- [ ] Port active fixtures, stable explicit fixture titles and HTTP-server lifetime, extension collector ownership (`message.webView === expected` and expected reply prefixes), and metadata-only ranking with nonmaterialized tabs. Preserve `.boundedWebViews`/exclusive traits and WSurf script message names.
- [ ] Port CoreML CPU selection only when Neural Engine absent. Configure **only hosted CI** to skip the four `AttachmentTests` OCR integrations listed in the journal. Keep them in the native test plan and Pro run.
- [ ] Keep `macos-26` runner and preflight `/Applications/Xcode_27.0.app`; fail clearly if unavailable instead of copying the unverified `xcode-27` label. Upgrade pinned actions: checkout `3d3c42e5aac5ba805825da76410c181273ba90b1`, cache `55cc8345863c7cc4c66a329aec7e433d2d1c52a9`, upload `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`. Verify SwiftLint version/SHA, lock-only resolution and disabled implicit test resolution. Retain CI's Metal install and port missing release/tip steps. Execution corrected the original all-three equivalence claim; attribute the real `853ce9b` adoption rather than claiming blanket equivalence.
- [ ] Run `native -only-testing:WSurfTests/AgentContextCompactionTests -only-testing:WSurfTests/OpenAICompatibilityTests -only-testing:WSurfTests/AttachmentTests -only-testing:WSurfTests/AgentContextBoundaryTests -only-testing:WSurfTests/ExtensionPageAssetsTests -only-testing:WSurfTests/BrowserPerformanceTests` plus the seven changed WebKit fixture suites. Smoke import a generated invoice image/scanned PDF through the real attachment path on Pro; retain extracted-text evidence. Commit code and subsequent journal evidence.

## T02 — Codex discovery, initialize compatibility and event-driven MCP stdio

**Upstream:** `791a548`, `3578dc2`, `3997153` (stdio slice).

**Files:** Modify `WSurf/MCP/{MCPClientConfiguration,LocalMCPTransport,MCPStdioRelay,LocalMCPEndpoint}.swift`; create `WSurf/MCP/MCPInitializationCompatibility.swift`, `WSurf/MCP/MCPStdioTransport.swift`, `WSurfTests/Agent/MCPStdioTransportTests.swift`; modify `WSurfTests/Agent/{MCPClientInstallerTests,MCPTransportTests}.swift`.

**Interfaces:** `MCPInitializationCompatibility.normalize(_ message: Data) -> Data`; actor `MCPStdioTransport: Transport`, `init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO)`, `connect() throws`, `disconnect()`, `send(_ data: Data) async throws`, `receive() -> AsyncThrowingStream<Data, any Error>`. Keep existing framer/SDK 0.12.1 contract and WSurf endpoint identity.

- [ ] Port both bundled Codex executable path cases (nested `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex` and legacy path), with executable checks and existing TOML preservation; fixture initialization uses `2025-06-18`, elicitation objects and client title.
- [ ] Port normalization tests: only object-valued `initialize.params.capabilities.experimental` removed; roots/elicitation and other fields preserved; malformed/non-initialize/array/absent inputs unchanged. Normalize at local transport and relay inbound SDK boundaries, including the new stdio path; do not change grants or tool validation.
- [ ] Port DispatchIO transport using duplicated owned descriptors, existing framing, 64-entry bounded streams, overflow error, newline output and terminal EOF/disconnect. Remove idle 10 ms polling; avoid duplicate normalizations or retries.
- [ ] Run `native -only-testing:WSurfTests/MCPClientInstallerTests -only-testing:WSurfTests/MCPTransportTests -only-testing:WSurfTests/MCPStdioTransportTests -only-testing:WSurfTests/MCPPrivacyTests`. Exercise WSurf's real stdio entrypoint with split/coalesced initialize frames, tools/list, idle input then EOF; observe correct replies and process exit without exposing production socket or replaying tool calls. Record all three SHA attributions.

## T03 — Autofill layout settling, trusted key acknowledgements and safe diagnostics

**Upstream:** `4ea5d35`, `2fe08fe`, `3997153` (autofill slice).

**Files:** Modify `WSurf/Web/Autofill/{AutofillSuggestionScript,AutofillSaveCoordinator,PasswordAutofill,AutofillDiagnostics}.swift`, `WSurf/Web/Autofill/README.md`, `WSurf/Web/Page/PageComputerInput.swift`, `WSurfTests/Web/{PasswordAutofillScriptTests,PageComputerInputTests}.swift`; create `WSurfTests/Web/AutofillFramePolicyTests.swift`.

**Interfaces:** Existing AutofillSuggestionScript and PageDriver computer-action signatures unchanged. Add `AutofillDiagnostics.PolicyOperation` cases `password`/`save` and `policyFailed(_ operation: PolicyOperation, error: any Error, isMainFrame: Bool)` with DEBUG-only classification, never raw exception/URL logging.

- [ ] Port moving/hidden username-to-password layout tests: exactly one settled suggestion with correct rectangle; blur/typing/disabled/dismissed/expired focus produces none. Keep the upstream 50 ms / 100 ms / <1 px / 1 s values and cancellation listeners; mutations alone must not start interactions.
- [ ] Port `keypressAcknowledgesKeyDownWhenPageConsumesKeyUp`: BACKSPACE changes `abc` to `ab` once despite consumed keyup. Trust only native trusted keydown; unsupported/system chords produce no events, delivery acknowledgement does not imply page completion.
- [ ] Port sandbox frame policy tests for main/same-origin/allow-scripts/allow-same-origin/fully sandboxed frames. Catch policy delivery errors using bounded DEBUG domain/code/allowlisted exception-class/main-frame diagnostics; never relax frame policy to pass tests.
- [ ] Run `native -only-testing:WSurfTests/PasswordAutofillScriptTests -only-testing:WSurfTests/PageComputerInputTests -only-testing:WSurfTests/AutofillFramePolicyTests`. Smoke first focus on animated fixture and trusted native Backspace in staged WebKit and CEF supported input paths. Autofill remains a WebKit capability; no invented CEF credential mechanism. Commit and record diagnostics privacy check.

## T04 — Media idle work, lyrics lifetime and engine-neutral geometry

**Upstream:** `b3bc2ef`, `3997153` (lyrics/geometry slices).

**Files:** Modify `WSurf/Media/MediaScript.swift`, `WSurf/Media/Lyrics/LyricsModel.swift`, `WSurf/Media/MediaControls.swift`, `WSurf/UI/Shell/WebViewRepresentable.swift`, `WSurfTests/Features/{LyricsModelTests,MediaScriptTests}.swift`; create `WSurfTests/UI/WebViewGeometryTests.swift`.

**Interfaces:** Retain WSurf `__wsurfSend` media bridge and BrowserPage wrapper. Port `LyricsModel.init(source: any LyricsSource = LRCLIB(), defaults: UserDefaults = .standard, clock: any Clock<Duration> = ContinuousClock())` and ticker reevaluation on phase/on-screen/sync changes; no new timer service.

- [ ] Adapt upstream idle/hidden/paused/dynamic/BFCache scan tests to WSurf's **already event-driven** script. Assert zero repeated DOM selector scans while idle/hidden; visible-playing scans and timeupdate reports remain correct. Do not reintroduce unconditional 500 ms scans merely to mirror upstream text.
- [ ] Port deterministic clock assertions: ticker runs only for visible + playing + synced; pause/hide/error cancels it and model release cancels pending work. Preserve private lookup prohibition and enabled preference.
- [ ] Port finite dimension tests to both surfaces: unspecified/nonfinite proposal is rejected; `-3` becomes `0`, zero stays zero and finite positive values are retained. Preserve BrowserPage native view/crop ownership on both engines.
- [ ] Run `native -only-testing:WSurfTests/MediaScriptTests -only-testing:WSurfTests/LyricsModelTests -only-testing:WSurfTests/WebViewGeometryTests`. Smoke fixture play/pause/hide/back-forward and staged lyrics display, observing the media messages and ticker/idle work. Commit all slices with journal evidence.

## T05 — Real document titles and PDF-viewer saves

**Upstream:** `2c3eee5`, `3007d94`.

**Files:** Modify `WSurf/Web/Tabs/{BrowserTab,BrowserTab+WebKitDelegates,BrowserTab+PageLifecycle,FolderNamer}.swift`, `WSurf/Web/Model/{BrowserModel,BrowserModel+Sessions}.swift`, `WSurf/Web/System/{SystemPages,DownloadManager}.swift`, `WSurf/UI/Chrome/ToolbarHoldMenu.swift`, `WSurf/Localizable.xcstrings`, `WSurf/Web/Engines/{BrowserPage,ChromiumPage,ChromiumClient}.swift`; modify `WSurfTests/UI/NewTabChromeTests.swift`, `WSurfTests/Web/{BrowserPagesTests,SessionRestoreTests,ProfileHandoffTests}.swift`; create `WSurfTests/Web/BrowserDocumentTitleTests.swift`, `WSurfTests/Web/PDFDownloadTests.swift`.

**Interfaces:** `BrowserTab.noteMainFrameResponse(_ response: URLResponse)` and `documentFilename(for url: URL?) -> String?`; new BrowserPage `onMainFrameResponse: ((URLResponse) -> Void)?`; `BrowserTab.onSaveDocument: ((Data, String, URL?, Bool) async -> Void)?`; `DownloadManager.save(_ data: Data, suggestedFilename: String, source: URL?, sourceTabID: UUID? = nil, privately: Bool = false, on window: NSWindow? = nil) async -> URL?` uses the existing destination hook.

- [ ] Port title behavior assertions: Start Page only for blank/start; direct untitled URL uses New Page; response PDF names cover escaped URL, Content-Disposition, local file, fragment revisit and restore; custom title always wins. Exclude both placeholder labels from folder naming.
- [ ] Forward WebKit main-frame response and implement CEF `cef_resource_request_handler_t.on_resource_response`: copy URL/status/MIME/headers while CEF values are valid, build an HTTP URLResponse, deliver on MainActor only for the current live main-frame document, and reject stale responses. Keep callback ownership/threading and no header/body logging. Use actual response suggested filename, not URL-extension guessing.
- [ ] Port manager tests for edited byte equality, disk/in-flight filename collision, cancelled location selection, write failure, quarantine and private-history absence. Share network destination reservations/selection; preserve existing WKDownload handoff dedupe, but do not dedupe distinct explicit saves.
- [ ] Connect WebKit PDF private save/Preview selectors to the async callback, detach clears it; save current viewer bytes before opening final user-owned file. Retain CEF native download path; no unsupported promise of Apple's selectors or edited-byte extraction on Chromium.
- [ ] Run `native -only-testing:WSurfTests/BrowserDocumentTitleTests -only-testing:WSurfTests/PDFDownloadTests -only-testing:WSurfTests/SessionRestoreTests -only-testing:WSurfTests/ProfileHandoffTests -only-testing:WSurfTests/NewTabChromeTests`. Smoke real local fixture PDFs in both engines, WebKit edited viewer Save/Preview and downloads page filename/private history, without modifying production downloads. Commit and journal.

## T06 — Source-origin external app approvals, revocation and real navigation fixtures

**Upstream:** `b06f891`, `c1e874d`.

**Files:** Create `WSurf/Web/Privacy/ExternalAppPermission.swift`, `WSurfTests/Web/ExternalAppPermissionTests.swift`; modify `WSurf/Web/Privacy/SitePermissions.swift`, `WSurf/Web/System/ExternalApp.swift`, `WSurf/Web/Tabs/{BrowserTab,BrowserTab+WebKitDelegates,BrowserTab+PageLifecycle}.swift`, `WSurf/Settings/Pages/WebsiteSettings.swift`, `WSurf/Settings/SiteSettingsIndex.swift`, `WSurf/Localizable.xcstrings`, `WSurf/Web/Engines/{ChromiumClient,ChromiumPage}.swift`, `WSurfTests/Web/{AppHandoffTests,NavigationPolicyTests}.swift`, `WSurfTests/Settings/SiteSettingsIndexTests.swift`.

**Interfaces:** Port `ExternalAppPermission` (scheme/bundleIdentifier/name), `TabExternalAppPolicy(store: SitePermissions, isPrivate: Bool)`, `allows(_ app: ExternalAppPermission, from origin: String) -> Bool`, `remember(_ app: ExternalAppPermission, from origin: String)`. Keep persistence inside SitePermissions; the policy owns private session grants. Existing handoff/prompt gains explicit source-origin context.

- [ ] Port acceptance/cancellation/allow-once/remember/revoke/reset/legacy-store tests. Assert exact scheme/port/subdomain/app bundle separation, no disk write on cancel/private grant, and no persistent remember control for unknown/non-HTTP origin or unavailable app.
- [ ] Replace synthetic external navigation fixtures with a real loaded source page/link; retain server lifetime and assert requested destination **and source origin**, no navigation/back entry. Preserve exclusive test observers.
- [ ] Port WebKit source-frame/redirect handling. In CEF `on_before_browse`, capture source-frame URL/redirect provenance **before** the app-scheme guard; route app-scheme attempts into shared handoff policy, then cancel browser navigation. Ambiguous redirect provenance supplies no origin. Do not use app destination or current top-level URL as approval authority.
- [ ] Add `cefExternalApprovalUsesSourceFrame`: iframe source A under top-level B and a pending/redirecting top-level C never grants B/C; cancellation grants nothing and ambiguous cases ask again. Test actual supported CEF callbacks; retain inert app-launch interception only to prevent external side effects.
- [ ] Run `native -only-testing:WSurfTests/ExternalAppPermissionTests -only-testing:WSurfTests/AppHandoffTests -only-testing:WSurfTests/NavigationPolicyTests -only-testing:WSurfTests/SiteSettingsIndexTests`. Smoke prompt/remember/revoke on owned stage fixture; cancel actual external launch unless separately authorized. Commit and journal.

## T07 — Late scroll-reset restoration without fighting user input

**Upstream:** `90e222b`.

**Files:** Modify `WSurf/Web/Tabs/BrowserTab+PageControls.swift` and `WSurfTests/Web/BackForwardScrollTests.swift`.

**Interfaces:** Preserve `BrowserTab.restoreScrollScript(to y: Double) -> String`, shared BrowserPage evaluation and existing reported-scroll state.

- [ ] Port `restorationSurvivesALateNativeReset(alreadyRestored:)`: requested 1500 survives an explicit post-restoration reset to zero. Port `restorationRespectsSubsequentInput(event:)` for wheel/keydown/pointerdown/touchstart/pagehide and page-selected nonzero 700; after bounded completion expect user/page position, not 1500.
- [ ] Apply upstream 20-attempt/60 ms bounded watcher; continue after reaching target to catch late zero; stop on user input/pagehide/different nonzero position and remove listeners/timer. Retain document identity and existing same-document behavior.
- [ ] Run `native -only-testing:WSurfTests/BackForwardScrollTests -only-testing:WSurfTests/SameDocumentBackTests -only-testing:WSurfTests/SessionRestoreTests`. Smoke same/cross-host back-forward on a tall fixture in WebKit and CEF, with intervening user scroll. Record post-watcher position rather than a transient match; commit and journal.

## T08 — Palette editing keys, Downloads navigation and sidebar contrast

**Upstream:** `fe1d5dc`, `3fdb775`, `498d232`, `c616faf`, `b1d7611`.

**Files:** Modify `WSurf/UI/CommandPalette/{CommandPalette,CommandPaletteModel}.swift`, `WSurf/Settings/Pages/{DownloadsSettings,AdvancedSettings}.swift`, `WSurf/Settings/SettingsSearchIndex.swift`, `WSurf/UI/Sidebar/{TabPreview,SidebarDrag}.swift`, `WSurf/Localizable.xcstrings`, `WSurfTests/UI/CommandPaletteModelTests.swift`; create `WSurfTests/UI/CommandPaletteShortcutTests.swift`; adapt existing `WSurfTests/Settings/{SettingsSearchTests,SettingsNavigatorTests}.swift` only for changed navigation contracts.

**Interfaces:** `CommandPaletteShortcutPolicy.shouldDismiss(_ event: NSEvent) -> Bool` and `shouldDismiss(modifiers: NSEvent.ModifierFlags, key: String, commandKey: String? = nil) -> Bool`. Use existing `browser.showDownloads()`; no new settings navigation service.

- [ ] Port layout-translated Cmd-V, Cmd-Shift-Z, Cmd-Option-Shift-V and unrelated Cmd-L behavior; capsLock/numericPad/function flags do not alter decision. Exercise actual `MainMenu` paste key equivalent, not just strings.
- [ ] Replace settings recent-list/Clear block with Open downloads route/search copy. Retain clear/open/reveal/cancel functionality in actual Downloads content. Use existing navigator test to assert Downloads and Back return to settings; never add a source-copy assertion.
- [ ] Synchronize **Advanced global reset** copy `are not affected` with its catalog key; do not change Appearance/theme reset wording. Gray folder preview uses secondary tint, other colors retain tint; drop mark no longer forces website color scheme. Preserve WSurf favorites/pin spacing and fonts.
- [ ] Run `native -only-testing:WSurfTests/CommandPaletteModelTests -only-testing:WSurfTests/CommandPaletteShortcutTests -only-testing:WSurfTests/SettingsNavigatorTests -only-testing:WSurfTests/SettingsSearchTests`. Smoke keys/menu paste and light/dark sidebar drop markers and gray previews on actual stage surfaces. Visual/copy changes need no wording tests; record screenshots and commit.

## T09 — Atomic profile-aware multiwindow cutover, including WSurf CEF and sidebar state

**Upstream:** `cd15751`; `3997153` resource-lifetime slice.

**Files:** The journal's **T09 exact mapped inventory** lists all 125 upstream paths as Create/Modify against deployed WSurf, including caller/test/docs updates. That inventory is part of this task, not an optional appendix. Also modify fork-only `WSurf/Web/Engines/{BrowserPage,ChromiumPage,ChromiumClient,ChromiumRuntime,ChromiumRuntime+Data,ChromiumPage+Settings}.swift`, `WSurf/Web/Tabs/BrowserTab+PageLifecycle.swift`, `WSurf/Web/Model/BrowserModel+SidebarUndo.swift` and its indexed callers; modify `WSurfTests/Web/{SidebarUndoTests,SidebarFavoritesTests,SessionWriterTests,SessionRestoreTests}.swift`; create `WSurfTests/Web/BrowserResourceLifetimeTests.swift`.

**Interfaces:**
- `BrowserApplication`: `windows: [AppCoordinator]`, `activeWindowID: UUID?`; `newWindow(profile: Profile? = nil, settingsOwner: Profile? = nil, windowID: UUID = UUID(), restoring: Bool = false, show: Bool = true, urls: [URL] = []) -> AppCoordinator`; `bootstrap() async`, `focus(_:)`, `didClose(_:)`, `coordinator(for page: BrowserPage) -> AppCoordinator?`.
- `BrowserProfileContext.shared(for profile: Profile, settingsOwner: Profile? = nil) -> BrowserProfileContext`; `existing(for profileID: UUID) -> BrowserProfileContext?`, `forget(_ profileID: UUID)`, `endPrivateSession() async`. Add `let contextID: UUID` unique per context for CEF ownership; persistent contexts are cached by profile ID, private ones never cached/shared. Its stores/pool/settings retain upstream names from the spec.
- `AppCoordinator.init(browser: BrowserModel, profiles: ProfileStore)`; context-backed services and windowID, application/nativeWindow/isClosed/isKeyWindow. `ProfileStore.selection(profile: Profile, catalog: ProfileStore = .shared) -> ProfileStore` keeps only selection per window.
- `BrowserModel.init(context: BrowserProfileContext? = nil, windowID: UUID = BrowserModel.legacyWindowID, database: AppDatabase? = nil, history: HistoryStore? = nil, sitePermissions: SitePermissions? = nil, downloads: DownloadManager? = nil, webViewFactory: (@MainActor () -> WKWebView)? = nil)`. Retain the existing WebKit test factory hook; production page creation wraps WebKit/CEF in BrowserPage with explicit context. `adoptTab(_ tab: BrowserTab, from source: BrowserModel) -> Bool`, transfer hooks and window-scoped snapshots.
- `BrowserPage.init(webKit: WKWebView, context: BrowserProfileContext)` and `ChromiumPage.init(context: BrowserProfileContext)` replace optional/global profile inference; `BrowserPage.init(chromium: ChromiumPage)` inherits that explicit context. `ChromiumRuntime.withContext<T>(for context: BrowserProfileContext, _ body: (UnsafeMutablePointer<cef_request_context_t>) throws -> T) throws -> T`, `releaseContext(contextID: UUID) async` and `command(context: BrowserProfileContext, method: String, params: [String: Any] = [:]) async throws -> [String: Any]` replace profile-ID-only ownership/teardown. Data helpers consume the same context and retain existing operation semantics.
- `LLMSettings.init(defaults: UserDefaults)` and `LLMSettings.$scoped.withValue` bind profile settings through async turns; `ProfileProviderCatalog(settings: LLMSettings)` retains global provider definitions. Update all callers to explicit instance/current task-local settings; do not retain old global accessor aliases.

- [ ] Obtain Pro indexed references for coordinator/bootstrap, BrowserModel construction/session writes, ProfileStore selection, WebViewPool, LLMSettings, Chromium context/data helpers, MCP/extension owner resolution and sidebar undo. Audit the entire 125-path inventory plus fork paths before editing; empty Air references are not an exhaustive call graph.
- [ ] Adapt upstream context/session/window/MCP/extension tests **before cutover**. Add fork tests `privateCEFContextsSurviveOtherWindowClose` (distinct cookie/context identities; closing A leaves B alive), `transferPreservesForkStateAndRejectsStaleUndo` (same tab/page/view and POST count; Favorites/pin/split/hierarchy retained; old undo cannot touch destination), and `concurrentTurnsKeepProfileSettings` (distinct selected model/tool grants before and after focus/switch). Use existing native engine fixtures and temporary databases.
- [ ] Create context ownership and explicit page constructors first. Move WebKit pool/dataStore/content rules/settings to context. Key CEF ephemeral contexts/origin bookkeeping/teardown by contextID; regular windows share actual profile context/cache path. Remove global profile swapping/fallback construction; private cleanup waits only its pages' close acknowledgements.
- [ ] Replace per-BrowserModel assignment/clearing of the shared `SitePermissions.onEngineChanged` callback with one context-owned callback that routes through registered application windows sharing that context. Preserve `applyStoredEngine(to:)` on each live model; switching/closing one owner cannot clear another's subscription. Add `sameProfileEnginePreferenceReachesAllWindows`: change one origin preference, observe both same-profile owners update, while another profile/private context does not.
- [ ] Port GRDB window tables/indexes/composite item key and revision/retirement guards. Adapt legacy migration from an untouched deployed-schema fixture retaining isFavorite/isPinned and all state/history/download/log tables. `retiredWindowRejectsQueuedWrites` covers late close/remap snapshots and occupied remap destination; transaction rollback leaves original data intact.
- [ ] Port BrowserApplication registry/bootstrap/external URL queue/reopen/terminate and AppCoordinator per-window lifecycle; make menus/views/update presentation/onboarding route through an explicit owning coordinator. Port profile-specific selection/settings and all async helper scopes; provider definitions and update configuration remain app-wide. Remove obsolete single-coordinator paths.
- [ ] Port per-window extension adapters and app-scope MCP binding/consent. Closing/switching unregisters only its adapters/connections; focus never retargets existing client, private focus denies new client without disrupting another regular owner. Callback completion verifies current registration. Preserve WSurf remote tools, Apple paths and WebKit-only extension/PiP restrictions.
- [ ] Port transfer last: require identical context/writer and open registered owners, cancel source assistant/voice/peek/media, reparent **the same live native view**, rebind WSurf history/navigation/download/new-tab hooks, invalidate stale-owner undo entries and atomically save both window snapshots after cancelling both debounces. Reject cross-profile/private/different-writer/closed-owner races; never close or reload moved page.
- [ ] Adapt all upstream window/session/profile/extension/MCP tests from the inventory, plus BrowserResourceLifetimeTests for page release and CEF OnBeforeClose acknowledgement. Run `native -only-testing:WSurfTests/WindowSessionTests -only-testing:WSurfTests/BrowserProfileContextTests -only-testing:WSurfTests/MultiWindowTests -only-testing:WSurfTests/LinkWindowTests -only-testing:WSurfTests/WindowMenuTests -only-testing:WSurfTests/MCPWindowScopeTests -only-testing:WSurfTests/ExtensionWindowTests -only-testing:WSurfTests/ProfileWindowSelectionTests -only-testing:WSurfTests/ProfileSwitchTests -only-testing:WSurfTests/SidebarUndoTests -only-testing:WSurfTests/SidebarFavoritesTests -only-testing:WSurfTests/BrowserResourceLifetimeTests` and remaining changed inventory suites. No partial hybrid commit passes this gate.
- [ ] Smoke owned stage: two regular windows same profile, second profile, two private windows; WebKit+CEF pages; switch only one owner; live same-context transfer; denied cross-context transfer; late close/undo; external link routing; bound MCP revocation; extension popup; private close; quit/relaunch window sessions/Favorites/pins/splits. Observe actual state and screenshot evidence. Update architecture/README/MCP/catalog with final ownership, then commit this coherent cutover and journal evidence.

## T10 — Questions remain at their initiating assistant surface

**Upstream:** `25bffb9`.

**Files:** Modify `WSurf/App/AppCoordinator.swift`, `WSurf/UI/Ask/{AskSurfaceModel,AgentInspector,AssistantComposer}.swift`, `WSurfTests/UI/AskSurfaceModelTests.swift` and `WSurfTests/Agent/AgentQuestionTests.swift` for real question transitions.

**Interfaces:** `AppCoordinator.pendingAgentQuestion(inChrome: Bool) -> AgentQuestionModel.Ask?` reads active space and returns only a question whose reply placement matches the requested surface.

- [ ] Port `questionsAppearOnlyWhereTheRequestStarted(placement:showsInChrome:)` and `questionsFromAnotherSpaceStayHidden(showsInChrome:)`; assert answering clears the originating request and both surfaces, but never exposes another space/window's question.
- [ ] Route chrome model to `true`, inspector/composer to `false`; resolve coordinator from T09 ownership rather than global focus.
- [ ] Run `native -only-testing:WSurfTests/AskSurfaceModelTests -only-testing:WSurfTests/AgentQuestionTests`. Smoke two-window chrome/inspector requests, change space/focus and answer only origin. Commit and journal.

## T11 — Bounded, control-aware form filling shared by assistant and MCP

**Upstream:** `db85459` (form slice).

**Files:** Create `WSurf/Web/Page/PageFormFilling.swift`; modify `WSurf/Web/Page/{PageDriver,PageInteraction,PageRuntime}.swift`, `WSurf/Agent/{AgentTools,AgentToolDescriptions,AgentToolCatalog,AgentExecutionPolicy}.swift`, `WSurf/MCP/MCPToolCatalog.swift`, `MCP.md`, `WSurfTests/Web/{PageDriverTests,PageInteractionTests}.swift` and relevant existing tool contract tests only where consumer behavior changes.

**Interfaces:** Move, do not duplicate, `PageDriver.FieldValue: Codable, Equatable, Sendable` (`ref: Int`, `value: String`, `select: Bool`) and `static func fillFields(_ fields: [FieldValue], in webView: BrowserPage, announced: Bool = false) async -> String`. Preserve engine-neutral WebKit/CEF evaluation and observation guard.

- [ ] Port mixed 10-of-14 verification/eligibility/radio tests, >32 and duplicate/nonpositive refs rejected **before writes**, checkbox/radio bools, select options, date/color/range validations, no submit/picker and exact verified refs. Sensitive/unavailable/file failures do not prevent later safe fields; chooseFilesOnPage still requires user file selection.
- [ ] Add `formFillStopsAtDocumentOrGrantBoundary` on each engine: trigger navigation, cancellation or approval revocation after first field; first old-document write occurs once, no new-document write and no continuation replay of verified refs.
- [ ] Move implementation to PageFormFilling; implement the upstream eligibility/per-control operation/retained-state checks with limit 32, same frame/document guard at every await and accurate per-field failures/snapshot. Preserve select boolean schema, stable exact refs and no alternate-tool retry.
- [ ] Update assistant descriptions/instructions/catalog and MCP max/description contract together, without copy-string assertions. Run `native -only-testing:WSurfTests/PageDriverTests -only-testing:WSurfTests/PageInteractionTests -only-testing:WSurfTests/MCPPrivacyTests -only-testing:WSurfTests/MCPTransportTests`. Exercise real assistant and MCP batch on a local owned mixed-control fixture in both engines; inspect values/events/no submission. Commit and journal.

## T12 — Rate-limit pause/recovery and visual no-progress without replay

**Upstream:** `db85459` (retry/progress slices).

**Files:** Modify `WSurf/Agent/{AgentEvaluationEvent,AgentProgressMonitor,AgentProviderRetry,AgentRunner,AnyLanguageModelAgent,AnyLanguageModelAgent+Run}.swift`, `WSurf/Agent/Providers/OpenAI/OpenAITransport.swift`, `WSurf/Localizable.xcstrings`, `WSurfTests/Agent/{AgentProgressMonitorTests,AgentProviderRetryTests,OpenAIResponsesTests}.swift`.

**Interfaces:** Port `OpenAIFailure.isRateLimited`, `.rateLimited` runner stop reason and `rate_limited` diagnostics; preserve existing retry delay interface/5xx handling and checkpoint/Continue flow. Consumes T09 task-local owner and T11 no-replay result semantics.

- [ ] Port streamed 429/rate_limit_exceeded classification and quota/billing exclusions; assert bounded 2 s/4 s retry, request maximum, no retries with remote actions enabled, and one browser action across retries. `rateLimitAfterActionDoesNotReplayOrSummarize` asserts exhausted run pauses with saved progress, no extra summary request, one prior action and original owner/context despite focus changes.
- [ ] Port no-progress fingerprint test: coordinate changes and click/doubleClick/typeAtPointer/drag variations on unchanged page with image cannot reset progress; changed page/failure distinction still matters. No screenshot hashing/extra allocations merely to compare incidental outputs.
- [ ] Apply upstream retry/classification/progress/pause copy and skip summary for rateLimited/providerError. Preserve existing security prohibition on replay after uncertain browser mutations; context-overflow recovery from T01 remains distinct.
- [ ] Run `native -only-testing:WSurfTests/AgentProviderRetryTests -only-testing:WSurfTests/AgentProgressMonitorTests -only-testing:WSurfTests/OpenAIResponsesTests -only-testing:WSurfTests/AgentContextCompactionTests`. Run a throwaway provider fixture through the real runner: one browser action then two rate-limit retries/pause/Continue, inspect request/action counts and trace. No real provider account action is needed. Commit all db85459 slices as verified only after T11 and T12 evidence exists.

## T13 — Synchronous speech preparation and URL-correct favicons

**Upstream:** `3997153` (speech/favicon slices; other slices T02/T03/T04/T09).

**Files:** Modify `WSurf/Voice/AppleSpeechOutput.swift`, `WSurf/App/AppDelegate.swift`, `WSurf/Web/Page/FaviconLoader.swift`, `WSurf/Web/Model/BrowserModel+Sessions.swift`, `WSurf/UI/Sidebar/SidebarTabRow.swift`, `WSurfTests/Web/FaviconLoaderTests.swift`; create `WSurfTests/Features/AppleSpeechVoiceCatalogTests.swift`.

**Interfaces:** `AppleSpeechVoiceCatalog.init(loadVoices: @escaping () -> [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices)`, `prepare()`, cached `voice`; `FaviconLoader.load(forPageURL pageURL: URL) async -> NSImage?` retains existing cache/coalescing.

- [ ] Port unprepared/empty/repeated catalog tests and premium→enhanced→first English selection. Call prepare synchronously in applicationDidFinishLaunching **before** test early return/async bootstrap; speech tasks read cache. Preserve WSurf muted default and current voice conversation behavior.
- [ ] Port full-URL favicon fixtures for localhost/IPv4/IPv6, HTTP/HTTPS and nondefault ports; fallback strips credentials/query/fragment but retains scheme/authority/port. Host-only calls must not guess HTTPS for local/IP. Update restored/pinned callers to actual page URL; preserve fork cache fix and private persistence policy.
- [ ] Run `native -only-testing:WSurfTests/AppleSpeechVoiceCatalogTests -only-testing:WSurfTests/FaviconLoaderTests -only-testing:WSurfTests/ReadAloudDefaultTests -only-testing:WSurfTests/LyricsModelTests -only-testing:WSurfTests/BrowserResourceLifetimeTests`. Smoke cold stage launch and restored/pinned icon from local HTTP port fixture, verifying no wrong-scheme request. Mark 3997153 verified only after every mapped task and all 20 changed upstream paths are accounted for.

## T14 — Tab-to-search site chips and stable native text/glass integration

**Upstream:** `56880f2`.

**Files:** Create `WSurf/Web/Search/SiteSearch.swift`, `WSurf/UI/CommandPalette/{SiteSearchAppearance,CommandPaletteGlass}.swift`, `WSurfTests/UI/CommandPaletteSiteSearchTests.swift`; modify `WSurf/UI/CommandPalette/{CommandPalette,CommandPaletteModel,CommandPaletteComponents}.swift`, **`WSurf/UI/Ask/MentionField.swift`**, `WSurf/Localizable.xcstrings`, `WSurfTests/UI/MentionFieldTests.swift`.

**Interfaces:** `SiteSearch.catalog: [SearchEngine]` and `SiteSearch.match(_ query: String, customEngine: SearchEngine? = nil) -> SearchEngine?` use existing SearchEngine URL methods; `CommandPaletteModel.suggestedSite`, `activateSiteSearch() -> Bool`, `removeSearchSite() -> Bool`, `searchSite` and site placeholder. MentionField gains upstream Tab/Delete handling callbacks without bypassing NSTextView marked-text/focus handling.

- [ ] Port all upstream matching/activation/removal/mention/IME/focus cases: valid custom engine first, built-in/named aliases >=2 chars, reject paths/query syntax/deceptive subdomains; no Tab capture when Shift/marked text/mentions/no match. Enter opens new tab; Option-Enter current tab; empty query remains open; Backspace removes only with empty editor, explicit chip removal preserves query.
- [ ] Adapt matching/model/view and native editor together. Suppress default suggestions/assistant context only in active site mode; use existing SearchEngine URL encoding. Apply upstream fixed reference glass height clipped to actual bounds through WSurf's current palette style; no second glass system or new dependency.
- [ ] Run `native -only-testing:WSurfTests/CommandPaletteSiteSearchTests -only-testing:WSurfTests/MentionFieldTests -only-testing:WSurfTests/CommandPaletteShortcutTests -only-testing:WSurfTests/CommandPaletteRankingTests`. Smoke actual native Tab/chip/Backspace/Enter/Option-Enter, IME composition, focus/VoiceOver removal label and palette sizing in two windows. Commit and journal.

## T15 — Display-only native window/Dock title limit

**Upstream:** `eb338d7`.

**Files:** Modify T09-created `WSurf/App/AppCoordinator+Windows.swift` and `WSurfTests/App/WindowMenuTests.swift`.

**Interfaces:** Existing `windowTitle: String`; only native displayed page-title component is limited. `String.count`/`prefix` operate on grapheme clusters, not UTF-8 bytes.

- [ ] Port `nativeWindowTitlesLimitLongPageTitles(isPrivate:)`: short and exactly 40 unchanged, 300 ASCII and 41 family-emoji clusters become 39 + `…`, full tab title unchanged; profile/private suffix retained.
- [ ] Apply upstream display expression at NSWindow title assignment; do not truncate stored title, session data or palette results.
- [ ] Run `native -only-testing:WSurfTests/WindowMenuTests`. Smoke native Window/Dock entry with long title/profile/private suffix and original full page title. Commit and journal.

## T16 — Complete localization/docs adoption and journal reconciliation

**Upstream:** `2fe070a`, `f46c591`, plus docs/catalog portions of all behavioral tasks.

**Files:** Modify `WSurf/Localizable.xcstrings`, `README.md`, `ARCHITECTURE.md`, `MCP.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/upstream-migrations.md`; preserve `AGENTS.md` and `RELEASING.md` isolation/PR/deployment policies.

**Interfaces:** Final public contract is the implemented WSurf feature set, not intermediate historical README copy. Journal format/statuses are defined in its own header.

- [ ] Merge remaining upstream catalog changes/translations/selective obsolete entries; preserve WSurf-only keys/branding and each feature's live keys. Carry f46c591 readability/privacy/assistant copy, but don't restore its obsolete one-window limitation or pretend CEF has WebKit-only capabilities.
- [ ] Document multiwindow/profile/private ownership, transfer restrictions, remembered external app approvals/revocation, 32-field no-submit contract/rate-limit pause, Tab-to-search keys, supported engine capability distinctions and Xcode 27/OMP `.worktrees/` setup. Add one focused changelog entry for the migration rather than 31 redundant feature tours.
- [ ] Reconcile all 31 full SHAs, all mixed-commit task slices and upstream changed-file inventories. For every item record original behavior, WSurf adaptation, code commit(s)/PR, actual check evidence and status. Metal's partial baseline equivalence and execution correction are explicit; no invented applied/CI/deploy history. Check local links and plist/xcstrings JSON validity, then view changed settings/palette strings in the stage app. Do not create wording/source-copy tests.
- [ ] Commit docs/journal evidence; implementation coverage is complete only when every task's consumer behavior and fork constraints are covered.

## T17 — Whole-app compatibility gate, PR and authorized release handoff

**Files:** Execution evidence under owned `build/`/Pro artifacts and `docs/upstream-migrations.md`; no additional product scaffolding.

**Interfaces:** Consumes every prior completed task, exact execution feature commit, test result bundles, artifact provenance and migration backup. Produces reviewed PR/CI evidence, stage proof, and only after authorization an exact-main deployment record.

- [ ] Run complete native `native -enableCodeCoverage YES -resultBundlePath "$PRO_ROOT/FullSuite.xcresult"` including all four OCR integrations. Run `Tools/check-format.sh`, coverage **24.0** and performance gates using actual result/metric artifacts. Preserve budgets; diagnose failures rather than re-pin incidental tests or broaden CI skips.
- [ ] Build actual Debug app on Pro from the same clean snapshot with the existing Xcode project/CEF embedding build phases. Verify CEF framework/helper presence and launchability; a Swift syntax/CEF component probe is not a whole-app build. Record source commit, package pins, toolchain, build log/result and artifact hashes.
- [ ] Copy the complete app bundle to a separate Air stage location, not `/Applications/WSurf.app`, and launch with `WSURF_STAGE=1` and an owned `WSURF_STAGE_HOME`. Use native computer helpers, live confirmation where required, and fresh screenshot/AX proof. Exercise T09 full window matrix plus permissions/PDF/forms/site search/input/media, suspend/resume/close/relaunch, extension/Apple capabilities and CEF lifetime. Keep production browsing data untouched.
- [ ] Inspect an owned consistent deployed-schema/profile backup upgraded by this build: windows restore data intact; no private browsing rows/cookies/grants leaked to persistent storage. Prove rollback on an owned backup copy with the old app, never by feeding the upgraded database to it.
- [ ] Obtain fresh branch review, open PR to `main` with journal/spec/task evidence, resolve review and require green CI before merge. Do not publish/merge without the applicable authorization. Record actual PR and merge SHA only when they exist.
- [ ] For release/deployment, wait for CI on the exact PR-merged main SHA and build that clean merged source on Pro. Ask user approval before replacing their installed Air app. Once approved, quit WSurf, take a consistent backup of profile databases (including WAL/SHM consistency) and previous bundle, deploy exact verified artifact and perform production-safe launch checks. Record deployed SHA/artifact/backup/approval; rollback restores pre-migration data plus old app if needed. Without deployment approval the completed deliverable stops at verified PR/build/stage evidence, with deployment explicitly not performed.

## Completion checklist / plan self-review

- [ ] Every one of the journal's 31 upstream SHAs has an explicit disposition; db85459 has form + retry + no-progress evidence; 3997153 has stdio + speech + lyrics + geometry + favicon + autofill + lifetime evidence.
- [ ] T09 inventory and fork-only paths are migrated together; no old global coordinator/profile routing or legacy aliases remain; full-window transfer and private isolation hold on both engines.
- [ ] Named signatures remain consistent across task boundaries; Create paths are explicit, including new tests absent from deployed tree; later tasks modify files created by T09.
- [ ] Every Review Focus input has its owning test and real smoke scenario; upstream test confidence does not replace WSurf-specific proof.
- [ ] Journal separates planning/applied/verified/merged/deployed and already-equivalent; all evidence is observed, no inferred CI or source provenance from version strings.

Planning self-review is performed before handoff. The checkboxes above belong to future implementation and remain open until actually exercised.
