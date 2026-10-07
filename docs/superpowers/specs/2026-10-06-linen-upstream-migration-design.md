# Linen upstream migration — WSurf design and acceptance contract

## Scope and authority

Migrate **all 31 commits** from Linen's `3c532ff33660f14b7ba4039cd924473de5f80b60` (the shared v0.7.1 tree) through `eb338d70bd1740a33e6a34f71e328e13d014bc42`, inclusive of fixes, features, test maintenance, dependencies, CI and documentation. The user explicitly expanded the earlier fixes-only request. The range has no merge commits; its aggregate changes touch 225 files, with 8,798 insertions and 1,564 deletions.

**Assumption supplied by the user:** upstream changes have been thoroughly tested. Do not create a second effort to validate Linen itself. Reuse upstream behavioral tests when porting; spend additional verification on changed WSurf contracts, runtime integration and fork-specific boundaries. This assumption is not evidence that WSurf's adapted implementation already passes.

This document authorizes a plan, not implementation, publishing, merging or deployment. The [implementation plan](../plans/2026-10-06-linen-upstream-migration.md) and [versioned migration journal](../../upstream-migrations.md) travel together. No upstream item is silently omitted because it is large or not a bugfix.

## Verified last-deployed baseline

- Source: `4d33cb93ed22a92ffa2db0d5fc8109b5e4a78557`, merged in [WSurf PR #5](https://github.com/wsagency/wsurf/pull/5).
- Installed artifact: `/Applications/WSurf.app`, version `0.1.0`, build `1`. These version fields alone do **not** identify a source commit.
- Source provenance: `build/merged-main-4d33cb9/provenance.json` in the main project checkout. The installed Debug dylib, local merged-main artifact and Pro build artifact have identical SHA-256: `d03913ca7ae850c613a179435564e1a36d67b4d41d019676d9c45dc3f1d3b9cd`.
- Pro source snapshot: `/tmp/wsurf-sidebar-main-20261006-1791305932863/source`; DerivedData: the same parent directory's `DD`; result bundle: `merged-main-build.xcresult`. The checksum source comparison before editing planning documents showed timestamp differences, not source-content differences.
- Observed deployment build evidence: Debug arm64, ad-hoc, zero errors and one existing Sendable warning in `ProfileSettingsStore`. This is **not** a claim of a green complete CI run or a new application smoke test.
- Remote `main` subsequently moved to `11ab647c184bb2f0a13b65e3a589b5a1baa29f2e`, [PR #6](https://github.com/wsagency/wsurf/pull/6): nine formatting-only files, +32/-15. Research uses deployed `4d33cb9`; execution starts from current `origin/main` and retains that formatting change. Any additional main delta requires a fresh compatibility assessment before applying the plan.
- The dirty shared checkout's `971d10695610fab2eae52edfacfce148732f362b` is neither the deployed baseline nor the implementation input. Do not stash, reset, copy over or commit its unrelated work.

Planning isolation: `.worktrees/linen-migration-plan-20261006`, branch `feature/linen-migration-plan-20261006`, based on `4d33cb9` to make the deployed-source comparison reproducible. This historical planning branch is not the branch to deploy.

## Global constraints

- Every task, including documentation and configuration, uses a `feature/<short-name>` branch in the project-root `.worktrees/` directory; `/.worktrees/` stays gitignored. OMP automatically supplies the separate task worktree. Detect and reuse it; do not create a second worktree or switch the shared checkout.
- Develop on the Air; native app build and tests run through SSH alias `pro` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Verified toolchain: Xcode 27.0 (`27A266a`), Swift 6.4 (`swiftlang-6.4.0.34.1`). Do not alter global `xcode-select` or fake SwiftUI macros on the Air.
- Minimum runtime remains macOS 26, Apple silicon; this migration's native build toolchain floor is Xcode 27.0. Swift 6 isolation and concurrency checks remain enabled.
- Keep WSurf identity `io.wsagency.wsurf`, WSurf App Support/database/Keychain identifiers, `WSURF_*` environment variables, stage isolation, MCP socket/config namespaces, update feed, signing and release gates. Merge localization keys; never replace the WSurf catalog, project or package lockfile with Linen's file.
- Preserve CefSwift revision `59cad64e124b8efdb6b2ee811963097bb6e689e8`. Resolve AnyLanguageModel 0.15.1 (`c4a1acdbc8a2a9f967fada82208798b3a719a458`) and swift-collections 1.7.1 (`98ef3c98609a1e31b7e157b5b619579001a789d6`), retain other required packages, and regenerate WSurf acknowledgements.
- CI keeps coverage floor **24.0%**, existing performance budgets, watchdog and WSurf release protection. SwiftLint becomes **0.65.1**, archive SHA-256 `c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0`.
- Clean cutover: migrate all affected callers; remove obsolete singleton routing and dead code. Do not add legacy-global compatibility aliases, a second permission store or a second download pipeline.
- Each adapted behavior has a versioned journal entry linking full upstream SHA, task, adaptation, WSurf implementation commits, PR and actual verification. Planning entries must not claim implementation or deployment.
- Integrate only through reviewed PRs to `main` with required CI. Release/deployment uses the exact PR-merged, CI-passing main commit. Replacing `/Applications/WSurf.app` on the Air additionally requires explicit user deployment approval.

## Design decisions and acceptance

### Adopt behavior rather than overwriting the fork

Use parent-to-commit patches pinned by the journal. Straightforward isolated changes can be applied as adapted patches. The 125-file window change is one coherent architectural cutover: schema, context ownership, registry, callers, extension/MCP ownership and transfers must be reviewable together, not shipped as a partial singleton/multiwindow hybrid. Later commits depend on that owner model.

Preserve WSurf's existing BrowserPage abstraction, WebKit/CEF engine selection, native Apple integrations, WebKit-only extension/PiP capability boundaries, persistent-background behavior, lazy page materialization, page close acknowledgements, download-handoff deduplication, Favorites and pinned folders, hierarchical sidebar undo, and current assistant-versus-external-MCP trust separation.

### Profile-aware native windows

Port `BrowserApplication` as the app-level registry and routing owner; each `AppCoordinator` owns one native window, selection, BrowserModel and assistant/voice task lifetime. Regular windows in the same profile share one `BrowserProfileContext`. Each private window gets a fresh, uncached context with ephemeral browsing stores, approvals, downloads/history/log and CEF request context.

Make WSurf's WebViewPool and Chromium context selection explicit. A private Profile's shared descriptor/UUID is not a private-session identity. Chromium teardown must select the actual context, not close every page bearing `Profile.privateID` or another window's regular profile. Never use `ChromiumRuntime.currentProfile` to decide the owner of an already-created page.

SitePermissions is shared within a regular context. Its engine-preference change callback must fan out to every live registered window using that context; switching/closing one window cannot replace or clear another owner's subscription. Other profile/private contexts remain unchanged.

Transfer is legal only between open owners with the identical context and database writer. Move the same tab, BrowserPage and native view; preserve navigation/POST state and engine. Do not reload, replay navigation or close the transferred page. Cancel source-bound assistant/voice work, clear source peek/media state, rebind all destination callbacks, and atomically persist both snapshots. Old sidebar undo closures must not resurrect or mutate a tab owned by another window.

### Window sessions and safe storage migration

Port `sessionWindow(id,lastActiveAt,closedAt,revision)`, retirement watermarks and `windowID` constraints on tab/folder/item/split tables. `sessionItem` key becomes `(windowID,position)`. Legacy rows begin in the all-zero window ID; startup transactionally remaps legacy/colliding IDs before registering windows.

**WSurf additions are required migration inputs:** retain `isFavorite` on sessionTab and `isPinned` on sessionFolder, hierarchy/split/state blobs and existing history/download/assistant data. Closing synchronously saves; monotonic revisions reject late snapshots and retired IDs. Transfer cancels both debounced saves before the transaction. Exercise an untouched deployed-schema database copy, not merely a database produced by the new schema.

Rollback restores a consistent **pre-migration** database/profile backup together with the previous app. Running the old app against the upgraded database is not a supported downgrade.

### Trust and asynchronous ownership

External MCP connections bind to the eligible active regular window at connection time. Focus never retargets them; private focus refuses new connections without disconnecting existing regular clients. Closing or switching an owner revokes only its grants/connections. Shared extension managers register expiring per-window adapters; an unregistered adapter cannot operate on a new window.

Provider definitions remain app-wide; profile model choice, context budget, tools and action grants become context-owned. Every async assistant/helper turn inherits its initiating settings through `LLMSettings.$scoped.withValue`, including work continuing after a different window gains focus. Question UI appears only in its originating space and chrome/inspector surface.

Remembered external-app approval is keyed by canonical HTTP(S) **source** origin plus app scheme/bundle, saved only after acceptance, revocable in existing website settings. Unknown/ambiguous source has no persistent remember option; private allowance stays in that tab's session policy. CEF must dispatch unsupported app-scheme navigation through that policy before its current scheme gate discards it; capture actual source-frame/initiator provenance, never destination URL or a guessed current top-level origin.

### Browser, assistant and palette behavior

- Preserve editing shortcuts across keyboard layouts and native menu routing.
- Autofill focus waits for stable layout: 50 ms checks, 100 ms stability, <1 px geometry changes, 1 s deadline; typing, blur/navigation, dismissal and expiry cancel it. Trusted keydown acknowledges delivered keypress; missing keyup does not cause replay.
- Media has no repeated idle/hidden scanning; lyrics tick only when visible, playing and synced. Geometry rejects nonfinite dimensions and clamps finite negative dimensions to zero.
- Distinguish New Page from Start Page; use main-frame PDF response filenames without overwriting custom titles. Add a real CEF response bridge; do not infer MIME/filename from extension alone.
- WebKit PDF-viewer byte saves, including edits, use existing DownloadManager destination reservations, quarantine and private-history policy. CEF retains its native viewer/download behavior; Apple's private PDF selectors do not define a new Chromium edited-byte capability.
- Restored scroll survives bounded late zero resets (20 attempts, 60 ms apart) and yields to user input, pagehide or a different nonzero page scroll.
- Form filling accepts 1–32 distinct positive refs with unchanged `ref/value/select` schema; validates before writes, uses control-appropriate operations, skips sensitive/unavailable/file controls, never submits, verifies retained state and reports exact refs. Navigation, cancellation or grant revocation between fields stops before touching a replacement document.
- Rate-limit generation retry is bounded to two attempts (2 s then 4 s, bounded Retry-After), excludes quota/billing, remote-actions-enabled runs and any replay of browser actions. Exhaustion pauses without requesting another summary. Visual coordinate/input variation cannot disguise same-page no-progress.
- Tab-to-search supports valid configured/built-in/site aliases with >=2-character match, IME/mention/Shift-Tab safeguards, empty-query non-submission, chip removal only on empty-editor Backspace, Enter new tab and Option-Enter current tab. Preserve focus, VoiceOver and existing palette glass conventions.
- Native window/Dock display truncates page title to 40 grapheme clusters (39 + ellipsis when longer), with profile/private suffix; stored tab title is unchanged.

### Tooling, fixtures and maintenance

Port all fixture maintenance: active headless WebKit configuration, stable context-fixture titles/server lifetimes, real external WKNavigationActions, ranking without page loads, and replies from the expected extension page. Keep meaningful behavior tests; do not import or re-pin incidental wording/source/wiring assertions.

Port CPU OCR fallback when no Neural Engine is available. Hosted CI exclusions are limited to the four upstream AttachmentTests OCR integrations; all four remain enabled on native Pro. Execution corrected the original Metal baseline inference: installation was present only in CI, not release/tip. Retain the CI step without duplication and port the two missing steps; the journal preserves the correction and actual evidence.

Use supported WSurf `macos-26` hosted runner plus explicit Xcode 27.0 preflight instead of blindly copying the unverified upstream `xcode-27` runner label. Missing image/toolchain fails that gate; it does not justify lowering the toolchain or widening exclusions. Preserve pinned checkout/cache/upload-action upgrades and locked resolution semantics. Port speech preparation, URL-aware favicon fallback/cache behavior, privacy-safe DEBUG autofill diagnostics and full resource-lifetime coverage from the mixed idle/startup commit.

Adapt README/architecture/MCP contract and localization changes to WSurf's final multiwindow state. Do not reintroduce the obsolete one-window limitation from the earlier README commit.

## Compatibility proof and completion

For each task: adapt upstream behavior tests, add only uncertain fork-edge regressions, run the affected native suites on an owned Pro snapshot, and exercise the actual changed WSurf path. Final proof includes complete native suite (including OCR), CEF embedding and runtime, stage UI on the Air with owned `WSURF_STAGE_HOME`, profile/window/transfer/relaunch scenarios, permission and MCP revocation, private disk isolation, and existing coverage/performance gates.

Sourcekit queries on the Air returned empty references for context classification, OCR and form filling; the index is insufficient for an exhaustive caller graph. This is recorded as a tool limitation, not proof of absent callers. During implementation obtain references from the Pro indexed build before exported-symbol cutovers.

Completion means all 31 journal items have an explicit implemented-and-verified or already-equivalent disposition, every sub-area of mixed commits has evidence, and WSurf fork contracts hold. Deployment is a separately authorized transition, never implied by plan or successful tests.
