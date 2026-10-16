# Linen upstream research: curated handoff (2026-10-16)

Static reading of Git objects and GitHub API data, plus small native component probes (section 6). **No whole-app build, Xcode test suite or UI verification backs anything below.** Claims marked **source** come from reading files; **native** means a probe in section 6 measured it.

## 1. Pinned state

| Item | Value | Link |
|---|---|---|
| Upstream `kavoye/linen-browser` main | `62e5c0571a908f775d50ae53c9e2da2fb178db56` (committed 2026-10-14T09:09:34Z). Identical to this SHA on re-check 2026-10-15T22:13Z: 0 new commits, only branch `main`, no upstream-authored PR or issue. | https://github.com/kavoye/linen-browser/commit/62e5c0571a908f775d50ae53c9e2da2fb178db56 |
| Latest upstream release | `v0.8.0` = `4b6d2203db4b55557798cae5839847ded98a2830` (2026-10-08); `tip` is a rolling prerelease that points at `62e5c05` | https://github.com/kavoye/linen-browser/releases |
| Last integrated pin (PR #8) | `eb338d70bd1740a33e6a34f71e328e13d014bc42` | https://github.com/wsagency/wsurf/pull/8 |
| Range since the pin | `eb338d7..62e5c05` = 82 commits: 40 up to v0.8.0, 7 after the tag up to `16c58005a589946d21b039fa1aa51fcc88ed8daa`, 35 after that | https://github.com/kavoye/linen-browser/compare/eb338d70bd1740a33e6a34f71e328e13d014bc42...62e5c0571a908f775d50ae53c9e2da2fb178db56 |
| WSurf main when I last read it | `9f4b515` (PR #24, brand docs), after `7b99516f9b620bebe5a3e01efd875800237aca06` (PR #20) | https://github.com/wsagency/wsurf/commits/main |
| Integration branch | `feature/main-integration-20261015` at `a98f51f9f0fbb2360f075fe6ebe3016b1de56104`, pushed, 66 commits ahead of `7b99516` at the check. Not merged; native acceptance still pending. | https://github.com/wsagency/wsurf/tree/feature/main-integration-20261015 |

Before any new intake, re-check Linen main against `62e5c0571a908f775d50ae53c9e2da2fb178db56`.

## 2. Already covered remotely (links only, not repeated here)

- 0.8.0 intake dispositions for all 40 commits, the post-tag MCP rows and the one outbound candidate: `docs/upstream-migrations.md` on WSurf main, section "Linen 0.8.0 intake proposals" (PR #12 added the process).
- Inbound backports in open draft PR #21 (`f1f16a010a021df76c46f5c56ba4e963147ce68b`): Linen `3d0903d4218839cfba4df4e120cbcd7c7fa080ae`, `ebb66e95278ce2f1ddabb12dc3762a2989c5e1de`, `c0afef30cb8720d8a517b72827a47c636ff8540e`. https://github.com/wsagency/wsurf/pull/21
- AnyLanguageModel 1.0.0 bump: PR #22. https://github.com/wsagency/wsurf/pull/22 . MCP development mode: PR #23. https://github.com/wsagency/wsurf/pull/23
- Retired window key: PR #15 (merged), covers `register`/`unregister` of Linen `e478979`. https://github.com/wsagency/wsurf/pull/15
- Five pushed inbound branches, each implementing one group from my design briefs (no need to redo the briefs): wheel-aware pull refresh `6f1deaea3b447fe01dd8f3e862d5982567613112`, page tools `182a9d36f696570fd07740109da583c7b3e128e4`, UI polish `10dded87b5de23370ff37aee39bcde7d8a57f9fa`, address-field site search `593ffd7d89a887e4e73709706ebd50493d3f9383`, on-device images `813a4b46b585c9d53cfb20522e439a48e2788295`. Names: `feature/linen-{wheel-refresh,page-tools,ui-polish,address-search,device-images}-20261014` at https://github.com/wsagency/wsurf/branches
- Outbound WSurf to Linen draft PRs, open, zero reviews or comments at the last check: #3 PageReply caller cancellation, #4 stage-home isolation (DEBUG only), #5 privacy-test owned permissions file. Closed by us 2026-10-14T16:51:51Z, not merged: #2 iCloud Passwords startup. https://github.com/kavoye/linen-browser/pulls?q=is%3Apr
- Credential, CSV, brand, CI-isolation (PR #18) work is out of scope here.

## 3. Still open: inbound candidates (unique to this research)

Order is my recommendation. None is approved or started. All are small; each needs its own branch after native acceptance of the integration branch.

1. **Linen `d204703af978e65e2e7e8da4a17873d8fe520bf8`, update-approval half only.** In `WSurf/Extensions/ExtensionUpdates.swift` the quiet-update guard (`asksForNothingNew`) and the manual `accepts` check compare only `requestedPermissions` (API permissions). Host access lives in `allRequestedMatchPatterns`, and `ExtensionManager.swift` grants every requested pattern when a context loads. **Native:** for MV2 and MV3 manifests, changing a host from a specific one to `<all_urls>` leaves `requestedPermissions` unchanged, so the guard accepts it. **Source only, not reproduced:** the end-to-end effect (an update reaching `replacePackage` and the new host being granted). Do not describe it publicly as a vulnerability; for any upstream report use Linen's private advisory route (SECURITY.md). Plan: about 60 lines, add upstream's `access(in:beyond:)` idea (API permissions plus match patterns, minus the approved package), refuse quietly on any addition, and ask through the existing `ExtensionConsent.confirmRuntimeGrant` with only the added access. Reuse its copy and signature unchanged. Do not take per-site blocking, held-update UI or the context-menu split from the same commit. Do not add persisted held-update state.
2. **Linen `447c02bbcf7b5ab685e8f131f62c126792060e01`, full field values.** **Source:** `PageRuntime.swift` truncates control values and selected option text to 30 characters without a flag, and `inspectControl` returns a value only for range/color/date/number-type inputs, never for text. Claim is limited to those two outputs. Upstream uses 100 characters with a truncation flag and an `inspectControl` that pages `value`, `valueLength`, `nextOffset`. Conditions for a port: keep the sensitive-field redaction in front of both branches, keep the output budget (`PageOutputBudget`: 2400 text, 40 controls, 6000 total on main at the check; the size effect is unmeasured), never simply raise or drop the 30-character cut, and keep the frame cap (262144 bytes) in mind. Take it only after PR #23 and the page-tools branch are merged and re-diff. Tests should assert behavior (value returned, sensitive field hidden, long value pages), not exact strings.
3. **Linen `b6b33f2083022bde5dedb17f8d0c32fe30f6b71c`, locale percent.** `AssistantContextIndicator.swift` lines 52 and 87 use `\(percent)%`. **Native:** Foundation formats 0.5 as `50%` in en_US and as `50` + NBSP + `%` in fr_FR and hr_HR, regardless of UI language. WSurf's behavior under a non-US region is untested. Trivial isolated tidy-up using `.formatted(.percent)`.
4. **Low value, optional:** `ea1efe3b8bdcbd017df8ae3f3f0549b8fdb10514` (activity glyph and cancel for tab organizing; WSurf's organize `Task` in `AppCoordinator+Windows.swift` is unstored and `stopAgent` does not cancel it; port is not mechanical because of window/profile guards) and `9eefe377c30bd6bee704d2367a8fce8814cbd105` (show the MCP config after copy; about 30 lines in `MCPSettingsPage`; the config has no token).
5. **Linen `e47897970dfc6e4a507e243f8b694975d6143994`, remaining hunk.** Lookups in `ExtensionManager+Windows.swift` can return a stale adapter until `register` runs. Needs a reused `ObjectIdentifier`; WebKit-only; no known trigger.

## 4. Deferred, held or rejected (with reason)

- **Deferred, needs evidence:** `16c58005a589946d21b039fa1aa51fcc88ed8daa` ("NEW ON PAGE" revealed text; adds up to 800 characters per observation and per-runtime state; take only after a measured miss). Deferred half of `fac4fa1e74c45888c866462efa8c0b6d23147fe2` (instruction and schema token accounting): `ContextBudget.swift` has `compact ? 300 : 1_300`; no measured failure. If on-device acceptance shows an over-budget refusal or a compaction loop, first log the real compact instruction length against the 300 guess; at most add a measured-instruction-tokens accounting change. Never take from that commit: removing outcome tools, `tracksOutcomes`, `requiresOutcomeVerification = false`, catalog `isCore` changes, compact tool descriptions.
- **On-device window read** (`62e5c0571a908f775d50ae53c9e2da2fb178db56`): main hard-codes 4096 for the system model in `ContextWindow.resolve`. Optional bounded change: read `SystemLanguageModel.default.contextSize` at that seam, keep configured overrides first, fall back to 4096 on zero or unavailable. Check whether the device-images branch already covers it before doing anything.
- **Held (product decisions or conflicts):** `3ad0cf61ee084103bbe6e98f69881f485c2d1090` unified Pages list (about 600 lines; conflicts with the address-search branch); `0aa66316` settings subpage addresses (about 700 lines in 16 files) and `54245971` hidden-setting row highlight; `89800b27ec2001f2e04ede8a7ed2b7eaacc8c78b` copy checkmark (defer until address search lands); `7967c3e9` folder auto-naming (races WSurf's immediate rename); `99e6a35` Minimal window style; `12f97864` Duplicate Tab (WSurf already has it, and Shift-Command-D is Back to Pinned Page); `86a159e7` side-panel tab scrolling (no GitHub integration in WSurf).
- **Blocked by absent WSurf features:** Reader, Archive tabs, Translation and their follow-ups (`6ce93686`, `8127807`, `e335e9ac`).
- **Rejected:** `b17c9ffd` (deletes code WSurf uses), `b183aa84` (feature-first layout; path map only), `8d5b33ec` (Watches), `76c0873` (WSurf has its own onboarding), `a8448eb` (no switcher).
- **Post-0.8.0 MCP page tools:** `70c3c576` scope matches all elements, `78b76dee` screenshot byte cap and `59c396de` unlisted-ref message are implemented on the pushed page-tools branch (section 2; commits `d0c5dd9`, `cba0fcb`, `86f20aa`, review fixes through `182a9d3`; confirmed by reading the branch diff, not by running it). `447c02bb` and `16c58005` are not. Merge order after PR #23 is for the PR owners. When re-checking: the screenshot cap must apply only on the MCP path, computer-use frames must never be shrunk, and crop scale must use the final encoded pixel width.

## 5. Outbound candidates not proposed

- **Download-manager duplicate-handoff guard** (WSurf `e6362ec0329f29d3df04f169da1d8e1feffbd134`, mixed commit; take only the guard and its test). **Hold.** No upstream caller adopts one download twice; propose only after a real double handoff reproduces. Write fresh, do not cherry-pick.
- **Window-scoped consent sheets** (private window or profile). **Hold, needs a two-window reproduction on upstream and user approval; private advisory only, no public issue or PR.** Upstream chooses `NSApp.keyWindow ?? NSApp.mainWindow`; WSurf scopes the sheet to the action's window via `AgentActionConsent.scopedWindow`. A neutral patch also needs a registration check upstream lacks.
- **Reasoning-retention policy** (PR #22 `settledTranscript`). **Hold.** Policy question; do not propose removing replay. Unverified: provider requirements for reasoning items and what opaque metadata is.
- **Rejected for upstream:** MCP stdio transport cancel hook (no leak shown upstream); my earlier "PageReply view retention" claim (invalid: Linen already uses WKWebView's native completion API; that fix is WSurf-only).
- Limits that must stay attached to outbound PR #4: the stage per-home data store covers only the default profile; private profiles use non-persistent stores; other profiles keep their own IDs; keychains and `UserDefaults.standard` are not isolated; identity is the path as spelled after `..` normalization. Outbound PR #5 makes one suite's constructors owned; it does not isolate the whole test host. For all three outbound PRs, only CLT component smokes and lint were run. No native Xcode run exists.
- Do not describe an upstream fixture as "writing the real file": only a read of production state plus directory creation was shown.

## 6. Native probes (2026-10-15, macOS 27.0 arm64, Swift 6.4 CLT, synthetic data only)

- `WKWebExtension` built from synthetic MV2 and MV3 manifests (old host `https://old.invalid/*` to new `<all_urls>`), constructed via `WKWebExtension(resourceBaseURL:)` only: `requestedPermissions` stays `["storage"]`, while `allRequestedMatchPatterns` changes. Nothing was loaded into a controller or granted. Not tested: other permission names, `optional_*` fields, the real update flow.
- Foundation percent format of 0.5 by explicit locale: en_US `50%`, fr_FR and hr_HR `50` + U+00A0 + `%`.
- PageReply (earlier probe): upstream `PageReply.swift` at `62e5c05` (sha256 `1cc2f718859e747200486ca111be6508a5951e5a8323579107a8ccdb907b13e3`) returned a cancelled caller after about 2.0 s against a 30 s ceiling, which motivated outbound PR #3. Not a native Xcode test.

## 7. Limits

- Upstream CI and Actions were not inspected. Nothing was reproduced in the apps.
- PR #21, #22, #23 conflict cause with PR #20's `CHANGELOG.md` was inferred, not read. Their owners reconcile.
- Process note: upstream CONTRIBUTING requires a regression test per fix, Conventional Commits, full suite and `Tools/check-format.sh` before any PR. Any new upstream PR needs explicit user approval. Keep Apache-2.0 SPDX headers in upstream files.
- The raw research artifacts are local and ignored by Git and were not pushed. This curated summary is the published copy (committed on `feature/branch-handoff-20261016`).
