# WSurf DevOps handoff

Verified 2026-10-16. Keep this document with the WSurf source at `docs/devops-handoff.md`. It gives the project operator the native build/signing, installation, CI and website contracts without requiring a second DevOps checkout. Machine paths and inventory counts below are dated observations, not permanent assumptions.

**The Air-to-Pro source copy is complete and non-destructive.** The new Pro workspace contains the full checkout, existing linked worktrees and local-only assets. The fresh source-transfer backup choice was explicitly **no additional backup**; the Air originals remain intact. The earlier no-backup exception covered one Air application replacement only and was not reused as source-transfer approval.

## 1. Where the project and builds actually are

### Air source and Pro source custody

- Canonical Pro workspace: `/Users/klukacin/projects/development/wsurf`. It now contains the full Air primary checkout and sibling worktree root, copied non-destructively.
- The primary checkout was copied at HEAD `9606f9d4d14669798049f32c37aa8f8beab7e2c8`. This is the transferred source revision, not automatically the latest release source. The owner reports all branches committed and pushed; this is accepted as an owner report, not independently audited here.
- Preflight inventory recorded 56 worktree records: 55 existing and one historical missing record at `/tmp/wsurf-pr2-integration-20261006`. The missing record is retained unpruned for review only. Earlier counts of two primary modifications, seven dirty worktrees, one stash entry and upstream-behind status are historical and superseded; do not treat them as current state.
- The Air sibling root is embedded at `newroot/.worktrees/external-air`. Its ten existing sibling-linked worktrees were copied; preserve all other sibling-root content as well. Primary-internal `.worktrees` and `build/sidebar-customization` remain in place. Do not assume `build/` is uniformly disposable.
- The complete native macOS tar payload travelled directly from Air `192.168.0.203` to Pro `192.168.0.8` over LAN. Verification covered 325,662 entries and 36,801,824,826 logical regular-file bytes: every file hash, object type, symlink target, permission mode and UID matches the source. The source-before/source-after manifests matched; the approved Pro-copy verification passed at `2026-10-16T15:59:40.593330Z`. Hidden, private, ignored and historical assets were included.
- **Owner-approved native metadata:** retain Pro group `staff` for 4,681 entries originally using `wheel`/`admin`, retain 854 native Pro quarantine values, and retain native provenance on two restored empty historical lock files and the two exclusively moved source-root directories. These are documented metadata differences, not missing source or Git data. The new parent directory is private `0700`; no sudo, quarantine removal, Keychain/TCC/ACL change or global security-policy change was used. Do not claim a bit-identical copy of all original host-security metadata.
- Origin: `git@github.com:wsagency/wsurf.git`; upstream fork source: `https://github.com/kavoye/linen-browser.git`. The full local Git database, branch/tag refs, stash/reflogs, indexes and uncommitted/untracked worktree files were migration inputs. A fresh clone/pull is not a lossless migration.
- **Existing Git warning:** the copied source retains `refs/remotes/upstream/HEAD` with an invalid target. Native `git fsck --connectivity-only --no-dangling` returned `2` with that one reported ref error; this is not a clean Git-health result. The ref/database bytes were preserved from Air. Do not remove/repoint refs, fetch or reset as incidental migration cleanup; any repair needs its own task.

### Pro — existing paths, not one unified workspace

| Existing path | Observed role |
| --- | --- |
| `/Users/klukacin/projects/wsurf/` | Legacy build-only directory; not the new source workspace. Do not replace or treat as current development source. |
| `~/projects/wsurf-deploy-fb7b91c/` | Older clean detached source checkout at `fb7b91c2c5f5dbf523649c0a384ff8ae8b2684bc`, with ignored build output. Not current main. |
| `~/projects/wsurf-builds/` | Existing historical build directories. Preserve. |
| `~/projects/wsurf-native-main-20261005T204018234Z/`, `~/projects/wsurf-native-validation-20261005T204018234Z/` | Earlier source/build/validation snapshots. Preserve. |
| `/private/tmp/wsurf-cvs/` | Mixed protected source snapshots, package caches, signed builds, failed logs and native test results. Temporary location does **not** authorize deletion. |

Existing Pro legacy build-only and historical roots are untouched by this source transfer.

The current successful manual build operation is:

```text
/private/tmp/wsurf-cvs/manual-beeb824-20261016-25dvc6qj/
  src/                         exact clean detached beeb824 source
  SourcePackages/              this operation's candidate package graph/cache
  signedDerivedData/           this operation's Xcode output
    Build/Products/Debug/WSurf.app
  attempt-x9vncrdf/             successful owner build log and receipt
  build-result.json
  artifact-verification.json
```

