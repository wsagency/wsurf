# Current-main credential integration

> Execution continues with subagent-driven-development under Main orchestration; this is the current-main integration appendix to the approved credential plan, not a new product design.

**Goal:** Carry only the approved credential feature onto latest merged main without reverting multiwindow, profile, CEF or Stage isolation work.

**Spec:** docs/superpowers/specs/2026-10-05-profile-credential-manager-design.md

**Parent plan:** docs/superpowers/plans/2026-10-06-profile-credential-manager.md

**Status:** Planned; no integration worktree or port created yet. Old source worktree remains active until explicit freeze/handoff. PR metadata establishes merged changes, not our runtime acceptance.

## Global constraints

Preserve legacy SavedPassword/SecureAutofillVault/settings/autofill/data and default provider; separate explicitly selected encrypted manager. Native PRF and six Apple transfers remain late gates. No fake production keys/fallback. No UI/Stage launch while task control remains declined. No main checkout edits, branch switch in shared worktree, stash/reset, wholesale old-branch merge, commit/push/release/deploy. Preserve all dirty source and existing Pro output. Peer reconciliation remains blocked by Mail auth, not assumed agreed.

## Review focus

Native originating page.context owns profile/settings/provider; no active-window/global-profile substitution. Same-profile windows share one vault; other profiles and private contexts cannot access it. Lifecycle cancellation must reach retired pages and affected vaults without returning to global single-window architecture. Native document identity and effective policy remain authoritative after all awaits. Keep merged StageMode per-home identity/defaults/WebKit/MCP isolation. Import destination/profile and in-flight exchange state must not silently follow focus changes.

## Sequence

- [ ] Freeze complete Task9 Registry/context/driver and consumer relay contract, including unchanged dependencies; runner verifies one 72-path-or-expanded current manifest. Run the exact observed RED7 method once after the correction; compilation/setup failures are not GREEN. Preserve baseline MCP no-WebAuthn BFCache main+HTTP-child behavior, stale-resume refusal and retirement cleanup.
- [ ] Complete Task10 privacy/error/concurrency corrections and read-only review; distinguish synthetic tests from real UP/UV.
- [ ] Main authorizes fresh dedicated feature/<short-name> integration worktree based on newly fetched origin/main. Record exact base and owned Air/Pro paths; preserve old Air canonical candidate and Pro build mirror. Do not reuse another worktree's build directories. This task is source integration, not PR merge.
- [ ] Inventory credential-owned new files and semantic deltas against the approved parent baseline 9606f9d4d14669798049f32c37aa8f8beab7e2c8 and frozen candidate; exclude unrelated historical pin/test repairs. Do not copy old shared files wholesale. Query LSP references before symbol/interface changes.
- [ ] Port independent credential models/crypto/TOTP/exchange codecs and extension target onto current main. Preserve main deployment floor and SDK availability. Native provider registration remains unproved.
- [ ] Native owner ports BrowserPage/BrowserFrame/PageFrameRegistry/PageDriver/WebAuthnContext, lifecycle delegates and CEF effective-policy/final-dispatch checks; preserve current-main window/context ownership and transport. Consumer owner ports Task8 autofill and Task10/11 ceremony/relay/adapters using page.context.profile/settings and existing main conventions. No shared-file concurrent edits.
- [ ] Main owns lifecycle/settings/activity/project integration: reuse BrowserProfileContext.shared(for:), BrowserApplication.coordinator(for:), per-window AppCoordinator and Settings context. Shared per-profile CredentialManager must not depend on global active profile. Hook lock/retire/delete/termination at the actual new ownership boundaries; keep legacy paths intact. Existing BrowserApplication.activeCoordinator has fallback and is not foreground evidence. Resolve native foreground policy from current-main APIs; never guess NSApp key-window timing around sheets.
- [ ] Freeze complete current-main candidate, sync only owned sources to owned Pro integration worktree, use local DerivedData/SourcePackages. Run focused changed-path checks, relevant profile/window/legacy/MCP regressions, then one combined required gate with external stall sampling. Capture exact logs/source manifest. No repeated green hunting or whole-suite serialization.
- [ ] Run an actual-source synthetic smoke of the ported store/codec/ceremony boundaries. Real Settings/Stage restart/WebAuthn/PRF/six transfer acceptance remains blocked until fresh interactive approval; report each unperformed gate separately. Update docs/changelog only after exercised proof and remove throwaway scaffolding.
- [ ] Independent integration review; only after all required acceptance/review/CI may a scoped PR target main. No deployment authorized by this appendix.

## Known merged contracts

PR #8 (30069a194562057d65a2c56daaf72b4578eb5a2a) introduced BrowserApplication, BrowserProfileContext and per-context autofill. PR #10 (350de9362d09d7115517dfec865db08ae6121ae6) preserves password/payment/autofill vaults while fixing classic provider Keychain scope and per-home Stage isolation. PR #11 modifies BrowserTab/engine presentation. Re-fetch origin/main before creating the integration worktree; these references are not asserted latest remote HEAD.
