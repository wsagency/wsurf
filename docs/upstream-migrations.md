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

At initialization: **30 PLANNED; 1 ALREADY_EQUIVALENT**. No migration implementation, new application verification, PR, merge or deployment is claimed by this journal.

| # | Full upstream commit | Original subject | Task(s) | WSurf adaptation | Status |
|---|---|---|---|---|---|
| 1 | [`791a5487203677e5cceadd0b1c17c172c62acd49`](https://github.com/kavoye/linen-browser/commit/791a5487203677e5cceadd0b1c17c172c62acd49) | fix(mcp): Detect the bundled Codex CLI and update integration tests | T02 | Add nested ChatGPT Codex path; retain WSurf config identity and safe TOML merge. | PLANNED |
| 2 | [`fe1d5dc034c1fa780eff2dcd1a7dbba3e670c168`](https://github.com/kavoye/linen-browser/commit/fe1d5dc034c1fa780eff2dcd1a7dbba3e670c168) | fix(palette): Preserve editing shortcuts across keyboard layouts | T08 | Native layout-aware editing shortcuts; preserve WSurf menu and palette ownership. | PLANNED |
| 3 | [`4ea5d3545fd4284b6f52c50f51fe0b0936dde04c`](https://github.com/kavoye/linen-browser/commit/4ea5d3545fd4284b6f52c50f51fe0b0936dde04c) | fix(autofill): Wait for focused fields to finish layout | T03 | Port bounded focus/layout settling and cancellation; retain WSurf WebKit autofill bridge. | PLANNED |
| 4 | [`b3bc2effad8db625ab32a8400776dfd2478b6f82`](https://github.com/kavoye/linen-browser/commit/b3bc2effad8db625ab32a8400776dfd2478b6f82) | fix(media): Stop polling idle players and hidden pages | T04 | Adapt visible-playing/BFCache behavior to WSurf already-event-driven media script; no unconditional polling. | PLANNED |
| 5 | [`2c3eee541984de91aca0cc5ec33326ab577553e6`](https://github.com/kavoye/linen-browser/commit/2c3eee541984de91aca0cc5ec33326ab577553e6) | fix(tabs): Show PDF filenames and correct untitled page titles | T05 | New Page/Start Page distinction and response PDF names; add real CEF main-frame response bridge; retain custom titles. | PLANNED |
| 6 | [`b06f891be98f9574eb5292312319db7b1530d96c`](https://github.com/kavoye/linen-browser/commit/b06f891be98f9574eb5292312319db7b1530d96c) | feat(permissions): Remember external app approvals by website | T06 | Origin+app approvals in existing SitePermissions; private session-only grants; real WebKit/CEF source provenance. | PLANNED |
| 7 | [`3007d94feae184f2f0e6cd3a6c5b4b67b5358768`](https://github.com/kavoye/linen-browser/commit/3007d94feae184f2f0e6cd3a6c5b4b67b5358768) | fix(downloads): Save PDF viewer documents through download manager | T05 | Save WebKit viewer bytes via existing manager/reservations/quarantine; preserve handoff dedupe and CEF native download capabilities. | PLANNED |
| 8 | [`3fdb775df616da29ee4a65a0e2e4cc314e94e428`](https://github.com/kavoye/linen-browser/commit/3fdb775df616da29ee4a65a0e2e4cc314e94e428) | fix(settings): Open the Downloads page from download settings | T08 | Open actual Downloads content from settings/search; keep actual page clear/cancel/open/reveal actions. | PLANNED |
| 9 | [`2fe070a35d9021678855a0b6bac04a65140505d3`](https://github.com/kavoye/linen-browser/commit/2fe070a35d9021678855a0b6bac04a65140505d3) | chore(localization): Refresh remaining catalog entries | T16 | Selective catalog refresh after features; retain WSurf-only keys and branding. | PLANNED |
| 10 | [`498d2327c463f3442c4695a4c1beb3c7a144385b`](https://github.com/kavoye/linen-browser/commit/498d2327c463f3442c4695a4c1beb3c7a144385b) | fix(settings): Keep reset copy consistent with the string catalog | T08 | Advanced global reset catalog/copy consistency, not theme-reset behavior. | PLANNED |
| 11 | [`f0eba22e9a090d607bd35de006a1b9f719bc1a74`](https://github.com/kavoye/linen-browser/commit/f0eba22e9a090d607bd35de006a1b9f719bc1a74) | test(agent): Keep context fixture titles stable while pages load | T01 | Stable explicit context fixture titles and HTTP server lifetime; keep WSurf behavioral assertions. | PLANNED |
| 12 | [`c1e874d3f3e6c6f9d9b6eddfd16eda3b3ec1a1c2`](https://github.com/kavoye/linen-browser/commit/c1e874d3f3e6c6f9d9b6eddfd16eda3b3ec1a1c2) | test(web): Use real WebKit actions for external navigation | T06 | Real loaded-page WKNavigationAction tests with actual requesting origin, not fabricated action objects. | PLANNED |
| 13 | [`a05a57708fe66e4dea4710015532fb3900b8e471`](https://github.com/kavoye/linen-browser/commit/a05a57708fe66e4dea4710015532fb3900b8e471) | test(performance): Isolate result ranking from WebKit page loads | T01 | Ranking measures metadata-only projection, not page loads; retain WSurf performance budgets. | PLANNED |
| 14 | [`90e222bf96106ea6ea3844f82afa9f686d81be6f`](https://github.com/kavoye/linen-browser/commit/90e222bf96106ea6ea3844f82afa9f686d81be6f) | fix(web): Preserve restored scroll positions across late WebKit resets | T07 | Bounded late-zero scroll restoration; yield to input/pagehide/nonzero page scroll; shared BrowserPage path. | PLANNED |
| 15 | [`9b59c8351c6890e9a29ac962704199cda98ee2ae`](https://github.com/kavoye/linen-browser/commit/9b59c8351c6890e9a29ac962704199cda98ee2ae) | test(extensions): Wait for replies from the expected page | T01 | Filter extension replies by expected page and required result prefixes; retain native controller/lifetime isolation. | PLANNED |
| 16 | [`ce63cda705780ace77a2d0c5f1c85800970da3c3`](https://github.com/kavoye/linen-browser/commit/ce63cda705780ace77a2d0c5f1c85800970da3c3) | test(web): Keep headless automation fixtures active | T01 | Active headless WK configuration reused by existing fixtures; production scheduling unchanged. | PLANNED |
| 17 | [`2fe08fe3b63a1162d600298eba15577647298357`](https://github.com/kavoye/linen-browser/commit/2fe08fe3b63a1162d600298eba15577647298357) | fix(agent): Verify keypress delivery on trusted keydown | T03 | Trusted keydown delivery acknowledgement, no retry for absent/consumed keyup; retain engine adapters. | PLANNED |
| 18 | [`53fbb4c23337aeadc6e4c795cbbb0f6539e5c1bf`](https://github.com/kavoye/linen-browser/commit/53fbb4c23337aeadc6e4c795cbbb0f6539e5c1bf) | Update CI to Xcode 27 and upgrade stable dependencies | T01 | Xcode27/SwiftLint/actions/locked resolution/ALM+collections and API changes; retain CefSwift/release gates, use supported WSurf runner with explicit preflight. | PLANNED |
| 19 | [`f46c5917d55d1b0a96d43fa378dce3d87b6ca51c`](https://github.com/kavoye/linen-browser/commit/f46c5917d55d1b0a96d43fa378dce3d87b6ca51c) | chore: update README.md | T16 | README clarity/privacy updates in WSurf terminology; final multiwindow state supersedes historical one-window copy. | PLANNED |
| 20 | [`853ce9b56f760d8ac1e7abbb63e2de339c8a6951`](https://github.com/kavoye/linen-browser/commit/853ce9b56f760d8ac1e7abbb63e2de339c8a6951) | Install Metal toolchain before CI builds | T01 | Same MetalToolchain installation/version probe already exists in all three deployed WSurf workflows; retain, do not duplicate. | ALREADY_EQUIVALENT |
| 21 | [`231d2ece0c2cb75d4f10a8c92c9709276edb743e`](https://github.com/kavoye/linen-browser/commit/231d2ece0c2cb75d4f10a8c92c9709276edb743e) | Fix OCR and autofill tests on virtual macOS runners | T01 | CoreML CPU OCR fallback and active autofill fixtures; real OCR remains enabled on native Pro. | PLANNED |
| 22 | [`4367b14443831e114a30aa719efa6f1c16a3c984`](https://github.com/kavoye/linen-browser/commit/4367b14443831e114a30aa719efa6f1c16a3c984) | Exclude unsupported Vision OCR tests from hosted CI | T01 | Only four unsupported hosted Vision OCR integrations excluded; no native Pro exclusions or lowered coverage. | PLANNED |
| 23 | [`c616faf5ab6974040570173a5cfba2dcf8baa1c8`](https://github.com/kavoye/linen-browser/commit/c616faf5ab6974040570173a5cfba2dcf8baa1c8) | fix: Improve folder preview icon contrast in dark mode | T08 | Gray folder preview secondary tint; preserve colored previews and WSurf sidebar layout. | PLANNED |
| 24 | [`3578dc201402767b433d994dd40aedd3099f26ce`](https://github.com/kavoye/linen-browser/commit/3578dc201402767b433d994dd40aedd3099f26ce) | fix(mcp): Accept object-valued experimental capabilities | T02 | Normalize only object-valued initialize.experimental at inbound SDK boundaries; standard fields/grants unchanged. | PLANNED |
| 25 | [`cd1575134efaac800dda7bac92dcc862d394b43e`](https://github.com/kavoye/linen-browser/commit/cd1575134efaac800dda7bac92dcc862d394b43e) | feat(windows): Add profile-aware browser windows | T09 | Atomic registry/context/session/caller cutover; extend CEF context identity/lifetime and engine preference fanout; retain Favorites, pinned folders, sidebar undo and trust boundaries. | PLANNED |
| 26 | [`25bffb9b1ddc9d4b20146c6d55b1637fc739f548`](https://github.com/kavoye/linen-browser/commit/25bffb9b1ddc9d4b20146c6d55b1637fc739f548) | fix: Show assistant questions only where the request started | T10 | Questions bound to original window/space and chrome-versus-inspector surface. | PLANNED |
| 27 | [`db8545929e0bb84d3f36e086c23a12ad197f6fd8`](https://github.com/kavoye/linen-browser/commit/db8545929e0bb84d3f36e086c23a12ad197f6fd8) | fix: improve form filling and rate-limit recovery | T11, T12 | Shared 32-field guarded batch and exact verified refs; bounded rate-limit generation recovery, no action replay, summary-free pause and visual no-progress. | PLANNED |
| 28 | [`399715330a84b304251d3844188f2a53fd711cc0`](https://github.com/kavoye/linen-browser/commit/399715330a84b304251d3844188f2a53fd711cc0) | fix: Reduce idle work and correct startup behavior | T02, T03, T04, T09, T13 | All slices: DispatchIO stdio; cached synchronous speech; visible-playing synced lyrics; finite geometry; URL-aware favicons; privacy-safe autofill diagnostics/frame tests; WebKit+CEF lifetime. | PLANNED |
| 29 | [`b1d76114b6f4250fa6c4d30c6b18d2be650ea8e2`](https://github.com/kavoye/linen-browser/commit/b1d76114b6f4250fa6c4d30c6b18d2be650ea8e2) | fix(sidebar): Keep drop targets visible on light websites | T08 | Drop target follows sidebar surface, not forced website color scheme; keep WSurf Favorites/pin typography. | PLANNED |
| 30 | [`56880f2994cefcb38944f065894c98569178c653`](https://github.com/kavoye/linen-browser/commit/56880f2994cefcb38944f065894c98569178c653) | feat(palette): Add Tab-to-search site chips | T14 | Site match/chips/native editor safeguards and glass sizing; reuse SearchEngine and WSurf palette style. | PLANNED |
| 31 | [`eb338d70bd1740a33e6a34f71e328e13d014bc42`](https://github.com/kavoye/linen-browser/commit/eb338d70bd1740a33e6a34f71e328e13d014bc42) | fix(window): Limit Dock menu page titles to 40 characters | T15 | Limit native displayed page title to 40 grapheme clusters; preserve full stored tab title and profile/private suffix. | PLANNED |

## Baseline equivalence evidence — 853ce9b

**Disposition:** ALREADY_EQUIVALENT at WSurf baseline `4d33cb93ed22a92ffa2db0d5fc8109b5e4a78557`; do not attribute a new port commit.

- `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/workflows/tip.yml` already run `xcodebuild -downloadComponent MetalToolchain` then `xcrun metal --version` before builds.
- Evidence: direct deployed-source workflow inspection; CI workflow lines 38–41 contain the exact commands. This proves configured equivalent behavior, **not** a new green hosted workflow run.
- T01 keeps the steps, documents native/toolchain setup and rechecks workflow integration after upgrades. Record its later runtime result separately.

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