Its `src` HEAD was independently verified as `beeb8247deae7eac462b98f5ed435858ffbb2209`, with no tracked or untracked changes. Native test evidence for that candidate remains separately under `/private/tmp/wsurf-cvs/integration-test-compile-fix-20261016-dhd1a_du/`. Do not move, rewrite or clean these frozen operations during future workspace work.

### New-developer startup

1. Start in `/Users/klukacin/projects/development/wsurf`. Before acting, read `README.md`, `CONTRIBUTING.md`, `RELEASING.md`, the relevant `docs/` material and this `docs/devops-handoff.md`.
2. Choose an explicitly authorized branch and commit for the task. Work in a task-specific feature branch/worktree under `.worktrees/`; keep the root checkout on `main` as the primary workspace, and do not commit or push `main`. Do not pull, reset or change source revisions automatically.
3. Preserve the migrated local documentation/configuration adjustments: all 45 existing active `.omp/config.yml` files use `~/projects/development/wsurf/.worktrees`; ten worktrees without that file were left without it. Copied Git links were repaired to the new common `newroot/.git`, with the missing historical record retained for review. These migration edits are uncommitted; move intended repository changes through a normal feature-branch PR, never a direct main commit or reset that discards them.
4. Use the existing build entrypoints. Keep each operation's source snapshot, worktree, package cache, DerivedData and receipts isolated, serialize native operations with the existing lock, and use the per-command Pro Xcode 27 `DEVELOPER_DIR` and same owner-interactive authentication session when signing. Do not change certificates, private keys, profiles, ACLs or TCC.
5. Do not treat copied caches as fresh build/test proof or rerun frozen historical drivers. The retained beeb824 result has 18 failed test definitions and 19 skips; inspect its retained evidence for explicitly scoped next work instead of rerunning the full suite just to rediscover those results.
6. CI `374811544` remains disabled. Source transfer authorizes no runner use, merge, release, install, app launch or credential migration. Onboarding alone does not authorize an automatic native run.

**Fresh-worktree bootstrap — before starting OMP**

`git worktree add` checks out the chosen committed revision; it does **not** carry the primary checkout's uncommitted migration edits into the new worktree. A fresh worktree can therefore contain the old OMP base path, and this handoff may be absent there.

Read the handoff from the primary root at `/Users/klukacin/projects/development/wsurf/docs/devops-handoff.md`. Before starting OMP in **each newly created worktree**, inspect that worktree's own `.omp/config.yml` and verify/apply this Pro setting:

```yaml
worktree:
  base: "~/projects/development/wsurf/.worktrees"
```

If the committed base is still `~/projects/wsurf/.worktrees`, change only that value for the Pro workspace. If the file is absent, create the minimal configuration above in the new worktree. Preserve any other settings; inspect unexpected values instead of blindly replacing a custom configuration. Only then start OMP there. Keep this machine-local adjustment uncommitted unless it is separately reviewed as a repository change; do not commit or push main.

**Pasteable prompt for a new developer:**

