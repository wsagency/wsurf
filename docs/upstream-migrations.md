# WSurf upstream migration journal

Versioned provenance for changes imported from [Linen](https://github.com/kavoye/linen-browser). This file is maintained with source changes, not reconstructed from release notes.

## Pinned migration: 2026-10-06

- Upstream base (exclusive): `3c532ff33660f14b7ba4039cd924473de5f80b60`.
- Upstream tip (inclusive): `eb338d70bd1740a33e6a34f71e328e13d014bc42`.
- Scope: **31 unique commits**, every feature/fix/test/dependency/CI/docs change. No merge commits in the range.
- WSurf research baseline: last deployed `4d33cb93ed22a92ffa2db0d5fc8109b5e4a78557` ([PR #5](https://github.com/wsagency/wsurf/pull/5)); installed binary provenance is in the [spec](superpowers/specs/2026-10-06-linen-upstream-migration-design.md).
- Execution base: `9606f9d4d14669798049f32c37aa8f8beab7e2c8`, fetched from origin/main on 2026-10-06. Preserves `11ab647` app formatting and the subsequent website deployment/session-worktree policy changes; see T00 below.
- [Implementation plan](superpowers/plans/2026-10-06-linen-upstream-migration.md) defines T00–T17. All tasks use OMP-supplied feature worktrees under project-root `.worktrees/`, gitignored.
- User-supplied assumption: upstream thoroughly tested. New evidence below is for WSurf adoption/compatibility, not re-certification of upstream.

## Record format and transitions

Each manifest row records full source SHA/link, original subject, WSurf task(s), adaptation and current disposition. The execution record for an item adds **every WSurf implementation commit**, PR/merge SHA, exact checks with observed results and artifact references, and any later deployment SHA/build hash/approval/rollback backup. Split items require evidence for every named task before aggregate verification.

`PLANNED` → `APPLIED` → `VERIFIED` → `MERGED` → `DEPLOYED` are distinct transitions. `ALREADY_EQUIVALENT` records behavior demonstrably present in the pinned WSurf baseline and its evidence; it does not claim the upstream commit was cherry-picked. Preserve prior events when adding a transition; do not rewrite them as if later evidence existed earlier. Failed checks leave their actual outcome recorded and do not advance status.

Use full-SHA `Upstream-Commit:` and `Migration-Task:` trailers on code commits. Record those **known commits** in a following journal/evidence commit; never insert a guessed/self-referential SHA. Actual PR/CI/deploy fields are absent until those events occur. A combined WSurf commit can reference multiple upstream SHAs; a split upstream commit can reference multiple WSurf commits. Record both directions.

## Complete source manifest

At initialization: **30 PLANNED; 1 ALREADY_EQUIVALENT**. Execution corrected the Metal item to **PLANNED** because only CI was equivalent, not release/tip; the baseline finding and correction are preserved below. Implementation, verification, merge and deployment remain separate recorded events.

| # | Full upstream commit | Original subject | Task(s) | WSurf adaptation | Status |
|---|---|---|---|---|---|
| 1 | [`791a5487203677e5cceadd0b1c17c172c62acd49`](https://github.com/kavoye/linen-browser/commit/791a5487203677e5cceadd0b1c17c172c62acd49) | fix(mcp): Detect the bundled Codex CLI and update integration tests | T02 | Add nested ChatGPT Codex path; retain WSurf config identity and safe TOML merge. | APPLIED |
| 2 | [`fe1d5dc034c1fa780eff2dcd1a7dbba3e670c168`](https://github.com/kavoye/linen-browser/commit/fe1d5dc034c1fa780eff2dcd1a7dbba3e670c168) | fix(palette): Preserve editing shortcuts across keyboard layouts | T08 | Native layout-aware editing shortcuts; preserve WSurf menu and palette ownership. | APPLIED |
| 3 | [`4ea5d3545fd4284b6f52c50f51fe0b0936dde04c`](https://github.com/kavoye/linen-browser/commit/4ea5d3545fd4284b6f52c50f51fe0b0936dde04c) | fix(autofill): Wait for focused fields to finish layout | T03 | Port bounded focus/layout settling and cancellation; retain WSurf WebKit autofill bridge. | APPLIED |
| 4 | [`b3bc2effad8db625ab32a8400776dfd2478b6f82`](https://github.com/kavoye/linen-browser/commit/b3bc2effad8db625ab32a8400776dfd2478b6f82) | fix(media): Stop polling idle players and hidden pages | T04 | Adapt visible-playing/BFCache behavior to WSurf already-event-driven media script; no unconditional polling. | APPLIED |
| 5 | [`2c3eee541984de91aca0cc5ec33326ab577553e6`](https://github.com/kavoye/linen-browser/commit/2c3eee541984de91aca0cc5ec33326ab577553e6) | fix(tabs): Show PDF filenames and correct untitled page titles | T05 | New Page/Start Page distinction and response PDF names; add real CEF main-frame response bridge; retain custom titles. | APPLIED |
| 6 | [`b06f891be98f9574eb5292312319db7b1530d96c`](https://github.com/kavoye/linen-browser/commit/b06f891be98f9574eb5292312319db7b1530d96c) | feat(permissions): Remember external app approvals by website | T06 | Origin+app approvals in existing SitePermissions; private session-only grants; real WebKit/CEF source provenance. | APPLIED |
| 7 | [`3007d94feae184f2f0e6cd3a6c5b4b67b5358768`](https://github.com/kavoye/linen-browser/commit/3007d94feae184f2f0e6cd3a6c5b4b67b5358768) | fix(downloads): Save PDF viewer documents through download manager | T05 | Save WebKit viewer bytes via existing manager/reservations/quarantine; preserve handoff dedupe and CEF native download capabilities. | APPLIED |
| 8 | [`3fdb775df616da29ee4a65a0e2e4cc314e94e428`](https://github.com/kavoye/linen-browser/commit/3fdb775df616da29ee4a65a0e2e4cc314e94e428) | fix(settings): Open the Downloads page from download settings | T08 | Open actual Downloads content from settings/search; keep actual page clear/cancel/open/reveal actions. | APPLIED |
| 9 | [`2fe070a35d9021678855a0b6bac04a65140505d3`](https://github.com/kavoye/linen-browser/commit/2fe070a35d9021678855a0b6bac04a65140505d3) | chore(localization): Refresh remaining catalog entries | T16 | Selective catalog refresh after features; retain WSurf-only keys and branding. | APPLIED |
| 10 | [`498d2327c463f3442c4695a4c1beb3c7a144385b`](https://github.com/kavoye/linen-browser/commit/498d2327c463f3442c4695a4c1beb3c7a144385b) | fix(settings): Keep reset copy consistent with the string catalog | T08 | Advanced global reset catalog/copy consistency, not theme-reset behavior. | APPLIED |
| 11 | [`f0eba22e9a090d607bd35de006a1b9f719bc1a74`](https://github.com/kavoye/linen-browser/commit/f0eba22e9a090d607bd35de006a1b9f719bc1a74) | test(agent): Keep context fixture titles stable while pages load | T01 | Stable explicit context fixture titles and HTTP server lifetime; keep WSurf behavioral assertions. | APPLIED |
| 12 | [`c1e874d3f3e6c6f9d9b6eddfd16eda3b3ec1a1c2`](https://github.com/kavoye/linen-browser/commit/c1e874d3f3e6c6f9d9b6eddfd16eda3b3ec1a1c2) | test(web): Use real WebKit actions for external navigation | T06 | Real loaded-page WKNavigationAction tests with actual requesting origin, not fabricated action objects. | APPLIED |
| 13 | [`a05a57708fe66e4dea4710015532fb3900b8e471`](https://github.com/kavoye/linen-browser/commit/a05a57708fe66e4dea4710015532fb3900b8e471) | test(performance): Isolate result ranking from WebKit page loads | T01 | Ranking measures metadata-only projection, not page loads; retain WSurf performance budgets. | APPLIED |
| 14 | [`90e222bf96106ea6ea3844f82afa9f686d81be6f`](https://github.com/kavoye/linen-browser/commit/90e222bf96106ea6ea3844f82afa9f686d81be6f) | fix(web): Preserve restored scroll positions across late WebKit resets | T07 | Bounded late-zero scroll restoration; yield to input/pagehide/nonzero page scroll; shared BrowserPage path. | APPLIED |
| 15 | [`9b59c8351c6890e9a29ac962704199cda98ee2ae`](https://github.com/kavoye/linen-browser/commit/9b59c8351c6890e9a29ac962704199cda98ee2ae) | test(extensions): Wait for replies from the expected page | T01 | Filter extension replies by expected page and required result prefixes; retain native controller/lifetime isolation. | APPLIED |
| 16 | [`ce63cda705780ace77a2d0c5f1c85800970da3c3`](https://github.com/kavoye/linen-browser/commit/ce63cda705780ace77a2d0c5f1c85800970da3c3) | test(web): Keep headless automation fixtures active | T01 | Active headless WK configuration reused by existing fixtures; production scheduling unchanged. | APPLIED |
| 17 | [`2fe08fe3b63a1162d600298eba15577647298357`](https://github.com/kavoye/linen-browser/commit/2fe08fe3b63a1162d600298eba15577647298357) | fix(agent): Verify keypress delivery on trusted keydown | T03 | Trusted keydown delivery acknowledgement, no retry for absent/consumed keyup; retain engine adapters. | APPLIED |
| 18 | [`53fbb4c23337aeadc6e4c795cbbb0f6539e5c1bf`](https://github.com/kavoye/linen-browser/commit/53fbb4c23337aeadc6e4c795cbbb0f6539e5c1bf) | Update CI to Xcode 27 and upgrade stable dependencies | T01 | Xcode27/SwiftLint/actions/locked resolution/ALM+collections and API changes; retain CefSwift/release gates, use supported WSurf runner with explicit preflight. | APPLIED |
| 19 | [`f46c5917d55d1b0a96d43fa378dce3d87b6ca51c`](https://github.com/kavoye/linen-browser/commit/f46c5917d55d1b0a96d43fa378dce3d87b6ca51c) | chore: update README.md | T16 | README clarity/privacy updates in WSurf terminology; final multiwindow state supersedes historical one-window copy. | APPLIED |
| 20 | [`853ce9b56f760d8ac1e7abbb63e2de339c8a6951`](https://github.com/kavoye/linen-browser/commit/853ce9b56f760d8ac1e7abbb63e2de339c8a6951) | Install Metal toolchain before CI builds | T01 | CI install/version probe already equivalent; port missing release/tip steps without duplicating CI. Corrected during execution. | APPLIED |
| 21 | [`231d2ece0c2cb75d4f10a8c92c9709276edb743e`](https://github.com/kavoye/linen-browser/commit/231d2ece0c2cb75d4f10a8c92c9709276edb743e) | Fix OCR and autofill tests on virtual macOS runners | T01 | CoreML CPU OCR fallback and active autofill fixtures; real OCR remains enabled on native Pro. | APPLIED |
| 22 | [`4367b14443831e114a30aa719efa6f1c16a3c984`](https://github.com/kavoye/linen-browser/commit/4367b14443831e114a30aa719efa6f1c16a3c984) | Exclude unsupported Vision OCR tests from hosted CI | T01 | Only four unsupported hosted Vision OCR integrations excluded; no native Pro exclusions or lowered coverage. | APPLIED |
| 23 | [`c616faf5ab6974040570173a5cfba2dcf8baa1c8`](https://github.com/kavoye/linen-browser/commit/c616faf5ab6974040570173a5cfba2dcf8baa1c8) | fix: Improve folder preview icon contrast in dark mode | T08 | Gray folder preview secondary tint; preserve colored previews and WSurf sidebar layout. | APPLIED |
| 24 | [`3578dc201402767b433d994dd40aedd3099f26ce`](https://github.com/kavoye/linen-browser/commit/3578dc201402767b433d994dd40aedd3099f26ce) | fix(mcp): Accept object-valued experimental capabilities | T02 | Normalize only object-valued initialize.experimental at inbound SDK boundaries; standard fields/grants unchanged. | APPLIED |
| 25 | [`cd1575134efaac800dda7bac92dcc862d394b43e`](https://github.com/kavoye/linen-browser/commit/cd1575134efaac800dda7bac92dcc862d394b43e) | feat(windows): Add profile-aware browser windows | T09 | Atomic registry/context/session/caller cutover; extend CEF context identity/lifetime and engine preference fanout; retain Favorites, pinned folders, sidebar undo and trust boundaries. | APPLIED |
| 26 | [`25bffb9b1ddc9d4b20146c6d55b1637fc739f548`](https://github.com/kavoye/linen-browser/commit/25bffb9b1ddc9d4b20146c6d55b1637fc739f548) | fix: Show assistant questions only where the request started | T10 | Questions bound to original window/space and chrome-versus-inspector surface. | APPLIED |
| 27 | [`db8545929e0bb84d3f36e086c23a12ad197f6fd8`](https://github.com/kavoye/linen-browser/commit/db8545929e0bb84d3f36e086c23a12ad197f6fd8) | fix: improve form filling and rate-limit recovery | T11, T12 | Shared 32-field guarded batch and exact verified refs; bounded rate-limit generation recovery, no action replay, summary-free pause and visual no-progress. | APPLIED |
| 28 | [`399715330a84b304251d3844188f2a53fd711cc0`](https://github.com/kavoye/linen-browser/commit/399715330a84b304251d3844188f2a53fd711cc0) | fix: Reduce idle work and correct startup behavior | T02, T03, T04, T09, T13 | All slices: DispatchIO stdio; cached synchronous speech; visible-playing synced lyrics; finite geometry; URL-aware favicons; privacy-safe autofill diagnostics/frame tests; WebKit+CEF lifetime. | APPLIED |
| 29 | [`b1d76114b6f4250fa6c4d30c6b18d2be650ea8e2`](https://github.com/kavoye/linen-browser/commit/b1d76114b6f4250fa6c4d30c6b18d2be650ea8e2) | fix(sidebar): Keep drop targets visible on light websites | T08 | Drop target follows sidebar surface, not forced website color scheme; keep WSurf Favorites/pin typography. | APPLIED |
| 30 | [`56880f2994cefcb38944f065894c98569178c653`](https://github.com/kavoye/linen-browser/commit/56880f2994cefcb38944f065894c98569178c653) | feat(palette): Add Tab-to-search site chips | T14 | Site match/chips/native editor safeguards and glass sizing; reuse SearchEngine and WSurf palette style. | APPLIED |
| 31 | [`eb338d70bd1740a33e6a34f71e328e13d014bc42`](https://github.com/kavoye/linen-browser/commit/eb338d70bd1740a33e6a34f71e328e13d014bc42) | fix(window): Limit Dock menu page titles to 40 characters | T15 | Limit native displayed page title to 40 grapheme clusters; preserve full stored tab title and profile/private suffix. | APPLIED |

## Baseline equivalence evidence — 853ce9b

**Corrected disposition:** partial baseline equivalence, not an aggregate ALREADY_EQUIVALENT item.

- Initial planning inferred equivalence in all three workflows from CI's exact commands at lines 38–41. That inference was incorrect.
- Execution inspected canonical `9606f9d` workflow sources: CI had `xcodebuild -downloadComponent MetalToolchain` and `xcrun metal --version`; release/tip selected Xcode then proceeded directly to package caching. Neither contained Metal installation.
- T01 retains the existing CI step and ports the missing release/tip steps. Their implementation commit and actual workflow verification are recorded separately; this correction does not claim a green hosted run.

## Mixed-commit evidence requirements

### db85459

| Slice | Task | Required WSurf evidence |
|---|---|---|
| 32-field/control-aware fill and contract | T11 | Real guarded mixed-form values, exact verified refs, no submit, stale/revoked/cancelled document boundary on both engines; assistant + external MCP consumers |
| Provider rate-limit retry and pause | T12 | Bounded attempts, one action, no remote-action replay, quota/billing exclusions, saved checkpoint and no extra summary |
| Visual no-progress | T12 | Coordinate/input variation cannot hide unchanged page; changed-page/failure state still distinguished |

### 3997153

| Slice | Task | Required WSurf evidence |
|---|---|---|
| DispatchIO stdio/EOF/framing/lifetime | T02 | Split/coalesced/overflow/newline/idle disconnect/release plus real endpoint initialize/list/EOF |
| Speech catalog startup/cache | T13 | Synchronous preparation before bootstrap/test return; one enumeration including empty catalog; muted default preserved |
| Lyrics ticking/deinit | T04 | Controlled clock, visible+playing+synced only; cancellation on hide/pause/release |
| Web/media geometry | T04 | Both native BrowserPage surfaces: nil/nonfinite rejection, finite negative clamp and positive retention |
| Favicon URL identity/fallback/restored+pinned callers | T13 | Localhost/IP/IPv6/HTTP/HTTPS/port routes; no credential/query/fragment leaks; existing cache/private rules |
| Autofill DEBUG diagnostics + sandbox frame policy | T03 | Existing delivery policy behavior; safe classification only, no raw exception/page URL; no sandbox relaxation |
| Browser resource lifetime | T09 | Actual page/view release, no transfer close, CEF close acknowledgement before context cleanup |

The complete historical mixed patch changes 20 paths; every path is covered by these slices. Do not mark aggregate verification based only on the commit's idle-work title.

## Hosted OCR exclusions — 4367b14

Only `.github/workflows/ci.yml` hosted test invocation gets:

```text
-skip-testing:WSurfTests/AttachmentTests/normalizesImagesAndRecognizesText()
-skip-testing:WSurfTests/AttachmentTests/recognizesTextWithoutANeuralEngine()
-skip-testing:WSurfTests/AttachmentTests/recognizesScannedPDFPages()
-skip-testing:WSurfTests/AttachmentTests/pastingAnImageCreatesARemovableAttachment()
```

They remain enabled in `WSurf.xctestplan` and native Pro checks. Upstream attributes the hosted failure to Xcode 27 runner VMs lacking a usable Vision backend even with CPU selection. Do not widen this exception or claim hosted OCR passed. Remove exclusions once that runner backend supports them.

## T09 exact mapped inventory — cd15751

All **125 changed upstream paths** below are accounted for in the atomic cutover. Actions are relative to the deployed `4d33cb9` tree: **19 Create, 106 Modify**. The mapping changes only `Linen/`, `LinenTests/` and project prefixes; it is an inventory, **not an instruction to overwrite WSurf files**. T09's fork-only CEF/SidebarUndo/lifetime paths are additional and listed in the plan. Code scopes/caller ownership/field adaptations are defined by T09 and the spec.

`LLMSettings+Scoped.swift` adoption retains task-local/profile-provider behavior, not obsolete global getter aliases; migrate callers explicitly. All 125 paths must be reviewed, including downstream UI/settings/autofill/extension callers and changed tests/docs.

Execution adaptation: the mapped upstream
`WSurfTests/Features/ProfileWindowSelectionTests.swift` lives in WSurf's existing
`WSurfTests/Settings/` test grouping. The historical mapping below is retained;
this is the implemented path, not an omitted test.
The mapped `WSurf/Agent/Providers/LLMSettings+Scoped.swift` behavior is consolidated
in WSurf's existing `WSurf/Agent/Providers/Provider.swift`: `LLMSettings.scoped`,
`LLMSettings.current` and `ProfileProviderCatalog` live beside the instance-backed
settings type. No obsolete global-accessor forwarding file is retained.

| Action | Exact WSurf path | Role |
|---|---|---|
| Modify | `ARCHITECTURE.md` | Public documentation |
| Modify | `WSurf/Agent/AgentToolCatalog.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Agent/AgentTurnModel.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Agent/ContextBudget.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Agent/ConversationLog.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Agent/LinkGist.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Agent/Providers/ContextWindowDiscovery.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/Agent/Providers/LLMSettings+Scoped.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Agent/Providers/Provider.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/App/AppCoordinator+Bootstrap.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/App/AppCoordinator+Media.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/App/AppCoordinator+Profiles.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/App/AppCoordinator+WindowAgents.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/App/AppCoordinator+Windows.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/App/AppCoordinator.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/App/AppDelegate.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/App/BrowserApplication+Profiles.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/App/BrowserApplication.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/App/MainMenu.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Extensions/ExtensionLibrary.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Extensions/ExtensionManager+ControllerDelegate.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/Extensions/ExtensionManager+Windows.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Extensions/ExtensionManager.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Extensions/ExtensionTabBridge.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Extensions/ExtensionToolbarViews.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Localizable.xcstrings` | Window/context ownership and caller cutover |
| Modify | `WSurf/MCP/BrowserMCPServer.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/MCP/MCPAccessConsent.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/MCP/MCPBrowserSession.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Onboarding/OnboardingOverlay.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/Profiles/BrowserProfileContext.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Profiles/Profile.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Profiles/ProfileStore.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/BrowserSettings.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/IntelligenceViewModel.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/Pages/AssistantGrantsPage.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/Pages/IntelligenceSettings.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/Pages/PrivacySettings.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/Pages/ProfileSettings.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/Pages/WebsiteDataPage.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/Pages/WebsiteSettings.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/SettingsElements.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Settings/SettingsView.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Support/AppDatabase.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Ask/AgentInspector.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Ask/AskPageChip.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Ask/AskSurfaceInteraction.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Ask/AskSurfaceModel.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Ask/AssistantComposerToolbar.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Ask/AssistantTextEditor.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Ask/MentionField.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/UI/Chrome/LinkWindowMenuItems.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Chrome/ModelChip.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/UI/Chrome/ProfileFavicons.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Chrome/ToolbarHoldMenu.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/CommandPalette/CommandPaletteCommands.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/CommandPalette/CommandPaletteModel.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/CommandPalette/OmniboxResults.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Content/DownloadFlight.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Content/HistoryView.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Content/InternalPageSurface.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Content/SiteControlsMenu.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Content/SiteIdentity.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Shell/BrowserHost.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Shell/BrowserView.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Sidebar/ProfileButton.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Sidebar/SidebarMenus.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Sidebar/SidebarSplitRow.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Sidebar/SidebarTabRow.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/Sidebar/WorkspaceList.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/StartPage/StartPageComponents.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/UI/StartPage/StartPageSections.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Updates/UpdateController.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Assistant/AgentActionPolicy.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Autofill/AutofillSaveCoordinator.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Autofill/ContactAutofill.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Autofill/PasswordAutofill.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Autofill/PaymentCardAutofill.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Model/BrowserModel+Ordering.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Model/BrowserModel+Pages.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Model/BrowserModel+Sessions.swift` | Window/context ownership and caller cutover |
| Create | `WSurf/Web/Model/BrowserModel+Windows.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Model/BrowserModel.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Page/LinkPeek.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Page/PageClickWatcher.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Page/PageSaving.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Page/PageZoom.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Privacy/BrowsingData.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Privacy/ContentBlocker.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Privacy/SitePermissions.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Privacy/TabPopupPolicy.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Search/Omnibox.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Search/SearchSuggestions.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Search/SearchURLBuilder.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/System/DownloadManager.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Tabs/BrowserTab+PageControls.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Tabs/BrowserTab+WebKitDelegates.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Tabs/BrowserTab.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Tabs/PeekPanel.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Tabs/TabContextMenu.swift` | Window/context ownership and caller cutover |
| Modify | `WSurf/Web/Tabs/WebViewPool.swift` | Window/context ownership and caller cutover |
| Modify | `WSurfTests/Agent/AgentTurnModelTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/Agent/ConversationLogTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/Agent/MCPWindowScopeTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/App/LinkWindowTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/App/MainMenuKeyTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/App/MultiWindowTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/App/ProfileSwitchTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/App/WindowMenuTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/Extensions/ExtensionWindowTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/Features/ExtensionProfileScopeTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/Features/ProfileWindowSelectionTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/Settings/AssistantToolSettingsTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/Settings/ProfileSettingsTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/UI/CommandPaletteModelTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/UI/CommandPaletteRankingTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/Web/BrowserPagesTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/Web/BrowserProfileContextTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/Web/ContentBlockerTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/Web/DownloadListPersistenceTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/Web/PeekLifecycleTests.swift` | Behavioral test / fork adaptation |
| Modify | `WSurfTests/Web/TabContextMenuTests.swift` | Behavioral test / fork adaptation |
| Create | `WSurfTests/Web/WindowSessionTests.swift` | Behavioral test / fork adaptation |
| Modify | `MCP.md` | Public documentation |
| Modify | `README.md` | Public documentation |

## Execution events

### Planning initialized — 2026-10-06

- WSurf implementation commits: none; this is a plan/manifest, not an applied import.
- PR/merge/deployment: not performed for this migration.
- Evidence gathered: last-deployed provenance/artifact equality, pinned parent-to-commit patches for all 31 items, mapped deployed-source inspection, three read-only subsystem research slices, full window inventory and existing Metal workflow equivalence.
- Workflow edit smoke: `git check-ignore -v .worktrees/ignore-probe/` inside the planning worktree returned `.gitignore:18:/.worktrees/`; the shared checkout also already contains `/.worktrees/`.
- Tool limitation: Air sourcekit references returned empty for queried compaction/OCR/form-fill symbols; do not interpret as no callers. T09 obtains a Pro indexed reference graph before changing exported owners.
- No new native app build, test suite, UI smoke or production deployment has been performed for the migration during planning. Those are future task transitions and must carry actual results.

### T00 execution authorized and isolated — 2026-10-06

- The user approved execution and integration of the complete plan. Production app replacement remains a separately approved transition.
- Reused `.worktrees/linen-migration-plan-20261006` with execution branch `feature/linen-upstream-migration`, based on current main `9606f9d4d14669798049f32c37aa8f8beab7e2c8`. Imported the completed planning documents as `4c074ba8a5386e94e5d1eb477081ae654fb1a524`; preserved original planning branch/commit `469d01d30428c704b7322cc0286ca5b24348675d`.
- Main delta beyond the researched `11ab647`: `7130832` adds the CI-gated website deployment, and `9606f9d` adds session-worktree/PR policy. These add no application source changes. Their workflow/configuration and README/changelog additions remain in scope to preserve, not overwrite.
- Isolation check: `git check-ignore -v .worktrees/ignore-probe/` returned `.gitignore:18:/.worktrees/`. `git rev-list --count 3c532ff33660f14b7ba4039cd924473de5f80b60..eb338d70bd1740a33e6a34f71e328e13d014bc42` in the pinned upstream clone returned **31**.
- Owned Pro snapshot: `/tmp/wsurf-linen-pdU0S7Ye/source`; reserved DerivedData: `/tmp/wsurf-linen-pdU0S7Ye/DD`. Initial source sync completed, excluding Git/worktrees/build output and execution scratch. Existing Pro source and builds are unchanged.
- Native toolchain rechecked on `PRO.local`: `/Applications/Xcode.app/Contents/Developer`, Xcode **27.0 (`27A266a`)**, Apple Swift **6.4 (`swiftlang-6.4.0.34.1`)**, arm64.
- No upstream implementation, app test, new build, merge or deployment is claimed by this preflight event.

### T01 native package/toolchain preparation — 2026-10-06

- Locked native resolution succeeded in the owned Pro snapshot with `xcodebuild -resolvePackageDependencies -project WSurf.xcodeproj -scheme WSurf -derivedDataPath /tmp/wsurf-linen-pdU0S7Ye/DD -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation -skipPackagePluginValidation`.
- Observed resolved graph includes AnyLanguageModel **0.15.1**, swift-collections **1.7.1**, CefSwift **59cad64e124b8efdb6b2ee811963097bb6e689e8**, MCP SDK **0.12.1**, GRDB **7.11.1** and all other required packages. No origin hash was fabricated.
- Pro's `xcrun metal --version` succeeded: Apple metal **32023.921**. The real acknowledgement generator produced **14 packages** from the resolved checkout directory, and only its generated `WSurf/Support/Acknowledgements.json` was copied back.
- The release/tip Metal baseline correction above was confirmed against canonical main. T01 also restores the missing `if [ -z "${!name:-}" ]; then` in tip's existing credential loop; the original unmatched `fi` is not a valid release gate. No signing/publishing action was run.
- These are package/toolchain/generation results, **not** an application build, native test result, stage verification or deployment.

### Compatibility wave native integration — 2026-10-06

- T01–T08 source ports and fork adaptations are present in the execution worktree, not yet committed or marked verified. T01/T03 and T08 scoped source reviews found no actionable defect. T02 review identified a bundled-Codex fixture that incorrectly assumed no global executable; the bundled lookup is now tested independently without changing production search precedence.
- Synchronized the complete source wave into the owned Pro snapshot. Native commands use Xcode 27, the frozen package graph, existing watchdog, disabled parallel tests, ad-hoc signing and 39 selected compatibility suites, including native OCR. `CFFIXED_USER_HOME` and `TEST_RUNNER_CFFIXED_USER_HOME` point to `/tmp/wsurf-linen-pdU0S7Ye/test-home`.
- First attempt, `compatibility-wave1.xcresult`: app compilation failed on an ambiguous `NSWorkspace` configuration initializer. The call now selects `NSWorkspace.OpenConfiguration` and the completion-handler API explicitly.
- Second attempt, `compatibility-wave2.xcresult`: app and test source compilation completed, but test-bundle linking failed on direct `cef_request_create` / `cef_response_create` calls. Those factories are not trampolined by the pinned CCef shim. The fixture now resolves the real factories from the already-loaded CEF framework, preserving actual native-object ownership and post-release assertions.
- Third attempt, `compatibility-wave3.xcresult`, is running after those corrections. **No native test pass, complete application verification, stage smoke, PR/merge or deployment is claimed by this event.**

### Compatibility wave result and dependent cutover — 2026-10-07

- `compatibility-wave9.xcresult` completed with **531 Swift Testing cases across
  38 suites and 6 BrowserPerformance XCTest cases, zero failures**. Earlier
  compile/runtime failures were corrected without lowering coverage or performance
  budgets. This selected compatibility result predates the atomic window cutover;
  it is not a current full-suite or stage-GUI pass.
- The built compatibility app was copied to an owned Air stage bundle and passed
  code-signature validation. Its real `--mcp` entrypoint passed split/coalesced
  initialize, object-valued experimental capabilities, tools/list, idle input and
  EOF with exit 0 and empty stderr. It used isolated stage paths, not production
  browsing data. Desktop control did not receive live approval, so no GUI launch
  or stage interaction is claimed.
- Native indexed references and the pinned upstream window inventory drove the
  T09–T15 source cutover. Window gates 1–19 stopped during compilation; their
  failures do not constitute runtime test passes. The current integrated source
  still needs its selected native gate, full suite, stage smoke and review closure.
  Implementation commits, PR, merge and deployment have not occurred.
- Fresh source review found queued transfer-state loss, background-window palette
  shortcut handling, stacked rate-limit retries, visual progress identity and
  form authorization/eligibility boundaries. These have focused regressions and
  are being resolved before any verification transition. Source review is not
  runtime reproduction.

### T16 catalog and documentation adaptation — 2026-10-07

- Merged the pinned per-commit catalog additions and two English positional
  translations rather than replacing WSurf's catalog. Removed obsolete entries
  only after checking live Swift consumers. Kept `Search with %@ in current tab`:
  WSurf's `OmniboxResults` still uses it, unlike the upstream palette.
- Rate-limit catalog keys follow the actual WSurf retry/pause strings; site-search
  accessibility keys and the Advanced reset's `are not affected` key are included.
  WSurf-only strings, branding and external Apple identity contracts remain intact.
- README/MCP/architecture now describe profile-owned windows, private context
  isolation, live same-context transfer, originating-window consent, guarded
  32-control batches, rate-limit pause, site-search keys and engine limitations.
  Removed superseded one-window and duplicate sidebar descriptions. One focused
  changelog entry links this journal rather than claiming 31 separate releases.
- Catalog/plist/link validation and actual stage presentation remain pending;
  these source edits do not advance the 31 manifest statuses.

### Integrated fork-boundary evidence — 2026-10-07

- Reconciled all **31 full upstream SHAs**, the **125-file T09 inventory** and
  every slice of the two mixed commits against the source ports. Compatibility,
  window-feature, profile-repair and native handoff-lifetime reviews are complete;
  their history/peek, ownership and origin findings were corrected. This records
  source-review coverage, not a substitute for the remaining runtime gates.
- Catalog validation observed **1,729 keys**. The existing local-document check
  resolved **27 links with zero missing targets**. Stage presentation of these
  strings remains unverified; the earlier T16 pending event is retained above.
- `FullSuite-wave40.xcresult` compiled the app and tests, but the suite failed.
  Its coverage gate passed at **50.97%** against the unchanged **24.0%** floor,
  all four native OCR integrations passed, and the six performance cases passed
  all twelve existing budgets through `Tools/check-performance.sh`. These are
  component results from that failed run, not a full-suite pass for current code.
- Subsequent native regressions cover WebKit/CEF document replacement,
  cancellation and grant revocation, live POST-backed tab transfer without
  reload, both owners' undo/session boundaries, and actual assistant/MCP
  mixed-control filling and owner retirement. The eight form consumers and
  automation/transfer suites passed in wave56; no authorization or sandbox
  guard was relaxed.
- `native-frame-lifetime-wave51.xcresult` exercised the CEF pending-navigation
  handoff fix: native frame/document epochs avoid renderer RPCs that Chromium
  suspends during pending top-level navigation. Shared asynchronous liveness
  still refreshes the frame tree. Source validation remains bound to the
  original tab, page, document epochs and requesting origin; ambiguous and
  opaque sources cannot obtain durable approval.
- Wave48 passed **64 tests across five MCP suites**, including two real accepted
  Unix-socket sessions and owning-window close/profile-switch revocation.
  A separate bundled `WSurf --mcp --mcp-socket <owned-unused-path>` smoke passed
  split initialize, object-valued experimental capabilities, coalesced
  initialized/tools-list messages, all **19 tools**, idle-input survival and
  EOF exit **0** with empty stderr. It did not use the production endpoint.
- `FullSuite-wave60.xcresult` passed strict lint and compilation but reached the
  unchanged twenty-minute watchdog while progressing. Its five issues were
  opaque CEF input, palette focus, an incorrect upstream close-tab expectation
  for WSurf's existing Unload Tab command, and two native consent-focus checks.
  The menu regression now exercises the real local page and native shortcut,
  requiring the retained unloaded row and an untouched other window.
- Waves62–64 each passed the complete palette-shortcut, native-menu,
  site-access-window and theme-picker suites. Wave64 still failed the opaque
  CEF fixture's **foreground/key-window prerequisite before any click**:
  test-host active false, hidden false, key false, frontmost bundle
  `io.wsagency.wsurf`. Native process/window diagnostics are in progress;
  no current full-suite, opaque-input or stage-UI pass is claimed.
- The user made Pro available but not Air desktop control. The current Air stage
  bundle therefore remains unlaunched. An independently signed old-app stage
  copy is prepared with an owned home, but it has not seeded a deployed-schema
  session or proved backup/old-app rollback. Installed app and production
  browsing data remain untouched.
- Implementation commits, PR/CI/merge and deployment are still absent. Manifest
  statuses remain `PLANNED` until real code commits are recorded, then advance
  independently from verification. Full native, Air stage/rollback and reviewed
  green-PR gates remain mandatory before integration; installation requires
  separate deployment approval.

### Opaque-frame native input verification — 2026-10-07

- `native-opaque-frame-focus-wave73.xcresult` passed strict lint, native app/test
  compilation and all **16 AppHandoffTests**, including all five unattributed
  source cases. The opaque case requires three independent trusted,
  user-activated link events from origin `null`; cancellation, one-time launch,
  rejection of unrelated remembered grants and empty persisted grants passed.
- The fixture focuses its real sandboxed child link through its existing
  postMessage channel, then sends the existing native Enter key pair. This
  avoids background-window mouse hit targeting and does not depend on the root
  DevTools frame tree exposing out-of-process children. Failed mouse attempts
  had reached the parent iframe element, before the permission path.
- Removed temporary input diagnostics and screenshot/native-mouse experiments.
  No production authorization, cross-origin automation guard, sandbox flag,
  input retry, timeout or CI budget was changed. Full-suite and Air stage/rollback
  verification remain separate gates; this is not a merge or deployment record.

### Implementation commit — 2026-10-07

- WSurf implementation **`e26850135fe0982616377af501a11e1a50112df1`**
  (`feat(browser): Integrate the pinned Linen migration`) contains all 31
  manifest entries and T01–T16 source/catalog/documentation changes. Its trailers
  record every full upstream SHA and every implementation task; this subsequent
  evidence record therefore advances all 31 entries to **APPLIED**, not VERIFIED.
- The commit includes the atomic T09 owner/caller/session/CEF cutover and all
  slices of `db8545929e0bb84d3f36e086c23a12ad197f6fd8` and
  `399715330a84b304251d3844188f2a53fd711cc0`. No planning-only source claim,
  partial mixed-commit verification or inferred PR/merge identifier is used.
- `FullSuite-wave74.xcresult` is running against this committed implementation
  with coverage enabled, all native OCR cases and unchanged watchdog/budgets.
  Air stage/old-app rollback remain unavailable; PR/CI, main integration and
  installation have not occurred.

### Hosted runner correction and draft PR — 2026-10-07

- Published source and its following attribution commit
  `465ce6dd3f9d43374c6e8dbff5853a011318343e` in
  [draft PR #8](https://github.com/wsagency/wsurf/pull/8). A fresh main fetch
  still resolved to the recorded `9606f9d` base; no main merge occurred.
- [CI run 37591047023](https://github.com/wsagency/wsurf/actions/runs/37591047023)
  failed before building: its `macos-26-arm64` image
  `20260907.0351.1` lacks `/Applications/Xcode_27.0.app`.
  Its [published inventory](https://github.com/actions/runner-images/blob/macos-26-arm64/20260907.0351/images/macos/macos-26-arm64-Readme.md)
  lists only Xcode 26.x. This is an observed runner mismatch, not an app failure.
- GitHub [documents `xcode-27`](https://github.com/actions/runner-images/issues/14404)
  as the ARM64 Xcode 27 runner. Its
  [image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
  `20260928.0222.1` includes stable Xcode **27.0 (`27A266a`)** and the required
  `/Applications/Xcode_27.0.app` alias. CI/release/tip now use this verified label,
  correcting the earlier unverified-label concern; the runner is still public
  preview, with its documented stability/capacity risk.
- Exact Xcode selection, package pins, Metal installation, test/OCR scope,
  coverage/performance/watchdog budgets and release authorization gates remain
  unchanged. No Xcode downgrade, fallback compiler, additional test exclusion
  or release/deployment execution was introduced.

### Native full-run evidence and remaining focus failure — 2026-10-07

- Runner correction commit **`568d8446f60f2dc1a07c447ab53571ac0d2363c6`**
  records `53fbb4c23337aeadc6e4c795cbbb0f6539e5c1bf` / T01 and changes only
  CI/release/tip runner labels plus their documentation. In
  [CI run 37591545970](https://github.com/wsagency/wsurf/actions/runs/37591545970),
  Xcode 27 selection, Metal, SwiftLint/format, package resolution and
  acknowledgements passed. A GitHub API read timeout interrupted the observer,
  not the CI job; observation resumed without rerunning the workflow.
- Native `FullSuite-wave74.xcresult` completed in **828.77 s** wall time with
  strict lint and compilation successful. Device-level results contain
  **3,015 passed, one failed and 12 existing disabled cases**; the invocation
  added no test exclusions. All four native OCR integrations and all
  `AppHandoffTests` passed, including the opaque-origin consent boundary.
- The sole failure was
  `CommandPaletteShortcutTests.backgroundPaletteCannotConsumeAnotherWindowsKeyboardEvents`
  at its active/key-window precondition. The subsequent keyboard-routing and
  source-palette assertions passed. The reported frontmost bundle identifier
  alone does not distinguish activation timing, window ownership or another
  process; instrumented diagnosis is in progress, not a claimed product fix.
- The actual coverage gate passed at **51.41%** against **24.0%**.
  `Tools/check-performance.sh` passed all 12 unchanged time/memory budgets from
  the six recorded native benchmarks. The run also recorded a non-failing
  QoS priority-inversion warning in `AppHandoffTests`; it was not suppressed.
- The full-suite gate remains **failed**, all manifest entries remain
  **APPLIED**, and Air stage/backup rollback, green CI and main integration
  are still required. No production app or browsing data was changed.

### Passing native/CI gates and isolated backup recovery — 2026-10-07

- Instrumented diagnosis run 75 passed all 39 tests in five suites;
  the observed application/frontmost PID and key-window transition matched.
  `FullSuite-wave76.xcresult` then passed: **2,700 Swift Testing cases in
  322 suites**, device-level **3,016 passed, zero failed, 12 existing disabled**,
  **724.54 s** wall time. Coverage was **51.36%** and all 12 unchanged
  performance budgets passed. The intermittent wave74 foreground precondition
  is not claimed fixed. Temporary logging was removed; failure-only PID/window
  details remain without weakening the original assertions.
- [CI run 37591545970](https://github.com/wsagency/wsurf/actions/runs/37591545970)
  passed every gate on `568d8446f60f2dc1a07c447ab53571ac0d2363c6` in
  **15m 4s**. The subsequent stage-seeding guard and diagnostic-only test change
  passed `FullSuite-wave79.xcresult`: **3,016 passed, zero failed, 12 existing
  disabled cases**, **851.11 s** wall time; no additional exclusions. Strict
  lint passed, coverage was **51.36%** against **24.0%**, and all 12 actual
  performance budgets passed. The same non-failing AppHandoff QoS warning
  remains visible. A fresh CI run is required for these final source changes.
- On the user's now-available Air, the actual old stage app created a local
  `WSurf Migration Marker` page, Favorite and pin. After native Quit, its
  consistent owned backup contained 12 tabs, one folder, 13 hierarchy items,
  18 history pages and 24 visits. No production browsing data was copied.
  Backup database SHA-256:
  `2e96884c16791c7d4bde90a6db2c9da33c2a2aab3e52088adc148c368552a423`.
- Initial upgraded-stage launch exposed a verification-harness defect:
  `StageRun` always replaced restored data after its delayed sample seeding.
  A DEBUG-only `WSURF_STAGE_SEED=0` opt-out preserves stage isolation and the
  default demo behavior. Native **StageSeed-build77** passed strict lint and
  whole-app build. Its complete copied/signed Air bundle retained the real
  Favorite, pin and marker page through launch, Quit and relaunch; fresh
  screenshots/AX confirmed them after the seeding deadline.
- Actual rollback used a separate copy of the **pre-upgrade** backup, never
  the upgraded database. **LegacyStage-build78** built exact old product/storage
  source `4d33cb93ed22a92ffa2db0d5fc8109b5e4a78557` with its original package pins
  and **only the same DEBUG sample-seeding opt-out**. This is an explicitly
  adapted old-version verification harness, not the unchanged installed binary.
  Its native Air launch displayed the restored marker/Favorite/pin.
- Read-only comparison confirmed all old tab IDs, titles, Favorites/pins,
  folder properties, hierarchy/order, history pages/visits and agent-table
  contents in both upgraded and restored-old homes. Comparison accounts for
  the existing old/new folder-ID remapping and native page-state reserialization.
  `Downloads.json` remained byte-identical in all three homes, SHA-256
  `31d8a97881d9e2c2af16124520ce6ec17cd72271ced627bc1cb4ec83a8cb726a`.
  The new home has window tables; the old home retains the old schema.
- Air native smoke verified `abc` → `ab` from exactly one trusted Backspace
  despite consumed keyup in both WebKit and Chromium, first focus on the
  animated WebKit login fixture, and actual HTTP-port favicon rendering.
  The CEF helper rendered the same fixture with Chrome 154 and played the
  owned silent audio fixture. Synced lyrics visibly advanced; pause, hide,
  Back and Forward retained paused playback. No credentials were accessed.
- Both native PDF viewers displayed the response filename
  `Owned Stage Document.pdf` from a URL without a PDF extension. Chromium's
  native Download saved into the selected owned stage home and appeared in the
  shared-profile second window's Downloads list. Its Downloads header Back
  action returned to the original Settings category. WebKit edited Save/Preview
  and the rest of the window matrix are still being exercised.
- The complete Air feature/window matrix and final clean-source/CI gate remain
  open. PR #8 is still draft; nothing has been merged or deployed.