> Work only in `/Users/klukacin/projects/development/wsurf`. First read `README.md`, `CONTRIBUTING.md`, `RELEASING.md`, relevant `docs/`, and the primary root's `docs/devops-handoff.md`. Keep root/main as the primary checkout; choose the task's explicitly authorized branch and commit, and work in a task-specific feature branch/worktree under `.worktrees/`. Fresh worktrees do not inherit uncommitted migration edits: before starting OMP in each new worktree, verify/apply its own `.omp/config.yml` Pro base path using the primary-root handoff, even if that document is absent from the new worktree. Do not commit or push main, automatically pull/reset/change revisions, or discard migrated local docs/config adjustments. The copied worktree links are repaired; the missing historical record is review-only. Use existing build entrypoints, isolated per-operation source/worktree/build outputs and the existing native-operation lock. For signing, use Pro Xcode 27 via per-command `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and owner-interactive authentication in the same session; do not alter credentials, profiles, ACLs or TCC. Do not treat copied caches as fresh verification, rerun frozen drivers, or repeat the known beeb824 suite merely to rediscover 18 failed definitions and 19 skips. CI 374811544 remains disabled. No runner, merge, release, install, app launch or credential migration is authorized; start a native operation only when its task explicitly authorizes it.

## 2. Source-transfer procedure and custody

The current source copy is complete; the procedure below is for any future repeat transfer, not a pending step:

1. Re-inventory live checkout/worktree state and stop or coordinate WSurf development writers before taking a consistent copy. Do not stop unrelated applications or agents. Existing inventory is a discovery snapshot, not a reusable quiescence proof.
2. State the exact source/destination and overwrite risk, propose exact private backup commands for the checkout and external worktree roots, and obtain a fresh owner backup choice before the transfer. The browser-app backup waiver does not apply.
3. Stage a non-destructive copy on Pro. Preserve the full `.git` database, local-only refs/stash/reflogs/indexes, every existing linked worktree and its staged/unstaged/untracked content, symlinks, permissions and ignored local inputs. Do not use `rsync --delete`, `git clean`, resets, worktree pruning or a replacement clone.
4. Do not blanket-exclude `build/`: prior Air inventory identified `build/sidebar-customization` as a source worktree. Re-inventory actual contents for any repeat transfer, and account for private deployment/data backups. Keep any `.env`/signing-file values private; ignore rules alone do not prove those files exist. Never commit or paste private exports, browser data or logs containing credentials.
5. Verify the staged copy against the frozen source using opaque file/type/symlink and Git-state comparisons. Resolve any destination collision explicitly; do not overwrite a credential file just because names match. Repair worktree paths **only in the Pro copy**, then verify each worktree's branch/HEAD/index/local changes. Keep missing/prunable records for review; do not automatically prune them.
6. Update only Pro-local absolute-path configuration after verifying its old value and preserving rollback. Confirm the project's existing build entrypoints resolve from the new root. Do not pull, merge, update dependencies or choose a different source revision as an incidental migration step.
7. Keep the Air source and all existing Pro historical directories intact until the owner accepts the transferred workspace. A later source deletion is a separate approved operation, not routine cleanup.

Project migration is not browser-profile migration. Do not copy the Air's live browser database/vault, Apple Passwords, Keychain or passkeys into Pro as part of moving source. The cancelled Zen migration remains cancelled.

## 3. Native Pro build and signing contract

### Toolchain and existing signing setup

Pro was observed running macOS `26.6.2`, ARM64, Xcode `27.0` / `27A266a`, with approximately 1.03 TiB free at home. Use per-command `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; do not change global `xcode-select`, install a new toolchain or use GitHub/Gitea runners for the approved local-native route.

| Setting | Existing verified value |
| --- | --- |
| Team | `5X68L55TNU` |
| Apple Development public leaf SHA-1 | `3076859F107D3B59F2D72CA9F7EBEB55AB7CFBC0` |
| Host identifier | `io.wsagency.wsurf` |
| Extension identifier | `io.wsagency.wsurf.CredentialExchange` |
| Host development profile | `WSurf Mac Development`, UUID `fd8a4cee-f8e7-4aff-831a-ef76ac881b24` |
| Extension development profile | `WSurf Credential Exchange Development`, UUID `b4bca0c5-be57-4c7f-9e2e-225093b2aaeb` |
| Host / extension profile expiry | 2027-10-11 07:24:02Z / 07:25:38Z |

Revalidate identities/profile expiry and the actual target's native provisioning identifier before a future delivery; never persist device identifiers. The existing profiles were verified for Pro and M5 Air, **not** the separate operator MacBook Pro. Do not regenerate certificates, export/copy private keys, substitute Developer ID, modify entitlements, enroll another device, or change trust/ACL/partition-list/TCC to make a build pass. Signing stays in Pro's existing owner Keychain; moving source does not require migrating that Keychain.

### Prepare one exact operation

- Select the requested revision explicitly. Last verified merged main was `7b99516f9b620bebe5a3e01efd875800237aca06`; current Air-installed manual candidate is separate `beeb824`. The historically dirty Air main checkout and old Pro detached checkout are not automatically the release source. Check current authorized refs before a later build; this handoff did not fetch or merge.
- Use an independently owned exact source snapshot and clean, operation-specific DerivedData. Serialize native operations with the existing exclusive `flock` reservation `/tmp/wsurf-cvs/pro.lock`; do not delete or bypass the lock. An operation driver must hold it across native work.
- Use the candidate's reviewed `WSurf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; verify every checkout revision/clean state. Resolve packages in the operation's own SourcePackages, then use `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile`. Do not alter dependencies/acknowledgements or seed Xcode Build products to claim a fresh build.
- Pass `WSURF_CEF_PACKAGE` as an actual Xcode build-setting argument pointing at that operation's own `SourcePackages/checkouts/CefSwift`. Do not use a shared mutable checkout. If copying a verified package cache, relocate both `/tmp` and `/private/tmp` metadata aliases **only in the owned copy**; preserve historical caches and copied-cache provenance.
- For beeb824, the verified graph had 13 pins, AnyLanguageModel `1.0.0` / macro revision `80d50b0b22291d956d43f2c67ad1339c188084a3`, and CEF payload SHA256 `52ada707c9ed17bfeb48e235dd42a14b5f1f4a44551c9ceb0fb6ff748b26f0ed`. These are that candidate's facts, not overrides for another revision. Keep macro/plugin validation enabled.

### Owner authentication and the proven build body

If authentication is needed, the owner uses Pro Terminal or an interactive SSH TTY and enters the login-keychain password **only at the native prompt**:

```bash
# macOS — owner-operated Pro terminal, not an unattended agent command.
/usr/bin/security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
```

No `-p`, password environment variable, chat message, temporary password file or auto-approved GUI/security prompt. Run the build in that **same** terminal/security session. A new SSH session does not inherit the successful authorization. A locked-keychain/no-interaction failure is not permission to retry blindly or change key access controls.

The following is the successful beeb824 command shape, parameterized for an already-prepared owned operation. It is the build body, **not** a complete preparation/lock/authentication driver. Preconditions: exact source/cache verified, existing Pro reservation held by the operation driver, and owner authentication performed in this same session. `WSURF_SOURCE` and `WSURF_RUN` must be set to that operation's real paths; do not point them at protected historical operations to rerun a completed build.

```bash
# macOS — Pro, inside the already-authorized/locked operation.
: "${WSURF_SOURCE:?Set the exact clean source snapshot path}"
: "${WSURF_RUN:?Set the operation-owned output/cache root}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export WSURF_CI_TEST_LIMIT_SECONDS=1200
export WSURF_CI_FINALIZATION_LIMIT_SECONDS=120
cd "$WSURF_SOURCE"
/usr/bin/python3 Tools/run-xcodebuild-with-watchdog.py -- \
  "$DEVELOPER_DIR/usr/bin/xcodebuild" build \
  -project WSurf.xcodeproj -scheme WSurf -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$WSURF_RUN/signedDerivedData" \
  -clonedSourcePackagesDirPath "$WSURF_RUN/SourcePackages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  "WSURF_CEF_PACKAGE=$WSURF_RUN/SourcePackages/checkouts/CefSwift" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=3076859F107D3B59F2D72CA9F7EBEB55AB7CFBC0 \
  DEVELOPMENT_TEAM=5X68L55TNU \
  WSURF_PROFILE=fd8a4cee-f8e7-4aff-831a-ef76ac881b24 \
  WSURF_EXCHANGE_PROFILE=b4bca0c5-be57-4c7f-9e2e-225093b2aaeb \
  WSURF_BUNDLE_ID_SUFFIX=
```

Expected product: `$WSURF_RUN/signedDerivedData/Build/Products/Debug/WSurf.app`, including `Contents/PlugIns/WSurfCredentialExchange.appex`. Preserve full logs, exit status, exact commit/tree/pins, signing/profile metadata and UTC/monotonic durations. A successful `xcodebuild` exit is not artifact verification. Never rerun old `run-build.command` or `build-candidate.py` scripts merely because their paths appear in historical receipts: those drivers are frozen to one completed revision/operation.

### Native tests and acceptance

For a new acceptance task, use the exact candidate's existing pinned lint/format gate first, then its isolated build/test identity, watchdog/built-identity guard, full native suite, required non-skipped suites/benchmarks, coverage and all performance budgets. Existing entrypoints include `Tools/check-format.sh`, `Tools/run-xcodebuild-with-watchdog.py`, `Tools/check-coverage.sh` and `Tools/check-performance.sh`; arguments/thresholds come from that candidate's `.github/workflows/ci.yml`, not an invented generic shortcut. Do not loosen thresholds or add exclusions. Record environment/hardware/UI skips as limitations, never passes.

The retained beeb824 result had 18 failed test definitions and 19 natural skips. It is evidence to investigate, not a green baseline and not a reason to repeat the same suite just to rediscover known failures. Its manual-inspection build intentionally retained failures; this handoff does not authorize fixing/rerunning them or claiming native credential acceptance. New behavior fixes and their verification belong to the next explicitly scoped task.

## 4. Verify, package and install the full application

- Verify host and extension native deep-strict signatures, identifiers/team/public leaf, ARM64, exact profile blobs, signed entitlements versus grants/expiry, target-device membership and every nested Mach-O signature. Compare complete file/symlink manifests and executable/profile hashes across packaging/transport/installation. `codesign` alone does not prove target eligibility or runtime behavior.
- Development signing is not Developer ID/notarization/public-release acceptance. Apple Passwords, passkeys/PRF, system authentication and real native UI acceptance remain owner-operated. Never inspect credential contents or automatically accept provider/security prompts.
- Ask fresh scope/backup approval for a future install. Quit only authorized WSurf instances, require quiescence, hold the app's own `~/Library/Application Support/WSurf/WSurf.lock`, and use verified same-filesystem staging plus `renamex_np(RENAME_SWAP)`. Do not delete the live app first or copy over it in place. Preserve root owner/mode and guard opaque data/settings/defaults plus Codex config bytes/mode/owner before/after the swap. Stop on lock, signature, drift or App Management failure; do not grant permissions automatically.
- Current destination is **`/Applications/WSurf.app`**, the normal complete canonical app with its extension, not `build/` or a stage identity. Another folder with canonical identifiers does not isolate browser data. A test build must have a genuine isolated identity when tests require it; do not treat canonical `WSURF_BUNDLE_ID_SUFFIX=` as a test sandbox.
- Keep installed-app/data migration separate from source migration. After an app launch that could migrate data, an older executable alone is not a safe rollback: require the matching old app and pre-migration data/settings/defaults pair plus fresh approval.

The 2026-10-16 Air install completed at `12:15:14.337243Z`, under lock in `26.477278500s`. Host CDHash: `cd85eae6f86f3731f7f50f05a32efdb73e94f8d3`; extension: `4849aa674c6af6597184f0c0d05b01d95d5f1e39`. All 345 manifest entries and 20 Mach-O signatures passed; ten opaque data/settings paths, two actual defaults domains (base plus one profile) and Codex configuration were unchanged across the swap. No new recovery pair was created under the fresh one-operation waiver. The agent did not launch the new app. These are dated install facts, not current runtime/UI acceptance.

## 5. Website, credentials and release authority

The native macOS app and the Cloudflare static website are different deployment surfaces. `wrangler.jsonc` publishes only `wsurf.app/` assets to Worker `wsurf-site`, custom domain `https://wsurf.app`; there is no native build or signing in that website deployment.

- Last verified GitHub workflow `CI` ID `374811544` (`.github/workflows/ci.yml`) is `disabled_manually`. **Do not enable, dispatch or rerun it without fresh explicit approval.** Moving the project does not change this decision.
- `.github/workflows/deploy-site.yml` is registered/active but waits for successful CI on the exact merged main SHA and checks that SHA is still current. Paused CI supplies no new successful upstream event. Do not bypass that gate with an incidental manual website deployment.
- Website deployment uses pinned `wrangler@4.136.2` and GitHub secret `CLOUDFLARE_API_TOKEN`, scoped to the existing Worker. Secret values belong in provider/CI secret storage, never Git, this document, a report or command arguments. GitHub secrets are write-only; do not try to extract a value. Native builds do not need this token.
- Use the project's existing GitHub authentication and normal authorized PR/release process; moving source does not grant permissions or authorize a merge, tag, release, DNS/Worker change or force-push/reset of main. Keep `RELEASING.md` and workflow gates intact. Static website verification does not establish native app acceptance.

## 6. Evidence and rollback

Primary first-party sources for this handoff are the WSurf `README.md`, `CONTRIBUTING.md`, `RELEASING.md`, `.omp/config.yml`, `.gitignore`, `.github/workflows/` and existing `Tools/` entrypoints, plus the exact successful Pro build receipt under the retained manual operation above. Live native Git/toolchain/path inventory was taken at approximately `2026-10-16T12:57:21Z`, without fetch, index refresh, builds or signing probes.

Private operational history remains in the DevOps hub's ignored operation storage on the operator machine and in retained Pro operation roots. It is not a repository dependency: the operating rules needed here are included above. During an approved migration, preserve historical receipts/required local-only helpers privately rather than publishing raw sessions, copying credential exports into Git or silently abandoning evidence. No reusable generic build/install driver is claimed to have been added by this documentation task.

**Source rollback:** switch back to the untouched Air checkout/worktrees. The Air originals remain intact. If the new Pro copy must later be removed, preserve any new work first and obtain explicit deletion approval; remove only the exclusively new Pro copy, never old Pro histories. If verification fails, retain evidence and do not reset either side or prune worktrees.
**Native app rollback:** after possible migration, require the matching app/data/settings pair; the last no-backup install did not create one. **Website rollback:** use its separately approved workflow/provider procedure, not an app downgrade or automatic CI re-enable.
