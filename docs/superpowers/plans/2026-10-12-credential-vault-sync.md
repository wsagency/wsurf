# Credential Vault Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the whole approved spec: a per-profile hard-fail SQLite credential store with several vaults, mandatory history and linked Trash, v1 migration, reviewed Apple exchange for password/passkey/TOTP, routed consumers, then PR → `main` → Pro signed build → artifact checks → guarded Air install → the user's own native acceptance (Gate B, UNVERIFIED until the user reports).

**Architecture:** One actor `ProfileVaultStore` per profile owns `Credentials.store` (GRDB). Sealed head/rows/journal/registry formats, anchors, per-unlock verification, atomic commit/MOVE, migration and creation live under `WSurf/Web/Credentials/Store/`. `CredentialManager` becomes per `(profile, vault)` and keeps its lease/epoch role; the four `forProfile` consumers, the exchange coordinator and Settings are cut over to it. The exchange codec loses passkey replace and gains classification, binding and truthful lifecycle.

**Tech Stack:** Swift 6.4 / Xcode 27, GRDB (already a dependency, no new one), CryptoKit, Swift Testing (`@Test`, suites are `struct`s), SwiftUI/AppKit. Python 3 stdlib + `openssl` for the Gate B fixture only.

**Spec:** [`docs/superpowers/specs/2026-10-12-credential-vault-sync-design.md`](../specs/2026-10-12-credential-vault-sync-design.md), approved 2026-10-12 (design only; every runtime gate is unverified) **plus the §7 Planning Clarification (password-save policy in the sealed head), accepted by the user's instruction to proceed on 2026-10-12**. Base `origin/main` `46fd7b6`, spec commit `72afe2a`, branch `feature/credential-vault-sync-20261012`, worktree `.worktrees/credential-vault-sync-20261012`. Plan status: independently reviewed (plan quality passed). 2026-10-12 direct user direction: the §7 clarification is accepted and no disposable macOS user or Apple Account is required; the user runs the native Apple Passwords/passkey acceptance on their own account after delivery (Gate B amended, Task 17). Product code starts only when the user assigns Task 1 (§Execution).

## Global Constraints

Every task's requirements include this section.

- **Spec wins** over this plan; a conflict is escalated to Main, never silently resolved. The one plan-introduced spec change is the §7 Planning Clarification (accepted 2026-10-12); if the user later withdraws it, T3, T5, T6, T7, T9 and T12 must be re-planned before they start (they are the only owners of `blockedOrigins`; T12's `commitAccounts` builds its validation payload from the head's set).
- **Naming deviation (recorded, not a design change):** the spec calls the per-profile object `CredentialStore`; that name exists (`WSurf/Agent/Providers/CredentialStore.swift`, provider-key keychain store). The new actor is `ProfileVaultStore`; tests use the prefix `Vault*`.
- **Isolation:** the project defaults to main-actor isolation, so every new value type, enum and helper under `Store/` is declared `nonisolated` (and `Sendable` where stated). `CredentialManager` keeps its existing `@MainActor @Observable`; `CredentialRouting` and `VaultChoicePrompt` are `@MainActor`; `ProfileVaultStore` is an `actor`. No blanket `nonisolated` on the manager.
- **No new dependency, entitlement, App Group, keychain group, Secure Enclave key or extension data channel.** The managed-browser entitlement (`com.apple.developer.web-browser.public-key-credential`) stays absent.
- **Clean cutover:** every `forProfile` caller migrated, the v1 write path removed (v1 stays read-only for migration), no shims, aliases or dual paths. No stubs: a task never needs a later task's code; tasks are in topological order.
- **Test policy:** a test drives a real boundary and asserts the observable result. No test asserts API absence, source text, constant existence, call wiring, zeroization or "file contains no plaintext". Tests use synthetic data only; none reads a production vault, a backup or Apple Passwords. Spec-item traceability (§Spec coverage) is documentation in this plan and the PR, **not a test**.
- **Build/test only through the Pro runner** (§Verification); Air is CLT-only (no `xcodebuild`). `DEVELOPER_DIR` is set inside the runner. `-skipMacroValidation` / `-skipPackagePluginValidation` are never used locally; a macro-trust need is escalated to the user for a scoped approval.
- **Native evidence is human-operated.** No agent controls the production desktop (the user refused this earlier), drives Apple Passwords, Touch ID, a keychain prompt or any consent dialog, launches the app against production data, reads, exports, imports or deletes the user's real credentials, or fabricates consent, a passkey, a PRF output or an Apple Account. The user runs the native acceptance on their own macOS and Apple accounts after delivery (2026-10-12 direct instruction; no disposable user or account); every native item stays **UNVERIFIED** until the user reports it, never passed or scope-reduced by agents.
- **Deployment** is authorized by the user (2026-10-12; amended the same day: no Gate B pre-install condition) **for the signed artifact built from the exact CI-green merged `main` SHA only**; Gate A, CI, the artifact checks, the guarded backups or any prerequisite failing ⇒ stop and report. No tag, publish, release or preview. A fresh Cmd-Q of every WSurf is required immediately before the swap.
- Docs/changelog updated in Task 16; scaffolds and throwaway scripts removed before the PR.

## Review Focus

Five cases the spec implies and a reasonable person would expect to hold; each is pinned by named tests in the owning task.

1. **Migration under overlap and crash** (Task 9: `VaultMigrationTests`): kill at each of steps 1-10; an old-build write before the swap ⇒ `cutover-v1`, nothing granted or merged; after the swap ⇒ rows 1/3; `.pre-v2` reused only if byte-identical; `.migrating` untouched until v1 and backup verified; the pending store file is self-contained at the swap; `RENAME_SWAP` unsupported ⇒ abort unchanged; blocked-origin policy survives byte-for-byte.
2. **Nothing granted before verification, and lock order** (Tasks 4, 5, 6): lock taken before any read transaction and never upgraded; any registry/head/wrapper/V1-V5 failure ⇒ no grant, not even read-only; stale publish discarded; an A3 that is present-but-different is never overwritten; the stub is created only with create-if-absent; a tampered policy list fails V1.
3. **MOVE atomicity and logical residue** (Tasks 7, 8): one transaction, rolled back whole on any error; exactly one secret-bearing logical copy; `transfer` journal rows on both sides even for an empty move; delete → undelete → delete verifies; removal by any commit path is a MOVE with no leftover active revision; purge is logical, needs a fresh assertion, never touches wrappers or `.pre-v2`.
4. **Consumer cutover and routing** (Task 10): every former `forProfile` site resolves one named unlocked vault bound to its epoch; locked vaults are never read; ambiguous / none-matched-while-locked / default-locked ⇒ explicit choice, never silent fallback; WebAuthn keeps its post-prompt selected-account recheck; lock and erase drain every vault manager.
5. **Exchange identity, binding, messaging** (Tasks 11, 12): passkey replace is gone at codec and review; only same `rpID`+`credentialID` with a different public key or `userHandle` is a hard conflict; preview bound per account `(recordID, version, digest)`; exact §13.5 messages, never "synced/erased/accepted"; export dates never stale.

---

## Repo ground truth (verified in this worktree; paths relative to the repo root)

- Credentials sources: `WSurf/Web/Credentials/{CredentialAccount,CredentialExchangeCodec,CredentialExchangeCodecApply,CredentialExchangeCodecExport,CredentialExchangeCoordinator,CredentialManager,CredentialSettingsModel,CredentialVault,CredentialVaultCrypto,PasskeyKeyEncoding,PasskeyVaultUnlocker,WebAuthnAdapter,WebsiteAuthenticator,WebsiteAuthenticatorCeremony}.swift`. Settings UI: `WSurf/Settings/Pages/CredentialSettings.swift`.
- Existing shapes reused: `CredentialVault` actor (v1 store, kept untouched until Task 10 deletes it; Task 9's `LegacyVaultV1` reads v1 through `CredentialVaultCrypto` only), `CredentialVaultCrypto` (wrap/unwrap, `decodeEnvelope`, `validate(_ payload:)`), `VaultUnlockProof{credentialID,prfInput,prf}`, `VaultAccess{profileID,epoch,deadline,revoke,isAuthorized,checkAuthorization,withAuthorization}`, old v1 `VaultSnapshot{revision,accounts,blockedPasswordOrigins}` (created by `CredentialVault`; **deleted in Task 10**, replaced by Task 6's `StoreSnapshot`), `VaultCommitReceipt{revision}`, `VaultUnlock{credentialID,prfInput}`, `VaultDiscovery{vaultID,unlocks}`, `CredentialVaultError`, `CredentialVaultLimits{payloadBytes=4_000_000,fileBytes,accounts=1_000,wrappers=32}`, `TestClock` (`WSurfTests/Helpers/TestClock.swift`, `now`, `advance`). Test construction today: `CredentialManager(profile:directory:now:)` at `WebsiteAuthenticatorCeremonyTests.swift:137`, `CredentialExchangeCoordinatorTests.swift:42`, `CredentialSettingsTests.swift:585`.
- `forProfile` consumers (Task 10): `WSurf/Web/Autofill/AutofillSuggestions.swift:184,196`, `AutofillSaveCoordinator.swift:161,172`, `WSurf/Web/Credentials/CredentialSettingsModel.swift:289`, `WebAuthnAdapter.swift:400`. Lock/retire callers: `WSurf/App/AppCoordinator+Profiles.swift:27,68`, `WSurf/App/BrowserApplication.swift:295`, `WSurf/Profiles/Profile.swift:107`. Other files naming `CredentialManager`: `WSurf/Web/Autofill/{CredentialAutofill,PasswordAutofill,PasswordAutofillScript}.swift`, `WSurf/Profiles/BrowserProfileContext.swift`, `WebsiteAuthenticatorCeremony.swift`. `vaultExists()` / `create(in:)` are used by `CredentialSettingsModel.swift:404,519`. `VaultSnapshot` is constructed directly in `CredentialExchangeCoordinatorTests.swift:162` and `CredentialExchangeTests.swift:71`.
- Exchange: coordinator methods `receive, discardPendingImport, claimImport(token:for:owner:), hasStagedImport, importReview, beginImport, stage, choose, mergeTargets, commitImport, cancelImport, exportCredentials, prepareExport`; token intake `BrowserApplication.swift:188-205`; Settings entry `CredentialSettingsModel.swift:580-650`, UI `CredentialSettings.swift:44-58,228,837-839`.
- `PBXFileSystemSynchronizedRootGroup` (`objectVersion = 100`): new files under `WSurf/` and `WSurfTests/` are picked up with **no pbxproj edit**. `Tools/CredentialFixture` does **not** exist. `.superpowers/` is a self-ignoring SDD workspace.
- Docs to update: `CHANGELOG.md` (top `## WSurf`, dated `###` entries), `SECURITY.md` (credential bullet ~L37). `docs/superpowers/plans/2026-10-10-…` is historical and untouched.

## Task order, ownership and dependencies

Tasks run **strictly in numeric order, one implementer at a time**; each is reviewed before the next starts. A task consumes only what earlier tasks produce. A file has one owner; a later task that must change an earlier owner's file lists it under **Modify**.

| Task | Needs | Creates / owns | Modifies |
|---|---|---|---|
| 1 Primitives, errors, file ops, lock, test support | – | `Store/{StoreFormat,StoreCodec,StoreErrors,StoreFileOps,OperationLock}.swift`, `WSurfTests/Helpers/VaultTestSupport.swift` | `CredentialVaultCrypto.swift` (`wrapperAAD`) |
| 2 Account model, content hash, diff | 1 | `Store/{CredentialContent,CredentialDiff}.swift` | `CredentialAccount.swift` |
| 3 Sealed formats, policy, registry, tables | 1 | `Store/{StoreRecords,StoreSeal,StoreTables}.swift` | – |
| 4 Anchors and state machine | 1, 3 | `Store/StoreAnchors.swift` | – |
| 5 Verifier V1-V5 + scratch | 3 | `Store/{StoreVerifier,VerificationScratch}.swift`, `WSurfTests/Helpers/VaultStoreFixture.swift` | – |
| 6 Store core: open, unlock, snapshot, wrappers, policy | 1-5 | `Store/{StoreSnapshot,ProfileVaultStore,ProfileVaultStore+Unlock,ProfileVaultStore+HeadWrites}.swift` | `VaultStoreFixture.swift` (the v1 `VaultSnapshot` is not touched) |
| 7 Commit and MOVE | 2, 6 | `Store/{ProfileVaultStore+Commit,ProfileVaultStore+Move,StoreBodies}.swift` | `VaultStoreFixture.swift` |
| 8 Undelete, restore, purge, listings | 7 | `Store/{ProfileVaultStore+History,ProfileVaultStore+Purge}.swift` | – |
| 9 Vault creation and migration | 6, 7 | `Store/{LegacyVaultV1,ProfileVaultStore+Create,ProfileVaultStore+Migrate,ProfileVaultStore+UnlockRouting}.swift` | – |
| 10 Manager, routing, consumer cutover | 6-9 | `Web/Credentials/{CredentialRouting,VaultChoicePrompt}.swift`, `WSurfTests/Helpers/VaultManagerFixture.swift` | `CredentialManager.swift`, `CredentialVaultCrypto.swift` (deletes `VaultSnapshot`), `CredentialSettingsModel.swift` (3 sites + `VaultSnapshot` uses), 4 consumers, 4 lock/retire callers, existing credential tests; **deletes** `CredentialVault.swift`, `CredentialVaultTests.swift` |
| 11 Exchange codec and classification | 2 | – | `CredentialExchangeCodec.swift`, `CredentialExchangeCodecApply.swift`, `CredentialExchangeCodecExport.swift` |
| 12 Exchange coordinator, per-account writes, messages | 7, 10, 11 | `Store/ProfileVaultStore+AccountWrites.swift`, `Web/Credentials/CredentialTransferMessage.swift` | `CredentialManager.swift` (`commitAccounts`), `Store/ProfileVaultStore+Commit.swift` (only to expose the shared plan writer), `CredentialExchangeCoordinator.swift`, `BrowserApplication.swift:188-205` |
| 13 Editor contract | – | `Settings/Pages/{WebsiteListField,WebsiteFieldEditing}.swift` | – |
| 14 Settings model + Saved Credentials UI | 8, 9, 10, 12, 13 | `Settings/Pages/CredentialSettings+{Vaults,Trash,Versions,FailClosed}.swift` | `CredentialSettingsModel.swift`, `CredentialSettings.swift` |
| 15 Gate B fixture kit | – | `Tools/CredentialFixture/*` | – |
| 16 Gate A closure + docs | 1-15 | – | `CHANGELOG.md`, `SECURITY.md` |
| 17 Delivery | 16 + user review | no source; evidence under the SDD workspace | – |

Test files are flat under `WSurfTests/Web/` (existing convention) and `WSurfTests/Settings/`; helpers under `WSurfTests/Helpers/`.

Read-only inspection (scouts, reviewers) may run in parallel with each other; implementation is never parallel (SDD rule).

## Verification (Pro runner; Main is the single writer of the Pro tree)

Air is CLT-only; every build/test runs on Pro (`ssh pro`, Xcode 27 at `/Applications/Xcode.app/Contents/Developer`, set explicitly in every command). No `flock` executable is assumed. Preflight (Main, once, result recorded in the ledger): `ssh pro 'python3 -c "import fcntl,os;print(fcntl.flock)"; command -v rsync xcodebuild; install -d -m 700 /tmp/wsurf-cvs /tmp/wsurf-cvs/stage /tmp/wsurf-cvs/src'`. If `python3`/`fcntl` is missing, stop and report the missing prerequisite; do not substitute another lock.

One-time setup (Main) writes `/tmp/wsurf-cvs/locked.py` on Pro (stdlib `fcntl.flock(2)`, the same primitive as the app's `OperationLock`; the descriptor is made inheritable so the lock survives `exec`):

```python
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
os.set_inheritable(fd, True)
os.execvp(sys.argv[2], sys.argv[2:])
```

`PRO_TEST <Suite>...` = one attempt, run **fresh for every RED and every GREEN** (never reusing an earlier sync):
1. On Air, from the worktree: `A=$(date +%s)-$$; rsync -a --delete --exclude .git --exclude build --exclude .build --exclude .worktrees --exclude .superpowers ./ pro:/tmp/wsurf-cvs/stage/$A/` (private per-attempt staging; nothing ever builds from it).
2. Then `ssh pro "python3 /tmp/wsurf-cvs/locked.py /tmp/wsurf-cvs/pro.lock /bin/sh -c 'export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; rsync -a --delete /tmp/wsurf-cvs/stage/$A/ /tmp/wsurf-cvs/src/ && cd /tmp/wsurf-cvs/src && xcodebuild test -project WSurf.xcodeproj -scheme WSurf -destination \"platform=macOS,arch=arm64\" -derivedDataPath /tmp/wsurf-cvs/DD -disableAutomaticPackageResolution -only-testing:WSurfTests/<Suite> CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS='"`, then `ssh pro rm -rf /tmp/wsurf-cvs/stage/$A`. Promotion into `src/` and the build happen under one lock hold, so no sync can replace files mid-build. First attempt on a fresh Pro tree also runs `xcodebuild -resolvePackageDependencies … -onlyUsePackageVersionsFromResolvedFile` under the same lock.
3. Evidence: RED = the quoted failing assertion or compile error naming the missing symbol; GREEN = `** TEST SUCCEEDED **` with the executed test names and counts.

**Integration gate (Main, once, in Task 16):** `PATH=<pinned tools>:$PATH Tools/check-format.sh`; the full suite exactly as `.github/workflows/ci.yml` / `CONTRIBUTING.md` run it (`python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild test … -resultBundlePath build/TestResults.xcresult -enableCodeCoverage YES -parallel-testing-enabled NO`), `Tools/check-coverage.sh build/TestResults.xcresult <floor read from ci.yml>`, `xcrun xcresulttool get test-results metrics … | Tools/check-performance.sh`, `swift Tools/make-acknowledgements.swift build/DD/SourcePackages/checkouts` (Acknowledgements unchanged). Tasks 1-15 run only their own suites plus the named neighbouring suites (targeted); they do not each run the full suite.

**Air (syntax/hygiene only):** `git diff --check`; `xcrun swiftc -parse <changed .swift>`; `python3 -m py_compile Tools/CredentialFixture/*.py`; `plutil -lint`; `test -e` for every path this plan names. Air runs no `xcodebuild`, no WSurf app and no production data.

## Execution (after the user's plan review; nothing here starts earlier)

Subagent-driven development, **serial**: one implementer at a time, each task reviewed (spec compliance and quality) and fixed before the next task is dispatched; no two implementers run in parallel. **Harness adaptation (recorded ruling):** the skill text asks for a fresh implementer subagent per task, but the `task` tool's developer instruction (reuse the existing persistent session for the same workstream) overrides it. Existing persistent sessions are therefore reused for the same workstream (the credential-vault store/manager/exchange/settings chain), still one implementer at a time; a task whose ownership is unrelated to that workstream (for example Task 15's Python fixture kit) may use another existing or scoped session. No duplicate session is spawned for a workstream that already has one. Per-task isolation comes from the review gate, the ledger and the task brief. This is a harness-rule resolution, not an unresolved spec requirement. Read-only inspection (scouts, reviewers) may run in parallel with each other. Main is the only agent that runs the integration gate, Gate B coordination, the PR and delivery.

Workspace and artifacts come from the skill scripts, not invented paths (`SDD=~/.omp/plugins/cache/plugins/superpowers-marketplace___superpowers___6.3.0/skills/subagent-driven-development/scripts`):
- `bash $SDD/sdd-workspace docs/superpowers/plans/2026-10-12-credential-vault-sync.md` → `.superpowers/sdd/2026-10-12-credential-vault-sync/` (git-ignored by its own `.gitignore`); the ledger is `progress.md` there, first line `# SDD ledger — plan: docs/superpowers/plans/2026-10-12-credential-vault-sync.md`.
- Per task N: `bash $SDD/task-brief <plan> N` → `task-N-brief.md` (extracted from the `### Task N:` heading to the next `Task <number>` heading; **no non-task section follows Task 17**, so nothing leaks into its brief); implementer writes `task-N-report.md`; `bash $SDD/review-package <plan> <BASE> <HEAD>` → `review-<base7>..<head7>.diff`; record BASE per task in the ledger.
- Briefs do not contain the Global Constraints/Review Focus/Verification sections: the dispatch prompt points the implementer at them (and at the spec) by path.
- Spec/plan conflicts and contract changes go to Main, who edits this plan and the ledger before re-dispatch.

## Spec coverage (documentation; not a test)

Task 16 records, in the SDD ledger and the PR description, one row per spec item naming its tests (suite and test names); a row with no executed assertion is a gap to fix, not a pass.

**Items 1-20:** 1 → T4 (+T14 messages) · 2 → T3, T5, T6, T9 · 3 → T5 · 4 → T9 · 5 → T1 (lock, frozen AAD), T4 (stub), T6 · 6 → T2, T7 · 7 → T8 (+T14 confirmation) · 8 → T11 · 9 → T2, T11 · 10 → T10 · 11 → T12 · 12 → T6, T10 · 13 → T7, T8 · 14 → T7, T8 · 15 → T2, T7, T14 (+T13) · 16 → T11, T12, T14 · 17 → T8 (+T2, T7) · 18 → T5, T7, T8 · 19 → T8 · 20 → T13. **Gate A:** T16 (+T17 PR/CI). **Gate B:** G1 → T9, T14 + T17 · G2 → T15 + T11/T12 + T17 · G3 → T11/T12 + T17 · G4 → T9 + T17 · G5 → T13, T14 + T17 · G6 → T17.
**Sections:** §4 → T3, T6, T9, T8 · §5 → T1, T3, T7 · §6 → T4, T6 · §7 → T3, T5, T6, T7, T9, T12 · §8 → T9 · §9 → T6, T10 · §10 → T9 · §11 → T2, T7, T8 · §12 → T2, T11, T14, T13 · §13 → T11, T12 · §14 → T10, T14 · §15 → T1, T6, T7 · §16 → T16, T17 · §17 limits restated in T16 docs. **Risks:** R1 → T11 · R2 → T11 · R3 → T12 · R4 → T12 · R5 → T2, T14 · R6 → T11 · R7 → T12 (extension untouched; artifact check in T17).

## Unresolved prerequisites (real; none invented)

1. **Gate B operator:** the user, on their own macOS account and Apple Account (the disposable-user/Apple-Account requirement was removed by the user on 2026-10-12), with their own PRF-capable passkey. Gate B is not a precondition of the install; it is the user's post-delivery acceptance, UNVERIFIED until the user reports. Agents run none of it.
2. **G2 fixture origin (optional for the user):** an operator-controlled HTTPS origin with certificate/trust and DNS/hosts entry for `Tools/CredentialFixture` (Task 15 supplies the server, not the origin).
3. **Pro signing session:** the user at the Pro GUI Terminal with the login keychain unlocked for each signed build (SSH signing failed with `errSecInternalComponent` on 2026-10-11; current state unverified); scoped SwiftPM macro trust only if a build needs it.
4. **Pinned SwiftLint 0.65.1** in an owned Pro directory (Pro's global 0.65.0 differs). **Merged-main source** reaches Pro as an exported snapshot (Pro has no git checkout; `gh` is logged in on Air only).
5. **Historical helpers** (`air-deploy-swap.py` under `.worktrees/credentials-integration-20261010/.build/credential-takeover-20261010/`; Pro wrapper set under `/tmp/wsurf-signed-46fd7b6.htGNp1/out/`) are existence-unverified; they are re-checked, copied and reviewed, never run in place.
6. **Fresh Cmd-Q quiescence** of every WSurf immediately before the swap.
7. **Editor workstream overlap:** the spec calls the editor another worker's scope; no editor change exists in this worktree. Task 13 implements the §12.4 contract on the current website fields; if another branch has landed an editor first, Main resolves the overlap before Task 13.
8. **Planning Clarification (§7 policy field):** accepted or withdrawn at the user's plan review. Withdrawal ⇒ Tasks 3, 5, 6, 7, 9, 12 are re-planned before they start.
9. `RENAME_SWAP`/`RENAME_EXCL`, `F_FULLFSYNC` power-loss behaviour, physical disk-full and real-size verification cost: UNVERIFIED by design (spec §17); only logical behaviour is tested.

---

## Tasks

### Task 1: Primitives, errors, file ops, operation lock, test support

**Files:**
- Create: `WSurf/Web/Credentials/Store/StoreFormat.swift`, `StoreCodec.swift`, `StoreErrors.swift`, `StoreFileOps.swift`, `OperationLock.swift`
- Create: `WSurfTests/Helpers/VaultTestSupport.swift`; Test: `WSurfTests/Web/VaultPrimitivesTests.swift`, `VaultOperationLockTests.swift`, `VaultFileOpsTests.swift`
- Modify: `WSurf/Web/Credentials/CredentialVaultCrypto.swift:440-448` (`wrapperAAD` uses `StoreFormat.wrapperFormat`; the global `format` stays 1 and is not bumped)

**Interfaces:**
- Consumes: `CredentialVaultCrypto`, `VaultUnlockProof`, `Profile`, `TestClock`.
- Produces (all `nonisolated`; exact):

```swift
enum StoreFormat { static let schema = 2, wrapperFormat = 1
  static let rowLabel = "WSurf credential store", registryLabel = "WSurf registry v1"
  static let busyTimeoutMS = 5000, historyPage = 50, nameLimit = 64, activeVaultLimit = 16
  static let journalOpsPerRow = 1000, historyRowBytes = 8_000_000, blockedOriginLimit = 4_096
  static let lockWait: Duration = .seconds(5), verifyingThreshold: Duration = .milliseconds(250) }
enum VaultRole: UInt8, Sendable { case active = 1, trash }                 // trash == 2
enum RecordKind: UInt8, Sendable { case account = 1, revision, trashEntry, tombstone }
enum RecordSubject: UInt8, Codable, Sendable { case account = 1, password, totp, passkey, metadata }
enum JournalOpKind: UInt8, Sendable { case add = 1, remove }
enum TransferDirection: UInt8, Sendable { case `in` = 1, out }
enum TransferScope: UInt8, Codable, Sendable { case account = 1, credential }
// VaultRole, RecordKind, RecordSubject each also: var sqlName: String { get }  (lowercase case name, "trashEntry" camel) and init?(sqlName: String)
enum StoreLimit: Equatable, Sendable { case accounts, payloadBytes, fieldBytes, wrappers, historyRow, blockedOrigins }
enum UndeleteBlock: Equatable, Sendable { case ownerMissing, idCollision, exchangeIDCollision, originUsernameOverlap, passkeyCollision, slotOccupied(RecordSubject), passkeyIdentityConflict }
enum StoreFailCause: Equatable, Sendable { case foreignStore, v1AfterMigration, storeMissing, leftoversWithoutAuthority, unreadableVault, unreadableStore, cutoverV1Present, witnessMismatch, wrongProfile, migrationLeftover }
struct StoreFailClosed: Equatable, Sendable { let cause: StoreFailCause; let paths: [URL]; let preMigrationBackup: URL? }   // paths absolute (§6.4)
enum CredentialStoreError: Error, Equatable, Sendable {
  case failClosed(StoreFailClosed), storeBusy, integrityFailure(vaultOrdinal: Int?), limit(StoreLimit), diskFull
  case malformed, noAuthority, passkeyUnusable, migrationNeedsConfirmation, migrationAborted(path: URL?), renameSwapUnsupported, stateChanged   // stateChanged: the open state read under the lock is not the one the caller routed on
  case undeleteBlocked(UndeleteBlock), metadataUndecodable, invalidVaultName, tooManyVaults, noSuchVault }   // access/revision failures reuse CredentialVaultError.unauthorized/.expired/.staleRevision (existing; manager callers unchanged)
struct StoreWriter { init(); var data: Data { get }
  mutating func u8(_ v: UInt8); mutating func u32(_ v: Int); mutating func u64(_ v: UInt64); mutating func bool(_ v: Bool)
  mutating func uuid(_ v: UUID); mutating func text(_ v: String); mutating func bytes(_ v: Data); mutating func date(_ v: Date)   // date = timeIntervalSinceReferenceDate Float64 bit pattern, UInt64 BE (plan decision: the spec fixes the bit pattern, not the epoch)
  mutating func uuidSet(_ v: Set<UUID>)                                                                                    // count, then 16-byte ids sorted ascending
  mutating func optional<T>(_ v: T?, _ write: (inout StoreWriter, T) -> Void)
  mutating func array<T>(_ v: [T], _ write: (inout StoreWriter, T) -> Void) }
struct StoreReader { init(_ data: Data); var isAtEnd: Bool { get }
  mutating func u8() throws -> UInt8; mutating func u32() throws -> Int; mutating func u64() throws -> UInt64; mutating func bool() throws -> Bool
  mutating func uuid() throws -> UUID; mutating func text() throws -> String; mutating func bytes() throws -> Data; mutating func date() throws -> Date
  mutating func uuidSet(maxCount: Int) throws -> Set<UUID>
  mutating func optional<T>(_ read: (inout StoreReader) throws -> T) throws -> T?
  mutating func array<T>(maxCount: Int, _ read: (inout StoreReader) throws -> T) throws -> [T] }   // every failure throws CredentialStoreError.malformed
enum StoreFileError: Error, Equatable, Sendable { case exists, unsupported, io(Int32) }
struct StoreFileOps: Sendable {
  var renameExclusive: @Sendable (_ from: URL, _ to: URL) throws -> Void    // renamex_np RENAME_EXCL; existing destination ⇒ StoreFileError.exists
  var renameSwap: @Sendable (_ a: URL, _ b: URL) throws -> Void             // renamex_np RENAME_SWAP; ENOTSUP/EINVAL ⇒ .unsupported
  var fullFsync: @Sendable (_ file: URL) throws -> Void                     // open + fcntl(F_FULLFSYNC)
  var fsyncDirectory: @Sendable (_ directory: URL) throws -> Void
  var afterMigrationStep: (@Sendable (_ step: Int) throws -> Void)?          // test seam, nil in production; Task 9 calls it after each step 1-10
  static let live: StoreFileOps }
final class OperationLockHold: Sendable { func release() }                  // idempotent; also on deinit
enum OperationLock { enum Mode: Sendable { case shared, exclusive }
  static func acquire(in directory: URL, mode: Mode, wait: Duration = StoreFormat.lockWait) async throws -> OperationLockHold }  // flock(2) on <directory>/Credentials.lock, polled every 10 ms; timeout ⇒ CredentialStoreError.storeBusy
// WSurfTests/Helpers/VaultTestSupport.swift
struct VaultTestEnvironment { let directory: URL; let defaults: UserDefaults; let clock: TestClock; let profile: Profile
  static func make() throws -> VaultTestEnvironment        // temp dir, UserDefaults(suiteName: UUID().uuidString), TestClock(), Profile(id: UUID(), name: "Test", symbol: "key", color: .blue)
  func cleanUp() }
enum VaultFixtures { static func proof(_ n: UInt8 = 1) -> VaultUnlockProof                                  // credentialID 32×n, prfInput 32×(n+1), random 256-bit prf
  static func account(id: UUID = UUID(), username: String = "ada", password: String? = "secret", origin: String = "https://example.test", passkeys: [WebsitePasskey] = []) -> CredentialAccount
  static func passkey(rpID: String = "example.test", credentialID: Data = Data(repeating: 1, count: 32)) throws -> WebsitePasskey }   // bodies copy CredentialVaultTests.swift:32-82
```

- [ ] **Step 1: Record the frozen wrapper vector from the current code.** Add a temporary test `RecordWrapperVector` that wraps a fixed 32-byte DEK (`0x11`×32) with a fixed proof (`credentialID` `0x01`×32, `prfInput` `0x02`×32, `prf` `0x03`×32 as `SymmetricKey`) for fixed `profileID` `00000000-0000-0000-0000-0000000000A1` and `vaultID` `…00B2`, and prints the resulting `CredentialKeyWrapper` fields (`nonce`, `ciphertext`, `tag`) as hex. Run `PRO_TEST RecordWrapperVector` on the **unedited** `CredentialVaultCrypto.swift`; copy the hex into Step 2; delete the temporary test.

- [ ] **Step 2: Write the failing tests.**
  - `VaultPrimitivesTests`
    - `writerAndReaderRoundTripEveryEncodingRule`: writes `u8(7)`, `u32(1)`, `u64(1)`, `bool(true)`, one UUID, `text("é")`, `bytes([1,2])`, `date(Date(timeIntervalSinceReferenceDate: 1234.5))`, `optional(nil as Int?)`, `optional(5)`, `array([1,2,3])`, `uuidSet` of three ids; the reader returns equal values and `isAtEnd == true`.
    - `encodingsAreExactlyTheSpecifiedBytes`: `u32(1)` → `[0,0,0,1]`; `u64(1)` → `[0,0,0,0,0,0,0,1]`; `uuid` → its 16 raw bytes; `text("ab")` → `[0,0,0,2,0x61,0x62]`; `bool(true)` → `[1]`; optional absent → `[0]`; present `u8(9)` → `[1,9]`; `date` → big-endian `timeIntervalSinceReferenceDate.bitPattern`; a `uuidSet` is written in ascending 16-byte order whatever the Set order.
    - `readerRejectsMalformedInput` (parameterized): truncated `u32`; text length beyond the remaining bytes; invalid UTF-8 text; `bool` byte `2`; optional tag `2`; `array(maxCount: 2)` with count 3; `uuidSet` out of order and with a duplicate ⇒ each throws `CredentialStoreError.malformed`.
    - `lengthPrefixesKeepFieldPairsDistinct`: `text("ab")+text("c")` bytes ≠ `text("a")+text("bc")` bytes.
    - `sqlNamesRoundTripEveryEnumCase`: for `VaultRole`, `RecordKind`, `RecordSubject`, `init(sqlName: x.sqlName) == x`; `RecordKind.trashEntry.sqlName == "trashEntry"`; unknown name ⇒ nil.
    - `frozenWrapperVectorStillUnwraps`: `CredentialVaultCrypto.unwrap(CredentialKeyWrapper(<recorded fields>), prf: …, profileID: …, vaultID: …)` returns `Data(repeating: 0x11, count: 32)` after Step 4's edit (wrapper AAD byte-identical).
  - `VaultOperationLockTests`
    - `exclusiveWaitsThenReportsStoreBusy`: hold shared; `acquire(exclusive, wait: .milliseconds(150))` throws `.storeBusy` and the elapsed time is ≥ 0.14 s.
    - `twoSharedHoldsCoexist`: two shared acquires both succeed.
    - `sharedHolderRequestingExclusiveTimesOutInsteadOfUpgrading`: the same task holds shared then requests exclusive with a 100 ms wait ⇒ `.storeBusy` and the shared hold is still held (a third shared acquire succeeds).
    - `exclusiveExcludesShared`: hold exclusive; shared acquire with 100 ms wait ⇒ `.storeBusy`.
    - `releaseIsIdempotentAndFreesTheLock`: `release()` twice does not crash; afterwards an exclusive acquire succeeds.
    - `deinitReleasesTheLock`: drop the only reference; exclusive acquire succeeds.
  - `VaultFileOpsTests` (real files in a temp directory, `StoreFileOps.live`)
    - `renameExclusiveNeverOverwrites`: destination exists ⇒ throws `StoreFileError.exists`; both files byte-identical to before; with a free destination the bytes move.
    - `renameSwapExchangesTwoFiles`: afterwards each path holds the other's former bytes.
    - `fullFsyncAndDirectoryFsyncSucceedOnARegularFileAndDirectory`: neither throws; `fullFsync` on a missing file throws `.io`.

- [ ] **Step 3: Run the tests to verify they fail.** Run: `PRO_TEST VaultPrimitivesTests VaultOperationLockTests VaultFileOpsTests`. Expected: build failure `cannot find 'StoreWriter' in scope` (and the other new types) — the expected RED for new API.

- [ ] **Step 4: Implement** the types above in the named files. `wrapperAAD` changes only its `format` operand to `StoreFormat.wrapperFormat`. `OperationLock` opens `Credentials.lock` with `O_CREAT|O_RDWR`, `0600`, creating the directory if absent; each `acquire` uses its own file descriptor (flock conflicts are per open file description, so in-process holders conflict). `StoreFileOps.live` maps errno: `EEXIST` ⇒ `.exists`, `ENOTSUP`/`EINVAL` on swap ⇒ `.unsupported`, else `.io(errno)`. `VaultTestSupport` bodies copy the patterns at `CredentialVaultTests.swift:32-82` (copy, do not edit that file).

- [ ] **Step 5: Run the tests to verify they pass.** Run: `PRO_TEST VaultPrimitivesTests VaultOperationLockTests VaultFileOpsTests CredentialVaultTests`. Expected: `** TEST SUCCEEDED **`; the three new suites list every test above; the existing `CredentialVaultTests` still pass (wrapper compatibility). Air: `git diff --check`.

- [ ] **Step 6: Commit** — `git add WSurf/Web/Credentials/Store WSurf/Web/Credentials/CredentialVaultCrypto.swift WSurfTests && git commit -m "feat(credentials): store primitives, operation lock and file ops"`. Then the review gate (§Execution).

### Task 2: Account model, content hash, semantic diff

**Files:**
- Create: `WSurf/Web/Credentials/Store/CredentialContent.swift`, `CredentialDiff.swift`
- Modify: `WSurf/Web/Credentials/CredentialAccount.swift` (new optional fields only)
- Test: `WSurfTests/Web/VaultAccountModelTests.swift`, `VaultContentTests.swift`, `VaultDiffTests.swift`

**Interfaces:**
- Consumes (Task 1): `RecordSubject`, `CredentialStoreError.metadataUndecodable`, `StoreWriter`; `VaultFixtures`. Existing: `ExchangeMetadata` (`CredentialExchangeCodec.swift:124-286`).
- Produces (`nonisolated`; every new field optional and Codable so v1 payloads decode):

```swift
struct CredentialEvents: Codable, Equatable, Sendable { var lastImportedAt, lastExportHandoffAt, remoteLastObservedAt: Date? }
struct ExchangeBase: Codable, Equatable, Sendable { var contentHash: Data; var itemID: Data? }      // accepted remote observation (§13.2a)
// CredentialAccount += var createdAt, modifiedAt, migratedAt: Date?; var passwordEvents, totpEvents: CredentialEvents?; var passwordBase, totpBase: ExchangeBase?
// WebsitePasskey   += var events: CredentialEvents?; var base: ExchangeBase?
extension CredentialAccount { func stampingCreation(at now: Date) -> CredentialAccount }              // sets createdAt = modifiedAt = now, nothing else
enum CredentialPart: Equatable, Sendable { case password(CredentialAccount), totp(CredentialAccount), passkey(WebsitePasskey), metadata(CredentialAccount) }
enum CredentialContent { static func hash(_ part: CredentialPart) -> Data }                          // §12.3: SHA-256 over StoreWriter encoding of the part's semantic fields
struct MetadataProjection: Codable, Equatable, Sendable { var displayName: String?; var origins: [String]; var loginURLs: [URL]; var exchange: Data?; var exchangeAccountID: Data?; var exchangeItemID: Data? }
enum PersistenceClass: Equatable, Sendable { case noop, persistOnly, semantic }
struct RevisionDraft: Equatable, Sendable { let ownerID: UUID; let subject: RecordSubject; let superseded: Data }   // Codable plaintext of the superseded value
enum RemovalScope: Equatable, Sendable { case account(UUID), credential(ownerID: UUID, subject: RecordSubject, passkeyID: UUID?) }
struct CredentialChangePlan: Equatable, Sendable { let persistence: PersistenceClass; let revisions: [RevisionDraft]; let removals: [RemovalScope]; let touched: Set<UUID>; let setsModifiedAt: Set<UUID> }
enum CredentialDiff { static func plan(old: [CredentialAccount], new: [CredentialAccount]) throws -> CredentialChangePlan }   // throws CredentialStoreError.metadataUndecodable
```
Hash field set (plan decision, pinned by the tests): password = `username` + `password`; TOTP = every stored TOTP field except none (no dates exist on it); passkey = `rpID` lower-cased, `credentialID`, `userHandle`, and the public key from `PasskeyKeyEncoding.importPKCS8` re-exported (raw DER inequality of the same key does not change the hash); metadata = `MetadataProjection`.

- [ ] **Step 1: Write the failing tests.**
  - `VaultAccountModelTests`: `v1AccountJSONWithoutNewFieldsDecodesWithNils` (a JSON literal of an account with only today's keys ⇒ every new field `nil`); `newFieldsRoundTripThroughCodable`; `stampingCreationSetsOnlyCreatedAtAndModifiedAt` (`migratedAt`, events, bases stay nil; an account built by the migration/import paths has `createdAt == nil`).
  - `VaultContentTests`: `hashIgnoresTimestampsCountersAndExchangeDates` (password part unchanged when `modifiedAt`, events or bases change; passkey part unchanged when `lastSignedAt`/`events`/counter change); `hashChangesForEverySemanticField` (changing `username`, `password`, each TOTP field, `rpID`, `credentialID`, `userHandle`, the private key, `origins`, `loginURLs`, `displayName` each changes exactly the owning part's hash and no other part's); `equivalentPasskeyDERHashesEqual` (same key re-encoded) ; `hashIsStable` (fixed fixture ⇒ fixed 32-byte hex literal).
  - `VaultDiffTests` (one test per §11.1 row): `passwordReplaceMakesARevision`, `usernameReplaceMakesARevision`, `basicAuthReplaceMakesARevision`, `totpReplaceMakesARevision`, `metadataChangeMakesAMetadataRevisionWithoutSecrets` (the `superseded` bytes decode as `MetadataProjection` and contain no password/TOTP/passkey/basic-auth value), `passkeyRemovalIsARemovalNotARevision`, `passkeyAddLastSignedAtAndFIDO2RefreshMakeNoRevision`, `exchangeDateOnlyChangeMakesNoRevision`, `trueNoopIsNoop` (identical lists ⇒ `.noop`, no revisions, empty `touched`), `hashUnchangedButPayloadDifferentIsPersistOnly` (`lastSignedAt` change ⇒ `.persistOnly`, no revisions, `setsModifiedAt` empty), `semanticChangeSetsModifiedAtOnlyForChangedAccounts`, `clearingPasswordTOTPAndRemovingAPasskeyInOneEditYieldsRemovalsAndNoRevisionForThem`, `combinedEditMakesOneRevisionPerChangedKind` (password+TOTP+websites with a passkey ⇒ revisions for password, totp, metadata only; the passkey untouched), `unchangedDraftPreservesPasskeysAndTOTP`, `undecodableExchangeMetadataThrowsMetadataUndecodableWhenSuperseded`, `accountRemovedFromTheNewListIsAnAccountRemoval`.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultAccountModelTests VaultContentTests VaultDiffTests`. Expected: build failure `cannot find 'CredentialDiff' in scope` / missing members on `CredentialAccount`.

- [ ] **Step 3: Implement** the new `CredentialAccount`/`WebsitePasskey` optional fields in `CredentialAccount.swift` (decode with `decodeIfPresent`; existing initializers keep compiling because every new field has a default of `nil`), then `CredentialContent` and `CredentialDiff`. `CredentialDiff.plan` classifies each account pair by comparing `CredentialContent.hash` per part and the complete Codable payload; password/TOTP/metadata changes produce `RevisionDraft`s, a cleared password/TOTP or removed passkey/account produces `RemovalScope`s. The blocked-origin policy is not an account property and never enters the plan. No exchange code is edited here.

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultAccountModelTests VaultContentTests VaultDiffTests CredentialAccountSelectionTests CredentialExchangeTests`. Expected: `** TEST SUCCEEDED **`; existing suites unchanged and green. Air: `git diff --check`.

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials WSurfTests && git commit -m "feat(credentials): account dates, content hash and semantic diff"`. Review gate.

### Task 3: Sealed formats, policy-bearing head, registry, SQL tables

**Files:**
- Create: `WSurf/Web/Credentials/Store/StoreRecords.swift`, `StoreSeal.swift`, `StoreTables.swift`
- Test: `WSurfTests/Web/VaultSealTests.swift`, `VaultTablesTests.swift`

**Interfaces:**
- Consumes (Task 1): all enums, `StoreWriter/Reader`, `CredentialStoreError`, `StoreFormat`; GRDB `Database`; `CredentialAccount.origin(for:)`.
- Produces (`nonisolated`; exact):

```swift
struct StoreIDs: Equatable, Sendable { let storeID: UUID; let profileID: UUID }
struct VaultLink: Equatable, Sendable { let peerVaultID: UUID; let nonce: Data }
struct LiveEntry: Equatable, Sendable { let recordID: UUID; let version: UInt64; let digest: Data }
struct HistoryCounts: Equatable, Sendable { var revision = 0, trashEntry = 0, tombstone = 0 }
struct VaultHead: Equatable, Sendable { var ids: StoreIDs; var vaultID: UUID; var role: VaultRole; var revision: UInt64; var name: String
  var registryKey: Data?; var blockedOrigins: [String]; var link: VaultLink; var liveCatalog: [LiveEntry]
  var journalSeq: UInt64; var chainTip: Data; var historyCounts: HistoryCounts }     // blockedOrigins: §7 Planning Clarification; sorted by UTF-8 bytes, unique, ≤ 4096, canonical origins; empty on trash heads
struct TransferHeader: Equatable, Sendable { var transferID: UUID; var direction: TransferDirection; var scope: TransferScope; var ownerID: UUID; var subject: RecordSubject?; var liveRecordID: UUID; var liveVersion: UInt64; var entryRecordID: UUID }
struct JournalOp: Equatable, Sendable { var op: JournalOpKind; var recordID: UUID; var kind: RecordKind; var ownerID: UUID; var subject: RecordSubject; var version: UInt64; var rowDigest: Data }
struct JournalRow: Equatable, Sendable { var seq: UInt64; var prevChain: Data; var transfer: TransferHeader?; var ops: [JournalOp] }
struct RowAAD: Equatable, Sendable { var ids: StoreIDs; var vaultID: UUID; var recordID: UUID; var kind: RecordKind; var ownerID: UUID; var subject: RecordSubject; var version: UInt64 }
struct RegistryEntry: Equatable, Sendable { var vaultID: UUID; var role: VaultRole; var ordinal: Int; var createdAt: Date; var wrappersDigest: Data; var keyWrapDigest: Data; var headRevision: UInt64; var headDigest: Data }
struct RegistryCatalog: Equatable, Sendable { var ids: StoreIDs; var revision: UInt64; var vaults: [RegistryEntry]   // encode() sorts by vaultID
  func encode() -> Data; static func decode(_ data: Data) throws -> RegistryCatalog }
enum StoreSeal {
  static func digest(_ stored: Data) -> Data                                  // SHA-256
  static func digestOrZero(_ stored: Data?) -> Data                            // absent ⇒ Data(count: 32)
  static func sealRow(_ plaintext: Data, key: SymmetricKey, aad: RowAAD) throws -> Data            // nonce‖ciphertext‖tag
  static func openRow(_ sealed: Data, key: SymmetricKey, aad: RowAAD) throws -> Data
  static func encodeHead(_ head: VaultHead) -> Data                            // plaintext encoding, no validation
  static func sealHead(_ head: VaultHead, key: SymmetricKey, wrappersDigest: Data, keyWrapDigest: Data) throws -> Data   // validates policy (§7) then sealHeadPlaintext
  static func sealHeadPlaintext(_ plaintext: Data, key: SymmetricKey, ids: StoreIDs, vaultID: UUID, revision: UInt64, wrappersDigest: Data, keyWrapDigest: Data) throws -> Data
  static func openHead(_ sealed: Data, key: SymmetricKey, ids: StoreIDs, vaultID: UUID, revision: UInt64, wrappersDigest: Data, keyWrapDigest: Data) throws -> VaultHead   // non-canonical policy ⇒ .malformed
  static func sealJournal(_ row: JournalRow, key: SymmetricKey, ids: StoreIDs, vaultID: UUID) throws -> Data
  static func openJournal(_ sealed: Data, key: SymmetricKey, ids: StoreIDs, vaultID: UUID, seq: UInt64) throws -> JournalRow
  static func chain(_ prev: Data, sealed: Data) -> Data                        // SHA-256(prev ‖ SHA-256(sealed)); chain_0 = 32 zero bytes
  static func registryMAC(rk: Data, catalog: Data) -> Data                     // HMAC-SHA256(rk, registryLabel ‖ catalog)
  static func verifyRegistryMAC(rk: Data, catalog: Data, mac: Data) -> Bool    // constant-time compare
  static func wrapTrashKey(_ trash: SymmetricKey, under source: SymmetricKey, ids: StoreIDs, source: UUID, trash trashID: UUID, nonce: Data) throws -> Data
  static func unwrapTrashKey(_ keyWrap: Data, under source: SymmetricKey, ids: StoreIDs, source: UUID, trash trashID: UUID, nonce: Data) throws -> SymmetricKey }
enum StoreTables {                                                              // SQL layer; GRDB Database in, values out
  struct VaultRow: Equatable, Sendable { var vaultID: UUID; var role: VaultRole; var ordinal: Int; var createdAt: Date; var wrappers: Data?; var keyWrap: Data? }
  struct RecordRow: Equatable, Sendable { var vaultID: UUID; var recordID: UUID; var kind: RecordKind; var ownerID: UUID; var subject: RecordSubject; var version: UInt64; var sealed: Data }
  static func create(in db: Database, ids: StoreIDs) throws                      // §5 DDL + the single store_meta row (schema 2)
  static func storeMeta(_ db: Database) throws -> (schema: Int, ids: StoreIDs)?
  static func insertVault(_ db: Database, _ row: VaultRow) throws;   static func vaultRows(_ db: Database) throws -> [VaultRow]
  static func putHead(_ db: Database, vaultID: UUID, revision: UInt64, sealed: Data) throws;   static func head(_ db: Database, vaultID: UUID) throws -> (revision: UInt64, sealed: Data)?
  static func putRecord(_ db: Database, _ row: RecordRow) throws               // insert or replace by (vaultID, recordID)
  static func deleteRecord(_ db: Database, vaultID: UUID, recordID: UUID) throws;   static func record(_ db: Database, vaultID: UUID, recordID: UUID) throws -> RecordRow?
  static func putJournal(_ db: Database, vaultID: UUID, seq: UInt64, sealed: Data) throws
  static func putRegistry(_ db: Database, revision: UInt64, catalog: Data, mac: Data) throws;   static func registry(_ db: Database) throws -> (revision: UInt64, catalog: Data, mac: Data)? }
```
AAD fields are written with `StoreWriter` in the order listed in spec §5/§7 (label, schema, storeID, profileID, vaultID, recordID, kind, ownerID, subject, version for rows; schema, storeID, profileID, vaultID, head revision, wrappers digest, keyWrap digest for heads; schema, storeID, vaultID, seq for journals; schema, storeID, profileID, source, trash, nonce for the trash key wrap). Head plaintext field order is the §7 block with `blockedOrigins` directly after `registryKey` (optional bytes).

- [ ] **Step 1: Write the failing tests.**
  - `VaultSealTests`
    - `headJournalRowAndRegistryRoundTrip`: seal/open each with a fixed key; every field equal, including `blockedOrigins == ["https://a.example", "https://b.example"]`.
    - `rowAADBindsEachListedField` (parameterized over `storeID, profileID, vaultID, recordID, kind, ownerID, subject, version`): open with that one field changed ⇒ throws; the row AAD binds the row's own `version`, not any head revision.
    - `headAADBindsWrappersKeyWrapRevisionAndIdentity`: change each of `wrappersDigest`, `keyWrapDigest`, `revision`, `vaultID`, `ids` ⇒ `openHead` throws.
    - `headWithUnsortedDuplicateOversizeOrNonCanonicalOriginsIsMalformed`: craft plaintexts with `encodeHead` + `sealHeadPlaintext` (unsorted pair, duplicate, 4,097 entries, `"https://a.example/path"`) ⇒ `openHead` throws `.malformed`; `sealHead` refuses the same inputs with `.malformed`.
    - `editedPolicyByteFailsTheHeadOpen`: flip one ciphertext byte inside the policy region ⇒ `openHead` throws.
    - `registryMACRejectsAnyCatalogByteChange` and `registryCatalogEncodingIsSortedByVaultID` (input order irrelevant, decode(encode) equal).
    - `registryKeyCannotOpenAnythingElse`: take the RK from an opened head; using it as a `SymmetricKey` for `openRow`, `openHead`, `unwrapTrashKey` each throws; a registry MAC computed with a DEK's bytes in place of RK fails `verifyRegistryMAC`.
    - `journalChainIsRecomputedFromStoredBytes`: three sealed journal rows ⇒ `chain` result equals a manual SHA-256 computation; reordering two rows changes the tip.
    - `trashKeyWrapOpensOnlyUnderTheSourceKeyAndLink`: right key/ids/nonce opens; wrong source key, wrong nonce, wrong trash id each throws.
    - `wrongProfileStoreOrVaultFailsOpen`.
  - `VaultTablesTests`
    - `createBuildsSchemaAndSingleMetaRow`: `storeMeta == (2, ids)`; a second `create` on the same database throws.
    - `roleAndKindConstraintsRejectUnknownValues`: raw SQL insert of role `"x"` / kind `"y"` fails.
    - `recordsRoundTripAndReplaceByPrimaryKey`; `deleteRecordRemovesOnlyThatRow`; `headRegistryAndJournalRoundTripExactBytes`.
    - `vaultRowsReturnWrappersAndKeyWrapExactlyAsStored`.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultSealTests VaultTablesTests`. Expected: build failure `cannot find 'StoreSeal' in scope`.

- [ ] **Step 3: Implement** `StoreRecords.swift` (value types and their `StoreWriter`/`StoreReader` encodings with the bounds above), `StoreSeal.swift` (AES-GCM combined boxes with the AADs above) and `StoreTables.swift` (GRDB, parameterized SQL, canonical lower-case UUID strings in text columns, `ordinal`, `createdAt` as REAL).

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultSealTests VaultTablesTests`. Expected: `** TEST SUCCEEDED **` with every test above listed. Air: `git diff --check`.

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials/Store WSurfTests && git commit -m "feat(credentials): sealed store formats, registry and tables"`. Review gate.

### Task 4: Anchors and open-state machine

**Files:**
- Create: `WSurf/Web/Credentials/Store/StoreAnchors.swift`
- Test: `WSurfTests/Web/VaultStoreStateTests.swift`

**Interfaces:**
- Consumes (Task 1): `StoreIDs`? — no, `StoreIDs` is Task 3's; Task 4 consumes Task 3 `StoreIDs`, Task 1 `StoreFailClosed`, `StoreFileOps`, `StoreFileError`, `CredentialStoreError`; existing `CredentialVaultCrypto.decodeEnvelope`; `VaultTestEnvironment`.
- Produces:

```swift
enum StoreOpenState: Equatable, Sendable { case legacy(vaultID: UUID), firstRun, provisional(storeID: UUID, stubMissing: Bool), resumeMigration(storeID: UUID), failClosed(StoreFailClosed) }
enum StoreAnchors {
  static let witnessKey = "io.wsagency.wsurf.credentialVault.storeID"
  static func evaluate(directory: URL, profileID: UUID, defaults: UserDefaults) -> StoreOpenState                  // §6.3 rows 1-13; never writes
  static func stubBytes(ids: StoreIDs) -> Data                                                                     // binary plist {format: 2, profileID, storeID}
  static func writeStubIfAbsent(directory: URL, ids: StoreIDs, fileOps: StoreFileOps = .live) throws               // temp file + fullFsync + renameExclusive to Credentials.vault + fsyncDirectory; existing file ⇒ StoreFileError.exists
  static func setWitnessIfAbsent(_ storeID: UUID, defaults: UserDefaults) -> Bool }                                // false = present (never overwritten)
```
Reading rules (plan decisions): A2 = `Credentials.vault` (v1 if `CredentialVaultCrypto.decodeEnvelope` succeeds, stub if it decodes as the stub plist, else unreadable); A1 = `Credentials.store`, "present" when the file has the SQLite header and `store_meta` is readable through a **read-only connection opened with the `immutable=1` URI parameter** so that evaluating never creates `-wal`/`-shm` (the authoritative re-read happens under the operation lock in Task 6; creation always checkpoints, Task 9); A3 = `defaults.string(forKey: witnessKey)`. A `profileID` mismatch ⇒ `.failClosed(cause: .wrongProfile)`. `StoreFailClosed.paths` are absolute and list `Credentials.store`, `-wal`, `-shm`, `Credentials.vault` and `Credentials.store.migrating` as present, plus `Credentials.vault.swap`, every `Credentials.vault.cutover-v1*` and `Credentials.vault.pre-v2` **only when they exist**; `preMigrationBackup` is the `.pre-v2` URL when present.

- [ ] **Step 1: Write the failing tests** (`VaultStoreStateTests`; each builds real files in a `VaultTestEnvironment` directory, a v1 file via `CredentialVaultCrypto.encodeEnvelope`, a store via `StoreTables.create`, a stub via `stubBytes`):
  - `everyRowOfTheStateTableYieldsItsOutcome`: parameterized, explicit expected `StoreOpenState` for rows 1-12 exactly as spec §6.3 (row 1 `.legacy(vaultID)`, 2 `.failClosed(.v1AfterMigration)`, 3 `.failClosed(.v1AfterMigration)`, 4 `.provisional(storeID, stubMissing: false)` for A3 absent and for A3 agreeing, 5 `.failClosed(.foreignStore)`, 6 `.resumeMigration(storeID)` only with `Credentials.store.migrating` carrying the stub's `storeID` and no `cutover-v1*`, else `.failClosed(.storeMissing)`, 7 `.provisional(storeID, stubMissing: true)`, 8 `.failClosed(.witnessMismatch)`, 9 `.failClosed(.storeMissing)`, 10 `.firstRun`, 11 `.failClosed(.unreadableVault)`, 12 `.failClosed(.unreadableStore)`).
  - `cutoverFileWinsOverEveryOtherRow`: with `Credentials.vault.cutover-v1-<UUID>` present, rows 1, 4, 10 all return `.failClosed(.cutoverV1Present)` listing the file.
  - `firstRunIsOfferedOnlyWithoutLeftovers`: with each of `Credentials.store.migrating`, `Credentials.vault.swap`, `Credentials.vault.cutover-v1`, `Credentials.vault.pre-v2` present, row 10 returns `.failClosed(.leftoversWithoutAuthority)` and never `.firstRun`.
  - `evaluateWritesNothing`: for every row fixture, the directory's file names, sizes and bytes and the `defaults` dictionary are identical before and after `evaluate` (no `-wal`/`-shm`/scratch appears).
  - `failClosedPathsAreAbsoluteAndListOnlyExistingOptionalFiles`: all paths absolute; `.pre-v2` listed (and `preMigrationBackup` set) only when present; `.swap` and `cutover-v1*` only when present.
  - `wrongProfileInStubOrStoreFailsClosed`.
  - `stubWriteNeverOverwritesAnExistingV1File`: a v1 file at `Credentials.vault` ⇒ `writeStubIfAbsent` throws `StoreFileError.exists`, bytes unchanged, no temp file left behind.
  - `stubWriteCreatesTheStubWhenAbsent`: afterwards `evaluate` sees the stub (row 4/6/7 as fixtures dictate).
  - `witnessIsSetOnlyWhenAbsent`: first call true and stored; second call with a different id returns false and the stored value is unchanged.
  - `oldReaderRejectsTheStubAsCorrupt`: `CredentialVaultCrypto.decodeEnvelope(stubBytes(...), profileID:)` throws `CredentialVaultError.corruptVault`.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultStoreStateTests`. Expected: build failure `cannot find 'StoreAnchors' in scope`.

- [ ] **Step 3: Implement** `StoreAnchors` per the signatures and reading rules above (leftover-file names are fixed constants in this file; `cutover-v1*` is matched by directory enumeration for the prefix `Credentials.vault.cutover-v1`).

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultStoreStateTests`. Expected: `** TEST SUCCEEDED **`. If the `immutable=1` read misreads a store whose `store_meta` is only in the WAL, stop and report to Main (the plan assumes creation checkpoints). Air: `git diff --check`.

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials/Store/StoreAnchors.swift WSurfTests && git commit -m "feat(credentials): store anchors and open-state machine"`. Review gate.

### Task 5: Verification V1-V5 and scratch ledger

**Files:**
- Create: `WSurf/Web/Credentials/Store/StoreVerifier.swift`, `VerificationScratch.swift`; `WSurfTests/Helpers/VaultStoreFixture.swift`
- Test: `WSurfTests/Web/VaultIntegrityTests.swift`, `VaultVerificationBenchmark.swift`

**Interfaces:**
- Consumes (Task 3): `StoreSeal`, `StoreTables`, `VaultHead`, `RegistryCatalog`, `JournalRow`, `StoreIDs`; (Task 1) `CredentialStoreError`, `StoreFormat`.
- Produces:

```swift
struct VerifiedVault: Sendable { let vaultID: UUID; let head: VaultHead }
final class StoreVerifier { init(db: Database, ids: StoreIDs, scratchDirectory: URL)
  func verify(source: (id: UUID, key: SymmetricKey, head: VaultHead), trash: (id: UUID, key: SymmetricKey, head: VaultHead), isCancelled: () -> Bool) throws   // V1-V5; throws CredentialStoreError.integrityFailure(vaultOrdinal:) or CancellationError
}
enum VerificationScratch { static func directory(in supportDirectory: URL) -> URL            // <support>/Credentials.scratch
  static func cleanLeftovers(in supportDirectory: URL) }                                      // removes every file in the scratch directory
// WSurfTests/Helpers/VaultStoreFixture.swift
struct VaultStoreFixture { let env: VaultTestEnvironment; let ids: StoreIDs; let storeURL: URL; let vaultID: UUID; let trashID: UUID
  let dek: SymmetricKey; let trashDEK: SymmetricKey; let registryKey: Data; let proof: VaultUnlockProof
  static func make(accounts: [CredentialAccount] = [], blockedOrigins: [String] = [], historyRows: Int = 0) throws -> VaultStoreFixture   // writes a complete valid store with sealed rows, heads, journals, registry via Task 3 APIs
  func mutate(_ body: (Database) throws -> Void) throws }                                      // raw tamper access for tests
```
V1 head: opens; AAD fields, `storeID`, `profileID`, `vaultID`, `role` match; plaintext revision equals the sealed revision; link nonce matches the peer; **`blockedOrigins` canonical (§7 clarification)**. V2 live rows; V3 journal chain; V4 history ledger in the scratch DB; V5 transfer pairs — exactly as spec §7.

- [ ] **Step 1: Write the failing tests** (`VaultIntegrityTests`; each tamper is applied through `fixture.mutate` or by re-sealing, then `verify` must throw `integrityFailure`):
  - `validFixtureVerifies` (with 3 accounts, 5 history rows, blocked origins).
  - `tamperClassesFailVerification` (parameterized): altered live row ciphertext; deleted live row; substituted live row from another vault; replayed older version of a live row; foreign (other store) row; wrong digest column with valid bytes; ciphertext swapped while the head catalog digest is left alone; truncated journal; reordered journal rows; forged journal row; missing chain row; stale head (older sealed head under the same revision column); transfer-pair mismatch (missing/duplicated/mismatched `out`/`in` group); wrong profile in the head.
  - `nonCanonicalBlockedOriginsFailV1`: a head sealed with `sealHeadPlaintext` carrying an unsorted list ⇒ `integrityFailure`; a head whose blocked list was edited after sealing ⇒ `integrityFailure`.
  - `deleteUndeleteDeleteAndLongerAlternationsVerify`: fixtures built with 1, 2 and 3 MOVE round trips verify; the historical transfer header is never compared with the current catalogs.
  - `zeroHistoryAccountMoveVerifiesWithEmptyMovedSet`.
  - `movedRowsWithDifferentCiphertextDigestsButEqualKeyVerify`.
  - `scratchLivesInTheScratchDirectoryWithRestrictedModesAndIsRemoved`: during verification (observed through a hook-free approach: run `verify` with `isCancelled` flipping true after the first row) the directory `Credentials.scratch` has mode `0700` and the `.db` file `0600`; after success, after an `integrityFailure`, and after cancellation the directory holds no file.
  - `scratchHoldsOnlyOpaqueIds`: after a verification that is cancelled mid-way leaving the file for inspection (test reads it before removal by setting `isCancelled` and copying within the callback), scanning the SQLite file for the planted account username and vault name finds neither.
  - `cleanLeftoversRemovesPlantedFiles`; `cancellationYieldsNoResultAndRemovesScratch`.
  - `streamingHistoryStaysWithinAMemoryBudget`: 20,000 small history rows verify with a resident-size delta (via `task_info` `MACH_TASK_BASIC_INFO`) below 64 MB.
  - `VaultVerificationBenchmark` (tagged `.benchmark`, **Pro only**, excluded from the default run; run by Tasks 16/17): a ≥ 1 GB history verifies with bounded resident size and a reported wall time.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultIntegrityTests`. Expected: build failure `cannot find 'StoreVerifier' in scope`.

- [ ] **Step 3: Implement** `VaultStoreFixture` (writes through Task 3 APIs only) and `StoreVerifier`: one GRDB read transaction by the caller; `ATTACH` the scratch file `<support>/Credentials.scratch/<UUID>.db` (`journal_mode=OFF`, `synchronous=OFF`, directory `0700`, file `0600`, removed in `defer` on every exit), never `TEMP`/`temp_store_directory`; V4/V5 stream rows one at a time into scratch tables; any failure maps to `integrityFailure(vaultOrdinal:)`.

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultIntegrityTests`. Expected: `** TEST SUCCEEDED **`. Air: `git diff --check`.

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials/Store WSurfTests && git commit -m "feat(credentials): per-vault integrity verification"`. Review gate.

### Task 6: Store core: open, unlock pipeline, wrappers, password-save policy

**Files:**
- Create: `WSurf/Web/Credentials/Store/StoreSnapshot.swift`, `ProfileVaultStore.swift`, `ProfileVaultStore+Unlock.swift`, `ProfileVaultStore+HeadWrites.swift`
- Modify: `WSurfTests/Helpers/VaultStoreFixture.swift` (add `stubAbsent`, `secondVault`, `sharedProof` options and `unlocked(vaultID:) async throws -> (ProfileVaultStore, VaultAccess)` calling `unlockInitialized`). The v1 `VaultSnapshot` and `CredentialVault` are **not** touched here (they still serve the old manager until Task 10).
- Test: `WSurfTests/Web/VaultStoreUnlockTests.swift`, `VaultStoreWrapperTests.swift`, `VaultStorePolicyTests.swift`

**Interfaces:**
- Consumes: Task 1 (`OperationLock`, `StoreFileOps`, `CredentialStoreError`, `StoreFormat`), Task 3 (`StoreSeal`, `StoreTables`, `VaultHead`), Task 4 (`StoreAnchors`, `StoreOpenState`), Task 5 (`StoreVerifier`, `VerificationScratch`), existing `VaultAccess`, `VaultUnlockProof`, `VaultDiscovery`, `VaultCommitReceipt`, `CredentialVaultCrypto.wrap/unwrap/validate`.
- Produces (`nonisolated`, `Sendable` unless stated; `ProfileVaultStore` is an `actor`):

```swift
struct AccountStamp: Equatable, Sendable { let version: UInt64; let digest: Data }   // from the verified liveCatalog
struct StoreSnapshot: Sendable { let vaultID: UUID; let revision: UInt64; let accounts: [CredentialAccount]; let blockedPasswordOrigins: Set<String>; let stamps: [UUID: AccountStamp] }   // every member REQUIRED, no defaults; the v2 snapshot type; v1 `VaultSnapshot` is deleted in Task 10
struct VaultListing: Equatable, Sendable { let vaultID: UUID; let ordinal: Int; let name: String?; let isUnlocked: Bool; let isVerified: Bool }   // name nil until unlocked
struct FreshAuthorization: Sendable { let credentialID: Data; let prf: SymmetricKey }
actor ProfileVaultStore {
  init(profileID: UUID, directory: URL, defaults: UserDefaults, fileOps: StoreFileOps = .live, lockWait: Duration = StoreFormat.lockWait,
       now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }, wall: @escaping @Sendable () -> Date = { Date() })
  func openState() -> StoreOpenState                                       // StoreAnchors.evaluate; never writes
  func listing() throws -> [VaultListing]                                  // ordinals only before unlock; throws failClosed
  func discovery(vaultID: UUID) throws -> VaultDiscovery                   // wrapper plaintext (credentialID, prfInput) only
  // Unlock engine, two layers. Task 6 completes ONLY the initialized-v2 (`StoreOpenState.provisional`) path; the public routing `unlock(...)` is Task 9's.
  func unlockInitialized(vaultID: UUID, credentialID: Data, prf: SymmetricKey, access: VaultAccess,
                         verifying: (@Sendable (Bool) -> Void)?) async throws   // OWNS the lock: picks SHARED (stub present) or EXCLUSIVE (stub absent) from openState(), acquires it, re-reads the state under it
                                                                                 // (other mode needed ⇒ release, reacquire, restart; never upgrade in place); `.failClosed` ⇒ throws it; any non-`.provisional` state ⇒ CredentialStoreError.stateChanged, nothing written;
                                                                                 // then calls unlockHeld and releases the lock
  func unlockHeld(_ held: OperationLockHold, mode: OperationLock.Mode, vaultID: UUID, credentialID: Data, prf: SymmetricKey, access: VaultAccess,
                  verifying: (@Sendable (Bool) -> Void)?) throws                // §6.8 steps 1-8 on an initialized v2 store under a lock the CALLER holds; never acquires or releases a lock; stub repair only when mode == .exclusive;
                                                                                 // `verifying(true)` past StoreFormat.verifyingThreshold, `verifying(false)` at the end; internal (not private) because Task 9's router consumes it
  func snapshot(vaultID: UUID, using access: VaultAccess) throws -> StoreSnapshot            // throws CredentialVaultError.unauthorized without a published grant (access/revision failures: existing CredentialVaultError cases; all others CredentialStoreError)
  func updatePasswordSavePolicy(vaultID: UUID, _ blocked: Set<String>, expectedRevision: UInt64, using access: VaultAccess) throws -> VaultCommitReceipt
  func addUnlock(vaultID: UUID, _ proof: VaultUnlockProof, using access: VaultAccess) throws -> VaultCommitReceipt
  func removeUnlock(vaultID: UUID, credentialID: Data, verifiedRemaining: VaultUnlockProof, using access: VaultAccess) throws -> VaultCommitReceipt
  func authorize(vaultID: UUID, _ authorization: FreshAuthorization, using access: VaultAccess) throws    // fresh-assertion check for purge; publishes nothing
  func lock(vaultID: UUID); func lock(ifUsing access: VaultAccess); func lockAll(); func close() }
```
Lock ownership: `unlockInitialized` is the only Task 6 function that acquires the operation lock for unlock; `unlockHeld` never does, so Task 9's router can call it under the exclusive lock it already holds without nesting. Legacy, first-run and resume states are not handled in Task 6 at all (Task 9 defines the public `unlockInitialized` that routes them). Policy semantics are the spec §7 Planning Clarification: head-only transaction, CAS `head.revision`, revision+1, registry entry updated, no row/journal/history write; equal set is a true no-op; commits and wrapper changes copy the head's set; `snapshot.blockedPasswordOrigins` is the head's set; count ≤ 4,096 (the source cap at `CredentialVaultCrypto.swift:125`, not a new cap) and each entry canonical.

- [ ] **Step 1: Write the failing tests** (every assertion at the store's public boundary, built from `VaultStoreFixture`):
  - `VaultStoreUnlockTests`
    - `grantIsPublishedOnlyAfterVerification`: before `unlockInitialized`, `snapshot` throws `.unauthorized`; after, it returns the fixture's accounts, `vaultID`, and `stamps` equal to the head's `liveCatalog` (version and digest per account).
    - `badAnchorStatesGrantNothing` (parameterized: foreign A3, A3 differing from stub and store, v1 beside a store, store missing, wrong profile): `unlockInitialized` throws `failClosed` with the expected `StoreFailCause`; `snapshot` still throws `unauthorized`; the directory and `defaults` are byte-identical to before.
    - `wrongPRFOrUnenrolledCredentialGrantsNothing`.
    - `registryFailuresAreStoreWide` (parameterized: forged MAC, registry row missing, older registry entry replayed, head swapped for another vault's head, wrapper list swapped, a second vault's rows removed, linked trash removed): `unlockInitialized` throws `integrityFailure`; afterwards **a healthy second vault also cannot be unlocked**.
    - `rowTamperFailsOnlyThatVault`: a live row of vault A altered ⇒ unlocking A throws `integrityFailure(vaultOrdinal: 1)`; vault B still unlocks; a linked-trash key wrap that does not open ⇒ same, only that vault.
    - `lockIsTakenBeforeAnyReadAndNeverUpgraded`: (a) the test holds an EXCLUSIVE `OperationLock` ⇒ `unlockInitialized` (store `lockWait: .milliseconds(150)`) throws `.storeBusy`, `verifying` is never called, no `-wal`/`-shm` appears; (b) store with the stub absent (EXCLUSIVE needed) while the test holds SHARED ⇒ throws `.storeBusy` and the stub is still absent (no in-place upgrade); (c) stub present while the test holds SHARED ⇒ unlock succeeds.
    - `verifyingCallbackFiresOnlyPastTheThreshold`: a constant clock ⇒ never called; a clock that steps 300 ms per read ⇒ `verifying(true)` then `verifying(false)`.
    - `accessRevokedDuringVerificationIsNeverPublished`: `verifying` revokes `access` ⇒ `unlockInitialized` throws; `snapshot` throws `unauthorized`.
    - `stubMissingIsRepairedOnlyAfterAuthenticatedUnlock`: row-7 fixture ⇒ before unlock the stub is absent and `commit`-class operations are unavailable; after unlock `StoreAnchors.evaluate` reports the stub present.
    - `v1FileAppearingBeforeStubRepairIsNeverOverwritten`: a `fileOps.renameExclusive` wrapper writes a v1 file at `Credentials.vault` then calls the live implementation ⇒ `unlockInitialized` fails closed (`v1AfterMigration`), the v1 bytes are unchanged.
    - `a3IsSetOnlyWhenAbsentAfterUnlock`: absent ⇒ set to the `storeID`; present and different ⇒ fail closed (covered above) and unchanged.
    - `sharedPasskeyOpensOnlyItsVault`: vaults A and B wrapped for the same credential; unlocking A ⇒ `snapshot(vaultID: B)` throws `unauthorized`.
    - `unlockInitializedRefusesEveryStateButProvisional`: `.legacy`, `.firstRun` and `.resumeMigration` directories ⇒ `CredentialStoreError.stateChanged`, directory and `defaults` byte-identical (the precondition Task 9's router relies on; it is permanent, not a placeholder).
    - `lockRevokesGrants`: `lock(vaultID:)`, `lock(ifUsing:)` (only the matching access) and `lockAll()` each make `snapshot` throw `unauthorized`.
    - `authorizeNeedsAFreshAssertionFromAnEnrolledCredential`: unenrolled credential or wrong `prf` ⇒ throws; correct ⇒ returns; a different `VaultAccess` still cannot `snapshot`.
  - `VaultStoreWrapperTests`
    - `addUnlockRewritesWrappersHeadAndRegistryOnly`: afterwards the new proof unlocks; every `record` and `journal` row is byte-identical to before; `listing`/unlock still verify.
    - `removeUnlockStopsOpeningSourceAndTrash`: the removed credential cannot unlock (throws), an access it held is revoked (`snapshot` throws `unauthorized`), the remaining credential still opens the vault and its linked trash.
    - `wrapperCapIs32`: the 33rd `addUnlock` throws `.limit(.wrappers)` and wrappers are unchanged.
    - `staleOrForeignAccessCannotChangeWrappers`: an access from another profile or an expired access throws `unauthorized`/expired and nothing changes.
  - `VaultStorePolicyTests`
    - `policyRoundTripsThroughSnapshotAndUnlock`: update to `{"https://a.example","https://b.example"}` ⇒ `snapshot.blockedPasswordOrigins` equals it, revision +1, a fresh unlock verifies the registry and returns the same set; no `record`/`journal` row changed.
    - `unchangedPolicyWritesNothing`: the same set again ⇒ revision, head and registry bytes identical.
    - `stalePolicyUpdateIsRefused`: wrong `expectedRevision` ⇒ `.staleRevision`.
    - `policyLimitsAreTheSourceLimits`: 4,096 canonical origins accepted; 4,097 ⇒ `.limit(.blockedOrigins)`; `"https://a.example/x"` ⇒ `.malformed`; nothing written in the refused cases.
    - `wrapperChangesPreservePolicy`: after `addUnlock` and `removeUnlock` the snapshot's set is unchanged.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultStoreUnlockTests VaultStoreWrapperTests VaultStorePolicyTests`. Expected: build failure `cannot find 'ProfileVaultStore' in scope`.

- [ ] **Step 3: Implement** `ProfileVaultStore` (GRDB pool opened with `foreign_keys=ON`, `journal_mode=WAL`, `synchronous=FULL`, `secure_delete=ON`, `busy_timeout 5000`; never `AppDatabase`, never in-memory) with the §6.8 order, split as `unlockInitialized` (lock owner) → `unlockHeld` (engine): choose the lock from `openState()`, acquire it, re-read the anchors under it (release/reacquire/restart if the other mode is needed), open one read transaction, steps 1-5, stub repair (EXCLUSIVE only) via `StoreAnchors.writeStubIfAbsent`, A3 via `setWitnessIfAbsent`, publish the grant while holding the lock unless the access epoch/generation changed. Wrapper and policy changes are `BEGIN IMMEDIATE` transactions that re-verify the registry with RK and compare this vault's own registry entry (else `staleRevision`).

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultStoreUnlockTests VaultStoreWrapperTests VaultStorePolicyTests VaultIntegrityTests CredentialVaultTests CredentialExchangeTests`. Expected: `** TEST SUCCEEDED **` listing every test above; the two neighbours (`CredentialVaultTests`, `CredentialExchangeTests`) prove the untouched v1 path still passes. Air: `git diff --check`.

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials WSurfTests && git commit -m "feat(credentials): profile vault store core, unlock pipeline and policy"`. Review gate (§Execution): `review-package` for this task's BASE..HEAD, spec-compliance and quality review, fixes re-reviewed, ledger row written, before Task 7 starts.

### Task 7: Commit and MOVE engine

**Files:**
- Create: `WSurf/Web/Credentials/Store/ProfileVaultStore+Commit.swift`, `ProfileVaultStore+Move.swift`, `StoreBodies.swift`
- Modify: `WSurfTests/Helpers/VaultStoreFixture.swift` (history/near-cap builders)
- Test: `WSurfTests/Web/VaultCommitTests.swift`, `VaultRevisionTests.swift`, `VaultMoveTests.swift`, `VaultMoveBenchmark.swift`

**Interfaces:**
- Consumes: Task 2 (`CredentialDiff`, `CredentialChangePlan`, `RemovalScope`, `CredentialContent`), Task 3 (sealing, tables), Task 6 (`ProfileVaultStore`, `StoreSnapshot`, `VaultAccess`).
- Produces (`nonisolated Sendable Codable`, row plaintext bodies; the row `kind` selects the body):

```swift
struct RevisionBody: Codable, Equatable, Sendable { var recordedAt: Date; var cause: String?; var value: Data }                // value = Codable plaintext of the superseded part (§11.1)
struct TrashEntryBody: Codable, Equatable, Sendable { var deletedAt: Date; var scope: TransferScope; var ownerID: UUID; var subject: RecordSubject?; var passkeyID: UUID?
  var label: String?; var snapshot: CredentialAccount?; var credentialValue: Data? }                                        // account scope ⇒ snapshot once; credential scope ⇒ credentialValue + label (≤256 B owner name, ≤256 B first origin)
struct TombstoneBody: Codable, Equatable, Sendable { var entryID: UUID; var purgedAt: Date; var scope: TransferScope; var ownerID: UUID; var subject: RecordSubject?
  var passkeyCredentialID: Data?; var rpID: String?; var exchangeAccountID: Data?; var exchangeItemID: Data? }              // no secret field exists
extension ProfileVaultStore {
  func commit(vaultID: UUID, _ accounts: [CredentialAccount], expectedRevision: UInt64, cause: String?, using access: VaultAccess) async throws -> VaultCommitReceipt
  func delete(vaultID: UUID, scope: RemovalScope, expectedRevision: UInt64, using access: VaultAccess) async throws -> VaultCommitReceipt }
```
`commit` classifies with `CredentialDiff.plan` against the snapshot it reads; removals inside a commit run through the same MOVE engine as `delete`. The transaction body that writes a `CredentialChangePlan` (rows, revisions, MOVEs, journal, heads, registry) is one internal `func write(_ plan: CredentialChangePlan, in tx: …)` reused by Task 12's per-account `commitAccounts`. `StoreFormat.historyRowBytes` (8,000,000) is the history-row cap; live caps are `CredentialVaultLimits`.

- [ ] **Step 1: Write the failing tests** (public boundary; "state" = rows read back through `StoreTables`, snapshots and `StoreVerifier`):
  - `VaultCommitTests`
    - `trueNoOpWritesNothing`: an identical complete payload leaves every row, the head and the registry byte-identical.
    - `persistOnlyChangeBumpsHeadWithoutHistory`: a passkey `lastSignedAt` change ⇒ head revision +1, registry updated, no revision/journal/history row, no `modifiedAt`; 20 TOTP-copy no-ops and 5 sign-ins create zero revisions.
    - `staleRevisionIsRefusedAndOtherVaultsCommitDoesNotInvalidate`: wrong `expectedRevision` ⇒ `.staleRevision`; a commit to vault B between this vault's snapshot and commit does not.
    - `liveLimitRefusalsNameTheLimit`: 1,001st account ⇒ `.limit(.accounts)`; payload over `CredentialVaultLimits.payloadBytes` ⇒ `.limit(.payloadBytes)`; nothing written.
    - `commitCopiesBlockedOriginsUnchanged`: the head's set survives a semantic commit and a persist-only commit.
    - `revokedOrOtherEpochAccessIsRefused`: `unauthorized`, nothing written.
  - `VaultRevisionTests` (one assertion set per §11.1 row): `passwordReplaceMakesOneRevisionAndSetsModifiedAt`, `usernameAndBasicAuthReplaceMakeRevisions`, `totpReplaceMakesARevision`, `metadataChangeStoresTheTypedProjectionWithoutSecrets` (decode the revision with the held DEK: contains no password/TOTP/passkey/basic-auth value), `exchangeDateOnlyChangeMakesNoRevision`, `combinedEditMakesOneRevisionPerChangedKindInOneTransaction` (password+TOTP+websites with a passkey: three revisions, passkey row bytes identical, one head bump), `provenanceIsExplicitOrNil` (`cause` nil stays nil; `recordedAt` equals the injected `wall`), `undecodableExchangeMetadataRefusesTheSupersedingCommit` (`.metadataUndecodable`, nothing written).
  - `VaultMoveTests`
    - `wholeAccountDeleteMovesLiveRowAndEveryOwnedRevision`: the account is absent from the snapshot; Trash holds one `trashEntry` with the snapshot once plus the revisions with their original `recordID`s and `version`s; the active vault holds no row of that owner; both vaults verify.
    - `singleCredentialDeleteLeavesAccountSiblingsAndMetadataRevisions`: only that credential's value and its `ownerID`+`subject` revisions move.
    - `removalByCommitIsAMoveWithNoActiveResidue`: a commit that clears the password, clears the TOTP and removes one passkey ⇒ three MOVEs in one transaction, each with its own history in Trash, and no `revision` row of those subjects remains in the active vault.
    - `moveWritesTransferRowsOnBothSidesEvenForEmptyHistory`: an account with no history ⇒ Trash journal has the `in` row (one `trashEntry` add), source journal the `out` row, same `transferID`; `StoreVerifier` passes.
    - `exactlyOneSecretBearingLogicalCopy`: after delete, decrypting every reachable active-vault record finds the planted password nowhere; Trash holds it once.
    - `failureMidMoveRollsBackWhole`: an injected SQLite error after N rows (parameterized N = 0, 1, mid, last) leaves rows, heads, journals and registry as seen through the API unchanged and verification passing.
    - `deleteAtLiveCapAndWithManyVaultsAlwaysWorks`: with 1,000 accounts, at the payload cap, and with 16 vaults, `delete` succeeds.
    - `nearCapAccountWithComparableRevisionsDeletes`: a ≈4,000,000 B account with revisions of comparable size deletes; every history row ≤ 8,000,000 B.
    - `deleteUndeleteDeleteStillVerifies` is Task 8's (it needs `undelete`); here: `consecutiveDeletesOfDifferentAccountsVerify`.
  - `VaultMoveBenchmark` (tag `.benchmark`, Pro only, excluded from the default run, executed by Task 16): an account whose history exceeds 32 MB and a 1 GB history delete with a bounded resident-size delta.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultCommitTests VaultRevisionTests VaultMoveTests`. Expected: build failure `value of type 'ProfileVaultStore' has no member 'commit'`.

- [ ] **Step 3: Implement** `commit` and `delete` in `BEGIN IMMEDIATE` transactions: CAS this vault's `head.revision`, re-read and verify the registry with RK, compare this vault's (and its trash's) registry entries with the session's, write rows, append journal rows (≤ `StoreFormat.journalOpsPerRow` ops each, a MOVE's `transfer` header on both sides), seal both heads (history counts, `liveCatalog`, `chainTip`), rewrite the registry. The MOVE streams one history row at a time (decrypt under the source DEK, re-seal under the destination DEK keeping `recordID`, `kind`, `ownerID`, `subject` and the origin `version`). Bodies are the Codable types above; live account rows keep today's `CredentialAccount` encoding.

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultCommitTests VaultRevisionTests VaultMoveTests VaultIntegrityTests VaultDiffTests`. Expected: `** TEST SUCCEEDED **` with every test above listed.

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials/Store WSurfTests && git commit -m "feat(credentials): atomic commit, revisions and MOVE to linked Trash"`. Review gate (§Execution).

### Task 8: Undelete, earlier versions, purge, listings, removed identifiers

**Files:**
- Create: `WSurf/Web/Credentials/Store/ProfileVaultStore+History.swift`, `ProfileVaultStore+Purge.swift`
- Test: `WSurfTests/Web/VaultTrashTests.swift`, `VaultPurgeTests.swift`, `VaultResidueTests.swift`

**Interfaces:**
- Consumes: Task 1 (`UndeleteBlock`, `RecordSubject`, `TransferScope`), Task 6 (`FreshAuthorization`, `authorize`), Task 7 (`delete`, `commit`, bodies, MOVE engine).
- Produces (`nonisolated Sendable`; methods in `extension ProfileVaultStore`):

```swift
struct TrashItem: Identifiable, Equatable, Sendable { let id: UUID; let scope: TransferScope; let ownerID: UUID; let subject: RecordSubject?; let label: String; let revisionCount: Int }
struct RevisionItem: Identifiable, Equatable, Sendable { let id: UUID; let subject: RecordSubject; let version: UInt64; let recordedAt: Date; let cause: String? }
struct TrashPage: Sendable { let items: [TrashItem]; let next: Int? }
struct RevisionPage: Sendable { let items: [RevisionItem]; let next: Int? }
struct UndeletePreview: Sendable { let entry: TrashItem; let block: UndeleteBlock? }
struct PurgeReceipt: Equatable, Sendable { let removedEntries: Int; let revision: UInt64 }
struct RemovedIdentifier: Equatable, Sendable { let entryID: UUID; let isTombstone: Bool; let accountID: UUID; let exchangeAccountID: Data?; let exchangeItemID: Data?; let passkeyCredentialID: Data?; let rpID: String? }
struct RemovedIdentifiers: Equatable, Sendable { let items: [RemovedIdentifier] }
func trashPage(vaultID: UUID, after: Int?, using access: VaultAccess) throws -> TrashPage                    // pages of StoreFormat.historyPage = 50
func revisionPage(vaultID: UUID, accountID: UUID, after: Int?, using access: VaultAccess) throws -> RevisionPage
func previewUndelete(vaultID: UUID, entryID: UUID, using access: VaultAccess) throws -> UndeletePreview
func undelete(vaultID: UUID, entryID: UUID, expectedRevision: UInt64, using access: VaultAccess) async throws -> VaultCommitReceipt   // throws .undeleteBlocked(UndeleteBlock), nothing written
func previewRestoreRevision(vaultID: UUID, revisionID: UUID, using access: VaultAccess) throws -> CredentialAccount
func restoreRevision(vaultID: UUID, revisionID: UUID, expectedRevision: UInt64, using access: VaultAccess) async throws -> VaultCommitReceipt
func purge(vaultID: UUID, entryIDs: [UUID], emptyAll: Bool, authorization: FreshAuthorization, using access: VaultAccess) async throws -> PurgeReceipt
func removedIdentifiers(vaultID: UUID, using access: VaultAccess) throws -> RemovedIdentifiers               // ids only, streamed; never secrets
```

- [ ] **Step 1: Write the failing tests:**
  - `VaultTrashTests`
    - `deleteUndeleteRoundTripLeavesOneLogicalCopyWithFullHistory`: the account is live again with its revisions, Trash holds nothing of it, both vaults verify.
    - `deleteUndeleteDeleteAndLongerAlternationsVerify` (item 18): three and five alternations; `StoreVerifier` passes each time.
    - `everyWholeAccountCollisionBlocks` (parameterized: live account id, live `exchangeAccountID`/`exchangeItemID`, origin+username overlap, passkey `rpID`+`credentialID`): `previewUndelete.block` names it, `undelete` throws `.undeleteBlocked(<same case>)`, every row/head/registry byte is identical afterwards; then the test deletes the conflicting live item and the **same** `undelete` succeeds.
    - `singleCredentialUndeleteRules` (item 19): with the owner live, a password, a TOTP and a passkey entry each restore; blocked by an occupied password/TOTP slot (`.slotOccupied(.password)`/`(.totp)`), by any live passkey with the same `rpID`+`credentialID` (owner included) ⇒ `.passkeyCollision`, by another account's exchange item id or origin+username overlap; owner missing ⇒ `.ownerMissing`; the owner's own id/exchange ids/origin+username never block.
    - `passkeyWithSameIdentityDifferentKeyIsAnIdentityConflict`: ⇒ `.passkeyIdentityConflict`.
    - `restoreEarlierRevisionKeepsTheChosenRevisionAndMakesCurrentANewOne` (§11.3a, password/TOTP/metadata): the chosen revision row is byte-identical afterwards, the previous current value is a new revision, nothing in Trash; a result with duplicate/invalid origins is refused with nothing written; `previewRestoreRevision` returns the resulting account.
    - `listingsPageByFifty`: 120 entries ⇒ pages of 50, 50, 20; `next` nil on the last.
    - `removedIdentifiersCarryOnlyIdsAndCoverTombstones`: after delete and purge the list holds entry and tombstone identifiers; the planted password/TOTP strings appear in no field.
  - `VaultPurgeTests`
    - `purgeNeedsAFreshAssertionFromAnEnrolledCredential`: no/unenrolled/wrong `authorization` ⇒ throws, nothing changes; a cached lease alone is insufficient.
    - `purgeReplacesEntriesWithTombstonesAndJournals`: tombstone present with no secret field; `remove`/`add` journal ops; wrappers byte-identical; `.pre-v2` and `cutover-v1*` files untouched; `emptyAll` purges every entry.
    - `purgeIsNotBlockedByLogicalCapacity`: at the live caps, with 16 vaults, with large history ⇒ succeeds.
    - `purgeOnAFullFilesystemFailsAtomicallyWithTheHonestError`: injected disk-full ⇒ `.diskFull`, logical state unchanged.
  - `VaultResidueTests` (item 17): remove a password and a TOTP from an account, edit its metadata, delete it, purge it; open the store with the held DEK, decrypt **and enumerate every reachable record** of the vault and its Trash (live rows, revisions, trash entries, tombstones, journal rows) and assert the planted secrets appear in none of the decrypted plaintexts; `Credentials.scratch` is empty.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultTrashTests VaultPurgeTests VaultResidueTests`. Expected: build failure `has no member 'undelete'`.

- [ ] **Step 3: Implement** `+History` (listings decrypt one row at a time and derive labels from snapshots; `undelete`/`restoreRevision` collision checks per spec §11.3/§11.3a, then the Task 7 MOVE engine/commit path) and `+Purge` (`authorize` first, then one transaction: delete entries and their revision rows, add tombstones, journal `remove`/`add`, never touch wrappers; best-effort `wal_checkpoint(TRUNCATE)` afterwards).

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultTrashTests VaultPurgeTests VaultResidueTests VaultMoveTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials/Store WSurfTests && git commit -m "feat(credentials): undelete, earlier versions, purge and listings"`. Review gate (§Execution).

### Task 9: Vault creation and v1 migration

**Files:**
- Create: `WSurf/Web/Credentials/Store/LegacyVaultV1.swift`, `ProfileVaultStore+Create.swift`, `ProfileVaultStore+Migrate.swift`, `ProfileVaultStore+UnlockRouting.swift`
- Test: `WSurfTests/Web/VaultStoreCreateTests.swift`, `VaultMigrationTests.swift`

**Interfaces:**
- Consumes: Task 1 (`StoreFileOps` incl. `afterMigrationStep`, `OperationLock`), Task 3, Task 4 (`StoreAnchors`), Task 6 (`ProfileVaultStore`, `unlockInitialized`, `unlockHeld`, `StoreSnapshot`), Task 7 (`commit` paths, heads); existing `CredentialVaultCrypto.decodeEnvelope/unwrap/openPayload/wrap`, `CredentialVaultEnvelope{format,profileID,vaultID,wrappers,payload}`.
- Produces:

```swift
nonisolated enum LegacyVaultV1 {                                                  // read-only v1 access, used only by migration
  static func readEnvelope(at url: URL) throws -> Data                            // the v1 file bytes (B0)
  static func open(_ bytes: Data, profileID: UUID, proof: VaultUnlockProof) throws -> (vaultID: UUID, dek: SymmetricKey, payload: CredentialVaultPayload, wrappers: [CredentialKeyWrapper]) }
enum VaultCreationAuthority: Sendable { case firstVault, unlockedVault(vaultID: UUID, access: VaultAccess), existingPasskey(vaultID: UUID, credentialID: Data, prf: SymmetricKey) }
extension ProfileVaultStore {
  func createVault(name: String, unlock proof: VaultUnlockProof, authorizedBy: VaultCreationAuthority) async throws -> UUID     // §8; existingPasskey runs §6.8 steps 1-7 only and publishes nothing
  func setDefaultVault(_ vaultID: UUID?)                                           // UserDefaults key io.wsagency.wsurf.credentialVault.defaultVault
  func defaultVaultID() -> UUID?
  func unlock(vaultID: UUID, credentialID: Data, prf: SymmetricKey, confirmMigration: Bool, access: VaultAccess,
              verifying: (@Sendable (Bool) -> Void)?) async throws    // THE public unlock (Task 10's manager calls only this); routes on openState() with no lock held:
}                                                                    // .provisional ⇒ unlockInitialized (it owns its lock); .failClosed ⇒ throw it; .firstRun ⇒ .noSuchVault;
                                                                     // .legacy/.resumeMigration ⇒ confirmMigration false ⇒ .migrationNeedsConfirmation before any lock or write; else acquire EXCLUSIVE ONCE,
                                                                     // re-read the state under it (.stateChanged ⇒ re-route once), run the migration steps, then unlockHeld(hold, mode: .exclusive, …) and release.
                                                                     // A state seen as .provisional but changed at the lock ⇒ unlockInitialized throws .stateChanged ⇒ re-route once.
```
The routed `unlock(..., confirmMigration: true)` on `.legacy` performs §10 steps 1-10 and then the normal §6.8; on `.resumeMigration` it performs step 8 first, then verifies `.migrating` and performs 9-10. Migration copies the v1 payload's `blockedPasswordOrigins` verbatim into the first active head (spec §7 clarification) and invents nothing else.

- [ ] **Step 1: Write the failing tests.**
  - `VaultStoreCreateTests`
    - `firstVaultBootstrapInterruptedAtEachStepNeverEnablesCreateOrDiscards` (parameterized over the `afterMigrationStep`-style seam for steps before the pending store is complete, before `.swap`, before the stub exists): `openState` is `failClosed(.leftoversWithoutAuthority)` listing the leftover paths, no Create path exists in `StoreOpenState`, files untouched; interrupted after the stub exists ⇒ `.resumeMigration`; a completed bootstrap unlocks.
    - `newPasskeyVaultNeedsAnUnlockedVault`: `authorizedBy: .unlockedVault` with a revoked/other-profile access ⇒ `.noAuthority`.
    - `existingPasskeyRunsStepsOneToSevenAndPublishesNothing`: the new vault unlocks with the supplied proof alone; the source vault's manager-visible grant stays absent (`snapshot(source)` throws `unauthorized`); a wrong `prf` ⇒ `.passkeyUnusable` and nothing is created (no fallback path is invoked).
    - `creatingWithAnotherVaultLockedChangesNoneOfItsBytes`: every `vault`, `head`, `record`, `journal` row of the other vault is byte-identical afterwards.
    - `ordinalNameAndCountLimits`: ordinal = max+1; 17th active vault ⇒ `.tooManyVaults`; 65-character name ⇒ `.invalidVaultName`.
    - `defaultVaultPreferenceRoundTripsAndMayNameALockedVault`.
  - `VaultUnlockRoutingTests` (in `VaultMigrationTests.swift`)
    - `routedUnlockNeverNestsTheLock`: store with `lockWait: .milliseconds(150)`; a legacy-directory unlock with confirmation completes and a provisional-store unlock completes (a nested second `flock` from the same process would time out with `.storeBusy`).
    - `routerSendsProvisionalToTheInitializedPath`: a provisional store unlocks through `unlock(confirmMigration: false)` with no migration prompt.
    - `firstRunAndFailClosedStatesAreRefusedWithoutWriting`: `.firstRun` ⇒ `.noSuchVault`; a fail-closed directory ⇒ its `failClosed`; directory byte-identical.
    - `stateChangingBetweenRouteAndLockIsReroutedOnce`: the seam swaps the directory from legacy to provisional between route and lock ⇒ unlock still succeeds; a second change ⇒ `.stateChanged`.
  - `VaultMigrationTests` (each case builds a real v1 file with `CredentialVaultCrypto` and a synthetic proof; assertions are on files and the unlock result)
    - `crashAtEachStepLeavesV1OrTheNewStoreAuthoritative` (parameterized step 1…10 by throwing from `afterMigrationStep`): afterwards `openState` is the §6.3 state the spec names for that step; a retry unlock completes; never both unrecoverable.
    - `migratedVaultKeepsEverythingAndUnlocksWithTheOriginalPasskey`: wrapper bytes identical to B0's, account ids, passkey ids/`credentialID`s, exchange ids and values unchanged, new date fields nil, `blockedPasswordOrigins` identical (including a 4,096-entry set), unlock with the original proof succeeds.
    - `preMigrationBackupIsReusedOnlyIfByteIdentical`: identical leftover `.pre-v2` reused untouched; a different pre-existing `.pre-v2` ⇒ `.migrationAborted(path:)`, nothing changed.
    - `pendingStoreIsRemovedOnlyAfterV1AndBackupAreVerified`: a corrupt v1 with a leftover `.migrating` ⇒ `.migrating` still present.
    - `oldBuildWriteBeforeTheSwapIsPreservedAsCutoverV1`: the seam rewrites the v1 file before step 7 ⇒ step 8 renames the displaced newer file to `Credentials.vault.cutover-v1`, `unlock` throws `failClosed(.cutoverV1Present)` with paths, stub and pending store kept, nothing merged or rolled back, no grant.
    - `oldBuildWriteAfterTheSwapYieldsRowOneOrThree`: a v1 file written after step 8 ⇒ `openState` is `legacy` before the store rename and `failClosed(.v1AfterMigration)` after; both files kept.
    - `renameSwapUnsupportedAbortsUnchanged`: `fileOps.renameSwap` throwing `.unsupported` ⇒ `.renameSwapUnsupported`, v1 byte-identical, no stub.
    - `noSQLiteSidecarsOrOpenHandlesAtRename`: the injected `renameExclusive`/`renameSwap`/`renameExclusive` closures assert `-wal`/`-shm` are absent and that `lsof`-free proof: opening the pending file with `SQLITE_OPEN_EXCLUSIVE`-style probe via a second GRDB connection succeeds with no WAL side file.
    - `resumeAtUnlockPerformsStepEightFirstAndFailsClosedOnABadPendingStore`.
    - `migrationNeedsConfirmationAndExclusiveLock`: `confirmMigration: false` ⇒ `.migrationNeedsConfirmation`, nothing written; a held lock ⇒ `.storeBusy`, nothing written.
    - `oldReaderFence`: the stub through `CredentialVaultCrypto.decodeEnvelope` ⇒ `corruptVault` (reused from Task 4, run against a real migration output).

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultStoreCreateTests VaultMigrationTests`. Expected: build failure `cannot find 'LegacyVaultV1' in scope`.

- [ ] **Step 3: Implement** `LegacyVaultV1` over the existing crypto, the creation paths of spec §8 and migration steps 1-10 of spec §10 under the EXCLUSIVE lock (`afterMigrationStep` invoked after each step), using only `StoreFileOps` for renames and fsyncs (`renameExclusive` for the stub, `renameSwap` at the commit point; no non-atomic fallback). The router lives in `+UnlockRouting` and calls Task 6's functions unchanged.

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultStoreCreateTests VaultMigrationTests VaultStoreUnlockTests VaultStoreStateTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials/Store WSurfTests && git commit -m "feat(credentials): vault creation and one-way v1 migration"`. Review gate (§Execution).

### Task 10: Manager, routing and consumer cutover

**Files:**
- Create: `WSurf/Web/Credentials/CredentialRouting.swift`, `VaultChoicePrompt.swift`; `WSurfTests/Helpers/VaultManagerFixture.swift`
- Modify: `WSurf/Web/Credentials/CredentialManager.swift`; `CredentialSettingsModel.swift:289,404,519` (minimal real edits: operate on the selected vault via `forVault`/`createVault`; the Settings UI is Task 14); `WSurf/Web/Autofill/AutofillSuggestions.swift:184,196`; `AutofillSaveCoordinator.swift:161,172`; `WSurf/Web/Credentials/WebAuthnAdapter.swift:400`; `WSurf/App/AppCoordinator+Profiles.swift:27,68`; `WSurf/App/BrowserApplication.swift:295`; `WSurf/Profiles/Profile.swift:107`; existing tests constructing `CredentialManager(profile:directory:now:)` (`WebsiteAuthenticatorCeremonyTests.swift:137,498`, `CredentialExchangeCoordinatorTests.swift:42`, `CredentialAccountSelectionTests.swift:254`, `CredentialSettingsTests.swift:585`, `CredentialLifecycleTests.swift:30,314,343,389,568`) → `VaultManagerFixture`
- Delete: `WSurf/Web/Credentials/CredentialVault.swift`, `WSurfTests/Web/CredentialVaultTests.swift`, and the `VaultSnapshot` struct in `CredentialVaultCrypto.swift:77-81` (no alias, no typealias, no shim)
- Cut over `VaultSnapshot` → `StoreSnapshot` (every constructor passes `vaultID`, `stamps` and all other members explicitly): `Autofill/CredentialAutofill.swift:157`, `CredentialSettingsModel.swift:240,246,677`, `WebsiteAuthenticatorCeremony.swift:418`, `CredentialExchangeCodec.swift:25,169`, `CredentialExchangeCodecExport.swift:9`, and tests `CredentialExchangeTests.swift:70-71`, `CredentialExchangeCoordinatorTests.swift:65,162`, `CredentialAccountSelectionTests.swift:366,379,388`, `CredentialSettingsTests.swift:55` (its wrapper-compat assertions live in Task 1 and Tasks 6/9)
- Test: `WSurfTests/Web/VaultRoutingTests.swift`, `VaultManagerTests.swift`

**Interfaces:**
- Consumes: Tasks 6-9 (`ProfileVaultStore` and every method above), existing `PasskeyVaultUnlocker`.
- Produces — `CredentialManager` **keeps its existing `@MainActor @Observable final class` isolation** (`CredentialManager.swift:31-33`); no blanket `nonisolated`. Members kept verbatim from source: `isUnlocked`, `authorizationEpoch`, `stableGeneration`, `unlockCredentials`, `unconfirmedPasskeys`, `noteUnconfirmedPasskey(rpID:userName:revision:)`, `dismissUnconfirmedPasskeys()`, `profileID`, `beginAccess() -> VaultAccess`, `completeUnlock(credentialID: Data, prf: SymmetricKey, access: VaultAccess) async throws`, `unlock(in anchor: ASPresentationAnchor) async throws`, `addUnlock(in anchor: ASPresentationAnchor) async throws -> VaultCommitReceipt`, `preflightAddingUnlock(using access: VaultAccess) async throws -> VaultDiscovery`, `completeAddUnlock(_ proof: VaultUnlockProof, using access: VaultAccess) async throws -> VaultCommitReceipt`, `completeRemoveUnlock(credentialID:verifiedRemaining:using:) async throws -> VaultCommitReceipt`, `removeUnlock(credentialID: Data, in anchor: ASPresentationAnchor) async throws -> VaultCommitReceipt`, `snapshot() async throws -> StoreSnapshot`, `updatePasswordSavePolicy(_ blockedOrigins: Set<String>, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt`, `lock(reason: CredentialLockReason)`, statics `lockAll(reason:)`, `lock(profileID:reason:)`, `retire(profileID:) async`. **Changed:**

```swift
let vaultID: UUID
init(profile: Profile, vaultID: UUID, store: ProfileVaultStore, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now })    // replaces init(profile:directory:now:) throws
func commit(_ accounts: [CredentialAccount], expectedRevision: UInt64, authorizedEpoch: UInt64, cause: String? = nil) async throws -> VaultCommitReceipt
func delete(_ scope: RemovalScope, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt
func trashPage(after: Int?) async throws -> TrashPage
func revisionPage(accountID: UUID, after: Int?) async throws -> RevisionPage
func previewUndelete(entryID: UUID) async throws -> UndeletePreview
func undelete(entryID: UUID, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt
func previewRestoreRevision(revisionID: UUID) async throws -> CredentialAccount
func restoreRevision(revisionID: UUID, expectedRevision: UInt64, authorizedEpoch: UInt64) async throws -> VaultCommitReceipt
func purge(entryIDs: [UUID], emptyAll: Bool, in anchor: ASPresentationAnchor) async throws -> PurgeReceipt              // fresh assertion via PasskeyVaultUnlocker, then store.purge
func removedIdentifiers() async throws -> RemovedIdentifiers
static func store(for profile: Profile) throws -> ProfileVaultStore                                                       // one per profile
static func forVault(_ profile: Profile, vaultID: UUID) throws -> CredentialManager
static func unlockedManagers(for profile: Profile) -> [CredentialManager]                                                 // live lease only
static func createVault(profile: Profile, name: String, choice: NewVaultChoice, in anchor: ASPresentationAnchor) async throws -> UUID
// removed: forProfile(_:), vaultExists(), create(in:), completeCreate(_:access:)
enum NewVaultChoice: Sendable { case newPasskey(authorizedBy: CredentialManager?), existing(sourceVaultID: UUID, credentialID: Data, prfInput: Data) }
enum VaultChoiceReason: Sendable { case matchInSeveral, noneMatchedLockedExists, defaultLocked }
enum VaultRoute: Sendable { case manager(CredentialManager), needsChoice([VaultListing], reason: VaultChoiceReason), needsUnlock(VaultListing) }
@MainActor enum CredentialRouting { static func route(profile: Profile, origin: String, username: String?) async -> VaultRoute }
@MainActor enum VaultChoicePrompt { static func present(_ candidates: [VaultListing], reason: VaultChoiceReason, in anchor: ASPresentationAnchor) async -> UUID? }
```
`retire(profileID:)` drains every vault manager, then `store.close()`, before the directory removal runs. `lockAll` and the profile-switch/sleep/screen-lock/termination observers lock every vault manager.

- [ ] **Step 1: Inventory.** Run `grep -rn "forProfile\|CredentialVault(\|vaultExists()\|completeCreate\|\.create(in\|VaultSnapshot" WSurf WSurfTests` and record every hit in the ledger; every hit not in the Files list above is added to this task before editing.

- [ ] **Step 2: Write the failing tests** (`VaultManagerFixture.make(vaults:)` builds a real store with N unlocked/locked vaults and returns managers):
  - `VaultRoutingTests`: `importOrAutosaveToAnUnlockedVaultNeverTouchesAnother` (B's rows byte-identical); `lockedVaultsAreNeverRead` (a locked vault's `snapshot` is never reachable: its manager has no lease and the route result never includes its accounts); `autosaveGoesToTheVaultHoldingTheMatch`; `matchInSeveralUnlockedVaultsNeedsChoice`; `noMatchWhileAnotherVaultIsLockedNeedsChoice`; `newLoginGoesToTheDefaultVault`; `defaultLockedNeedsChoiceOrUnlockNeverSilentFallback`; `suggestionsUnionAcrossUnlockedVaultsAndFillOnlyFromTheOwningVaultUnderItsEpoch`; `webAuthnRegistrationRoutesLikeAutosaveAndKeepsThePostPromptRecheck` (the selected account changing during a stubbed prompt refuses the write); `staleEpochAfterLockIsRefused`.
  - `VaultManagerTests`: `commitRequiresTheAuthorizedEpoch`; `lockAllProfileSwitchSleepScreenLockAndTerminationLockEveryVaultManager`; `retireDrainsEveryManagerThenClosesTheStoreBeforeDirectoryRemoval` (a write in flight completes or is refused; afterwards the store refuses use and the directory can be removed); `privateProfileHasNoVault` (`store(for:)` throws `CredentialVaultError.privateBrowsing`); `trashAndVersionOperationsUseTheSourceManagersLease` (locked source ⇒ `trashPage` throws `unauthorized`); `purgeRequiresAFreshAssertion` (stubbed `PasskeyVaultUnlocker` records one assert; none ⇒ refused).

- [ ] **Step 3: Run the tests to verify they fail.** Run: `PRO_TEST VaultRoutingTests VaultManagerTests`. Expected: build failure `extra argument 'vaultID' in call` / `cannot find 'CredentialRouting'`.

- [ ] **Step 4: Implement** the manager over `ProfileVaultStore` (the `vault` property becomes `store` + `vaultID`; existing lease/epoch/`writing`/`guarded` logic unchanged), `CredentialRouting`/`VaultChoicePrompt`, cut over the listed sites one by one, delete `CredentialVault.swift`/`CredentialVaultTests.swift`, convert the listed test setups to `VaultManagerFixture`.

- [ ] **Step 5: Run the tests to verify they pass.** Run: `PRO_TEST VaultRoutingTests VaultManagerTests CredentialLifecycleTests CredentialAccountSelectionTests CredentialSettingsTests CredentialExchangeCoordinatorTests WebsiteAuthenticatorCeremonyTests WebAuthnAdapterTests`. Then Air: `grep -rn "forProfile\|CredentialVault(\|VaultSnapshot" WSurf WSurfTests` returns nothing (the old actor, the old snapshot type and every constructor of it are gone; no alias). Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit** — `git add -A WSurf WSurfTests && git commit -m "feat(credentials): per-vault managers, routing and consumer cutover"`. Review gate (§Execution).

### Task 11: Exchange codec and classification

**Files:**
- Modify: `WSurf/Web/Credentials/CredentialExchangeCodec.swift`, `CredentialExchangeCodecApply.swift` (delete the `(.passkey,.passkey)` replace branch at `:317-324` and the passkey replace validation in `validatedDecisions`), `CredentialExchangeCodecExport.swift`
- Test: `WSurfTests/Web/VaultExchangeClassificationTests.swift`; extend `CredentialExchangeTests.swift`

**Interfaces:**
- Consumes: Task 2 (`CredentialContent.hash`, `ExchangeBase`, account dates), Task 8 (`RemovedIdentifiers`, `RemovedIdentifier`), existing `CredentialImportPreview`, `CredentialImportConflict`, `CredentialImportDecision` (`.keep/.add(_:targetAccountID)/.replace(_:target)`), `CredentialIdentity`, `CredentialVaultError.invalidData`.
- Produces (`nonisolated Sendable`):

```swift
enum CredentialImportClass: Equatable, Sendable { case new, unchanged, remoteChanged, localChanged, bothChanged, noCommonBase, previouslyRemoved(entryID: UUID, isTombstone: Bool), ambiguous, passkeyHardConflict }
struct ImportDestinationView: Sendable { let accounts: [CredentialAccount]; let removed: RemovedIdentifiers }
static func classify(_ incoming: CredentialIdentity, in preview: CredentialImportPreview, destination: ImportDestinationView) -> CredentialImportClass   // on CredentialExchangeCodec
```
`CredentialExchangeCodec.apply` throws `CredentialVaultError.invalidData` for any `.replace` of a passkey and for any decision other than `.keep` on a `passkeyHardConflict`. `removesStoredPasswordOnReplace` is generalized in Task 12's review model to TOTP.

- [ ] **Step 1: Write the failing tests** (through `preview`/`classify`/`apply`/export, never by reading source):
  - `samePasskeyIdentityDifferentKeyOrHandleIsAHardConflict`: same `rpID` (case-folded) + `credentialID` with a different public key ⇒ `.passkeyHardConflict`; with a different `userHandle` ⇒ same; `apply` with `.replace`, `.add` or `.merge` for it throws `invalidData`, `.keep` leaves the local passkey byte-identical.
  - `equivalentKeyWithDifferentDERIsUnchanged`: PKCS#8 re-encoded variant of the same key ⇒ `.unchanged`; differing `userName`/`userDisplayName`/FIDO2 metadata/dates ignored; nothing written.
  - `differentCredentialIDAppends`.
  - `passkeyReplaceDecisionIsRejectedByApply`: `.replace` between two passkeys throws `invalidData` and `apply` leaves the base unchanged.
  - `idMatchWithoutBoundPairingIsAmbiguous`; `idMatchSeveralLocalIsAmbiguous`; `neverMatchesBySiteAndUsername`.
  - `boundPairingClassifiesByContentHash`: with `passwordBase` ⇒ remote-only change `.remoteChanged`, local-only `.localChanged`, both `.bothChanged`, equal `.unchanged`; no base ⇒ `.noCommonBase`; a bound pairing with changed content is never `.ambiguous`.
  - `previouslyRemovedMatchesIdentifiersNotSecrets`: matches `exchangeItemID`/passkey `credentialID` of a Trash entry or tombstone; a purged item matches by identifiers; content similarity alone does not.
  - `totpClassification`: identical ⇒ `.unchanged`; different seed or same seed with different digits/period/algorithm/issuer ⇒ conflict whose review values never contain the secret.
  - `usernameOnlyIncomingNeverRemovesAStoredPassword`; `defaultMergeThatWouldThrowInvalidDataBecomesAConflict`.
  - `malformedPayloadStillFailsClosedWholeWithPositionOnly`.
  - `replaceSupersedesPasswordAndTotpIntoARevisionPlan`: `apply` output plus `CredentialDiff.plan` shows revisions for the superseded password/TOTP.
  - Export: `exportLastModifiedIsModifiedAtWhenWSurfChanged`, `inheritedDatesOnlyWhileContentHashEqualsBase`, `otherwiseNilNeverNow` (a fixed clock far from the dates), `exportFormatIsV1Only`, `fido2MetadataOnOlderOSFailsWithAStatedError`.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultExchangeClassificationTests CredentialExchangeTests`. Expected: build failure `cannot find 'CredentialImportClass' in scope`.

- [ ] **Step 3: Implement** classification and the codec edits above; classification is evaluated against the destination view only.

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultExchangeClassificationTests CredentialExchangeTests CredentialExchangeCoordinatorTests`. Expected: `** TEST SUCCEEDED **` (the coordinator suite compiles unchanged because Task 12 owns its edits).

- [ ] **Step 5: Commit** — `git add WSurf/Web/Credentials WSurfTests && git commit -m "feat(credentials): exchange identity, classification and truthful export dates"`. Review gate (§Execution).

### Task 12: Exchange coordinator, per-account writes and messages

**Files:**
- Create: `WSurf/Web/Credentials/Store/ProfileVaultStore+AccountWrites.swift`, `WSurf/Web/Credentials/CredentialTransferMessage.swift`
- Modify: `WSurf/Web/Credentials/CredentialManager.swift` (adds `commitAccounts`, same epoch guard as `commit`), `Store/ProfileVaultStore+Commit.swift` (only to expose Task 7's internal plan writer to the new file), `WSurf/Web/Credentials/CredentialExchangeCoordinator.swift` (`CredentialImportChoice` loses passkey replace; review model and binding; `commitImport` and the export handoff write call `commitAccounts`, never `commit(_:expectedRevision:…)`), `WSurf/App/BrowserApplication.swift:188-205`
- Test: `WSurfTests/Web/VaultAccountWriteTests.swift`, `VaultTransferLifecycleTests.swift`; extend `CredentialExchangeCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 7 (internal plan writer, `CredentialDiff.plan`), Task 10 (`CredentialManager`, `commit`, `snapshot`, `StoreSnapshot.stamps`), Task 11 (`CredentialImportClass`, `classify`, `ImportDestinationView`), existing coordinator methods (`receive(_:) -> Bool`, `discardPendingImport(token:)`, `claimImport(token:for:owner:)`, `hasStagedImport(for:owner:)`, `importReview(for:owner:)`, `beginImport(token:into:owner:)`, `stage(_:into:owner:)`, `choose(_:for:owner:)`, `mergeTargets(for:owner:)`, `commitImport(into:owner:) -> VaultCommitReceipt`, `cancelImport(for:owner:) -> CredentialImportCancellation`, `exportCredentials(…)`, `prepareExport(…)`; signatures preserved except as listed).
- Produces:

```swift
nonisolated struct CredentialTransferMessage: Equatable, Sendable {
  enum Kind: Equatable, Sendable { case alreadyInProgress, discarded, applyFailed(operation: String), succeeded, mayHaveLanded, nothingImported, malformed(position: Int?), handedToSystem }
  enum Action: Equatable, Sendable { case none, exportAgain, checkSavedCredentials }    // the next step the consumer offers; terminal-state policy lives here, not in prose
  let kind: Kind; let action: Action; let receipt: VaultCommitReceipt?                    // receipt non-nil ONLY for .succeeded; nil for every other kind (no claim that anything landed)
  let text: String }                                                                       // wording per spec §13.5, owned by production code; tests never assert on it (Gate B operator reads it)
// CredentialImportReview += let profileName: String; let vaultName: String?; each Record += let classification: CredentialImportClass
// CredentialExchangeCoordinator.receive(_:) -> Bool is unchanged; the second-token message is delivered through
var onMessage: (@MainActor (CredentialTransferMessage) -> Void)?

// Per-account transactional write (ProfileVaultStore+AccountWrites.swift), the ONLY write path for import apply and the export handoff stamp
enum AccountExpectation: Equatable, Sendable { case stamp(AccountStamp), absent }       // the account's stamp the review/selection was bound to, or "this id must not exist live"
struct AccountWrite: Sendable { let accountID: UUID; let expected: AccountExpectation; let replacement: CredentialAccount }   // replacement.id == accountID
extension ProfileVaultStore {
  func commitAccounts(vaultID: UUID, _ writes: [AccountWrite], cause: String?, using access: VaultAccess) async throws -> VaultCommitReceipt }
// CredentialManager (@MainActor): same lease/epoch/writing guard as commit(_:expectedRevision:authorizedEpoch:cause:)
func commitAccounts(_ writes: [AccountWrite], authorizedEpoch: UInt64, cause: String? = nil) async throws -> VaultCommitReceipt
```
`commitAccounts` runs ONE `BEGIN IMMEDIATE` transaction that: re-verifies the registry with RK; reads the vault's **current** verified head and live catalog (no caller-supplied revision; the whole-head revision is not compared); requires `writes` non-empty with distinct `accountID`s (else `CredentialStoreError.malformed`); for each write requires `.stamp(x)` == the current stamp of that live id and `.absent` ⇒ the id is not live, else throws `CredentialVaultError.staleRevision` with nothing written; builds `CredentialVaultPayload(revision: currentHead.revision, accounts: candidateAccounts, blockedPasswordOrigins: Set(currentHead.blockedOrigins))` where `currentHead` is the **current verified** `VaultHead` (its sealed field is `blockedOrigins`; the payload label is `blockedPasswordOrigins`; never an empty or default policy) and `candidateAccounts` are the current live accounts with the touched ids replaced/added, and runs `CredentialVaultCrypto.validate` on that payload **before any write**, so the complete combined `CredentialVaultLimits.payloadBytes` (4,000,000) budget of accounts plus policy is enforced (limits, duplicate ids / exchange ids / origin+username introduced by a concurrently added account ⇒ `CredentialVaultError.duplicateIdentifier` or `.limit`, nothing written); plans only the touched ids against their current rows with `CredentialDiff.plan` and writes through Task 7's plan writer. Untouched account rows are never read for rewrite or modified; the head's `blockedPasswordOrigins` is copied unchanged; head revision +1 and registry updated only when the plan is non-empty (an all-unchanged write is a true no-op). One attempt only: no retry, no queue; the caller reports the failure.
The review binds `(recordID, version, digest)` of every account the plan touches (from `StoreSnapshot.stamps`), not the whole head revision. `commitImport` builds one `AccountWrite` per touched account (`.stamp(bound)` for replace/merge targets, `.absent` for new ids) and calls `commitAccounts`; the coordinator's own pre-commit re-check against a fresh snapshot is only an early discard, the authoritative check is inside the transaction.

- [ ] **Step 1: Write the failing tests:**
  - `VaultAccountWriteTests` (store and manager boundary, real fixture):
    - `unrelatedConcurrentWriteSurvivesAnAccountWrite`: commit unrelated account X, then `commitAccounts` for a different touched account with its earlier stamp ⇒ succeeds; X unchanged; head revision +1 of the post-X value.
    - `touchedStampMismatchFailsWithNoWrites`; `absentExpectationOnAnExistingIdFailsWithNoWrites`; `stampExpectationOnAMissingIdFailsWithNoWrites` (each `CredentialVaultError.staleRevision`, every row/head/registry byte identical).
    - `concurrentlyAddedIdentifierCollisionFailsWithNoWrites` (id, exchange ids, origin+username).
    - `untouchedRowsAndPolicyAreByteIdentical`: all rows of untouched accounts and the head's `blockedPasswordOrigins` unchanged (the head's policy set mirrors exactly through the write).
    - `combinedAccountsAndPolicyBudgetIsEnforced`: fixture head holds a large policy set (4,096 maximum-length canonical origins) and an account near the cap. (a) An edit whose accounts-only payload fits within 4,000,000 B but whose payload **with the existing policy** exceeds it ⇒ `.limit(.payloadBytes)`, and every row, head and registry byte is identical afterwards. (b) An edit that stays within the combined budget is accepted, and the head's `blockedPasswordOrigins` after the write equals the set before it.
    - `emptyDistinctnessAndNoOpRules`: empty list or duplicate `accountID` ⇒ `.malformed`; an all-unchanged write changes nothing (revision, registry bytes).
    - `revisionsFollowTheSameRulesAsCommit`: replacing a password creates one revision, a persist-only change none.
    - `managerRefusesAStaleEpoch`: wrong `authorizedEpoch` or locked ⇒ `.unauthorized`/`.expired`, nothing written.
  - `previewHeaderNamesProfileAndDestinationVault`.
  - `unrelatedWriteBetweenPreviewAndApplyDoesNotDiscard` and `touchedAccountWriteDiscardsWithTheDiscardedMessageAndWritesNothing`: a commit of another account, then one of a touched account, between preview and `commitImport`.
  - Seam for the next three tests: `var afterLastCheck: (@MainActor () async -> Void)?` on the coordinator, invoked after its pre-commit re-check and before `commitAccounts`.
  - `unrelatedWriteAfterTheLastCheckIsPreservedAndTheImportSucceeds`: `afterLastCheck` commits a change to an **unrelated** account through the real manager ⇒ `commitImport` returns a receipt; the final snapshot contains that unrelated change **and** every import result; the unrelated row and the policy set are byte-identical to their post-seam state; no retry happened (`commitAccounts` call count 1).
  - `touchedAccountChangedAfterTheLastCheckWritesNothing`: `afterLastCheck` changes a touched account ⇒ `.discarded`, `receipt == nil`, store rows/heads/registry equal the post-seam bytes (no import row), staged import cleared, token not reusable.
  - `newIDCollisionAfterTheLastCheckWritesNothing` (parameterized: same account id, same `exchangeAccountID`/`exchangeItemID`, same origin+username, added concurrently by the seam): `.discarded`/`.applyFailed`, `receipt == nil`, nothing of the import landed, post-seam bytes unchanged.
  - `secondTokenWhilePendingClaimedOrStagedIsNotSilentlyDropped`: `receive` returns false **and** `onMessage` gets exactly one message with `kind == .alreadyInProgress`, `action == .none`, `receipt == nil`; the pending/staged import is unchanged.
  - `twoWindowsOnlyTheFirstClaimerProceeds`: two managers for different profiles; the second `claimImport` fails visibly.
  - `everyFailedCancelledOrStaleStateSaysDiscardedAndNeverErased`: lock, epoch change, lease expiry, cancel, stale preview, apply failure (capacity/collision/write error) each emit exactly one message with `kind` `.discarded` or `.applyFailed(operation:)`, `action == .exportAgain`, `receipt == nil`; consumer state afterwards: `hasStagedImport` false, the token refused, store bytes unchanged. (No assertion on message text.)
  - `successCarriesTheReceiptAndTheResultList`: `kind == .succeeded`, `action == .none`, `receipt?.revision` equals the store's head revision, the result list equals the applied records; `allSkippedIsNothingImportedNotSuccess`: `kind == .nothingImported`, `receipt == nil`, store unchanged.
  - `lockDuringCommitReportsMayHaveLanded`: lock injected mid-commit ⇒ `kind == .mayHaveLanded`, `action == .checkSavedCredentials`, `receipt == nil` (never `.discarded`, never `.succeeded`).
  - `tokenReuseIsRefused`; `lateCompletionOfACancelledImportCannotConsumeASuccessor`.
  - `passkeyReplaceChoiceIsRejectedAtReview`: `choose(.replace, for: <passkey identity>, owner:)` throws `CredentialExchangeCoordinatorError.invalidChoice`; a hard-conflict record accepts only `.skip`.
  - Export: `exportNamesSourceProfileAndVault`; `exportSelectionBoundToAccountStamps` (an unrelated write does not invalidate, a changed selected account or lock reopens the sheet with the selection preserved and sends nothing); `uncertainExportWritesNoSnapshot`; `transferredRecordsHandoffStampAndHashOnlyAndNeverAdvancesTheBase` (the handoff stamp is written with `commitAccounts`: an unrelated write between the selection check and the stamp does not fail it; a changed selected account writes nothing); `exportEndsInHandedToSystemNotSucceeded`: the terminal message is `kind == .handedToSystem` and never `.succeeded`, no receipt.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultAccountWriteTests VaultTransferLifecycleTests`. Expected: build failure `value of type 'ProfileVaultStore' has no member 'commitAccounts'`.

- [ ] **Step 3: Implement** `commitAccounts` (store, over Task 7's plan writer) and its manager forwarder, the coordinator/intake edits (`BrowserApplication.swift:188-205` routes `receive`'s refusal to `onMessage`), the stamp binding via `AccountWrite`, the message type with the §13.5 wording as production strings, and the review additions.

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultAccountWriteTests VaultTransferLifecycleTests CredentialExchangeCoordinatorTests VaultExchangeClassificationTests VaultCommitTests VaultMoveTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git add WSurf WSurfTests && git commit -m "feat(credentials): bound import preview and truthful transfer messages"`. Review gate (§Execution).

### Task 13: Editor contract

**Files:**
- Create: `WSurf/Settings/Pages/WebsiteListField.swift`, `WebsiteFieldEditing.swift`
- Test: `WSurfTests/Settings/WebsiteFieldEditingTests.swift`

**Interfaces:**
- Consumes: existing `CredentialAccount.parseSites`/`validate`, `CredentialSettings.swift:507-510` website fields.
- Produces: `nonisolated enum WebsiteFieldEditing { struct State: Equatable { var text: String; var caret: Int; var selectionLength: Int; var hasMarkedText: Bool }; enum Input: Equatable { case typed(String, modified: Bool), returnKey(modifiers: Set<Modifier>), keypadEnter, paste(String), drop(String), dictation(String), replacement(String), imeCommit(String) }; enum Modifier { case shift, option }; static func apply(_ input: Input, to state: State, kind: Kind) -> State }` with `enum Kind { case websites, extraOrigins }`; `struct WebsiteListField: NSViewRepresentable` over `WebsiteTextView: NSTextView` (Tab/Shift-Tab move focus, Esc not intercepted) with a `URLOpening` seam `protocol URLOpening { func open(_ url: URL) }` defaulting to `NSWorkspace`.

- [ ] **Step 1: Write the failing tests** (`WebsiteFieldEditingTests`):
  - `typedCommaOrSpaceAtLineEndAfterAValidAddressBecomesANewline` (both `.websites` and `.extraOrigins`): `"https://a.example"` + `","` ⇒ text `"https://a.example\n"`, caret at end.
  - `delimiterIsLiteralWhenInvalidSelectedMarkedModifiedOrNotAtLineEnd`: invalid line, non-empty selection, `hasMarkedText`, `modified: true`, caret mid-line ⇒ the character is inserted; a second delimiter on the new empty line stays literal.
  - `returnVariantsInsertPlainNewlineAndNeverSave`: Return, Shift-Return, Option-Return, keypad Enter ⇒ `"\n"` (assert `!text.contains("\u{2028}")`).
  - `pasteDropDictationReplacementAndIMECommitInsertVerbatim`: `"a, b c"` unchanged, no splitting or normalization.
  - `markedTextGoesToTheIMEUntouched`.
  - `linkClickPlacesCaretAndOpensNothing`: a synthetic `NSEvent.mouseEvent` click on a link range in `WebsiteTextView` ⇒ caret moved to the click point and the recording `URLOpening` saw zero calls (item 20).
  - `saveTimeSanitizationIsUnchanged`: `parseSites` of the edited text equals today's result for the same text.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST WebsiteFieldEditingTests`. Expected: build failure `cannot find 'WebsiteFieldEditing' in scope`.

- [ ] **Step 3: Implement** the reducer and the `NSTextView` bridge; the bridge's `textView(_:clickedOnLink:at:)` returns handled and never calls `URLOpening`. VoiceOver, real `keyDown`, IME, dictation and undo stay Gate B G5 (native, UNVERIFIED).

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST WebsiteFieldEditingTests CredentialSettingsTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git add WSurf/Settings WSurfTests && git commit -m "feat(credentials): website field editing contract"`. Review gate (§Execution).

### Task 14: Settings model and Saved Credentials UI

**Files:**
- Modify: `WSurf/Web/Credentials/CredentialSettingsModel.swift`, `WSurf/Settings/Pages/CredentialSettings.swift`
- Create: `WSurf/Settings/Pages/CredentialSettings+Vaults.swift`, `CredentialSettings+Trash.swift`, `CredentialSettings+Versions.swift`, `CredentialSettings+FailClosed.swift`
- Test: extend `WSurfTests/Web/CredentialSettingsTests.swift`; create `WSurfTests/Settings/VaultSettingsPresentationTests.swift`

**Interfaces:**
- Consumes: Tasks 6-13 (`listing`, `createVault`, `NewVaultChoice`, trash/versions/purge methods, `CredentialTransferMessage`, `WebsiteListField`, `StoreFailClosed`, `UndeleteBlock`).
- Produces (`@MainActor`, on the existing model's isolation): `CredentialSettingsModel` gains `var vaults: [VaultListing]`, `var selectedVaultID: UUID?`, `var defaultVaultID: UUID?`, `var isVerifying: Bool`, `var failClosed: StoreFailClosed?`, `var pendingUnlockRemoval: PendingUnlockRemoval?`, `var pendingPurge: PendingPurge?`, `var restoreBlocked: RestoreBlocked?`, `func dismissRestoreBlock()`, `func selectVault(_:)`, `func setDefaultVault(_:)`, `func createVault(name: String, choice: NewVaultChoice) async`, `func requestRemoveUnlock(credentialID: Data)`, `func confirmRemoveUnlock() async`, `func cancelRemoveUnlock()`, `func restore(entryID: UUID) async`, `func requestPurge(entryIDs: [UUID], emptyAll: Bool)`, `func cancelPurge()`, `func confirmPurge(in anchor: ASPresentationAnchor) async`, `func restoreVersion(revisionID: UUID) async`, with `struct PendingUnlockRemoval { let credentialID: Data; let text: String }` `struct PendingPurge: Equatable { let entryIDs: [UUID]; let emptyAll: Bool; let count: Int; let warning: PurgeWarning }`, `struct PurgeWarning: Equatable { let logicalOnly: Bool; let preMigrationBackup: URL? }` (logicalOnly is true when the purge removes only the store's logical entries and cannot reach older copies; the path is the `.pre-v2` file when it exists, else nil), `enum RestoreAction: Equatable { case dismiss, retrySameCopy }` and `struct RestoreBlocked: Equatable { let entryID: UUID; let block: UndeleteBlock; let actions: [RestoreAction] }` (`actions` is what the UI renders for a blocked restore and is the only source of its buttons: `.dismiss` calls `dismissRestoreBlock()`, `.retrySameCopy` calls `restore(entryID:)` for the same entry; the model has no operation that restores under another id, replaces, or targets another vault). `confirmPurge(in:)` obtains a fresh native assertion (the manager's `purge` via `PasskeyVaultUnlocker`) before the store purge; `cancelPurge()` clears `pendingPurge` and touches nothing; `CredentialDraft.account() -> CredentialAccount` returns the base **unchanged** when no exposed field changed.

- [ ] **Step 1: Write the failing tests:**
  - `VaultSettingsPresentationTests`
    - `vaultPickerListsLockedVaultsByOrdinalAndShowsNoContent`.
    - `newVaultOffersExactlyTwoChoicesAndExistingOnlyForEnrolledPasskeys`; `unsupportedExistingPasskeyShowsTheDistinctMessageWithoutFallback` (store throws `.passkeyUnusable` ⇒ message set, no vault created, `NewVaultChoice.newPasskey` is not attempted).
    - `verifyingStateAppearsPastTheThreshold` (via the store's `verifying` callback).
    - `legacyUnlockRequiresTheMigrationConfirmationFirst`: the model asks for confirmation text mentioning every other WSurf build; the store is not called until confirmed.
    - `failClosedScreenListsAbsolutePathsAndOffersRetryOnly`: `.pre-v2` described as a copy from before migration that lacks later changes, `.swap` and `cutover-v1*` described as in §6.4; the model exposes no create/reset/acknowledge operation (`retry()` re-evaluates; calling it on an unchanged directory changes no file).
    - `removeUnlockDoesNothingUntilConfirmed`: `requestRemoveUnlock` sets `pendingUnlockRemoval` for that `credentialID`; the store's wrappers are byte-identical; `cancelRemoveUnlock` clears it and leaves them identical with zero assertions requested; `confirmRemoveUnlock` requests the native assertion of a remaining credential (stubbed `PasskeyVaultUnlocker`; declined or failing ⇒ nothing removed, `pendingUnlockRemoval` kept), then removes the unlock, and the removed credential can no longer unlock. The visible warning wording is read by the operator at Gate B; no unit test pins it.
    - `blockedRestoreOffersOnlyDismissOrSameRestoreAndChangesNothing`: before the collision `restoreBlocked == nil` and the entry's restore is offered; `restore(entryID:)` on a colliding entry transitions to `restoreBlocked == RestoreBlocked(entryID:, block: <the collision>, actions: [.dismiss, .retrySameCopy])` (the rendered action list is exactly these two). Running each offered action: `.dismiss` clears `restoreBlocked` and changes nothing else; `.retrySameCopy` (three times) calls the same `restore(entryID:)`, writes nothing each time (store bytes and revision identical) and leaves `restoreBlocked` equal; none of them creates another id, replaces a live item, or touches another vault (the other vault's bytes identical). After the test deletes the conflicting live item the same `.retrySameCopy` succeeds: the account is live again, `restoreBlocked == nil` and the normal restore action is offered again.
    - `emptyTrashRequiresAStructuredConfirmationThenFreshAuthorization`: `requestPurge(entryIDs:emptyAll:)` sets `pendingPurge == PendingPurge(entryIDs:, emptyAll:, count:, warning: PurgeWarning(logicalOnly: true, preMigrationBackup: <the fixture's `.pre-v2` URL, or nil when none exists>))` and writes nothing. `cancelPurge()` ⇒ `pendingPurge == nil`, store bytes identical, zero assertions requested. `confirmPurge(in:)` with the stubbed `PasskeyVaultUnlocker` declining or failing ⇒ nothing purged (store bytes identical), `pendingPurge` kept; with a successful assertion ⇒ exactly one assertion is requested **before** exactly one `purge`, entries are replaced by tombstones, `pendingPurge == nil`. The visible wording is read by the operator at Gate B G5; no unit test pins sentence text.
    - `earlierVersionsRestorePasswordTotpMetadataAndNeverPasskeys`.
    - `eraseTextStatesIrreversibilityAndCountsOrMayContainRecoverableItems` (locked ⇒ "may contain recoverable items").
  - `CredentialSettingsTests` additions
    - `unchangedDraftSaveIsATrueNoOp` (R5): save with no exposed change ⇒ store bytes identical, no revision.
    - `staleDraftIsRefusedWithReloadMessageAndStaysOpen`.
    - `combinedPasswordTotpWebsitesEditCommitsOneTransaction` (item 15): one account with password, TOTP and a passkey ⇒ one revision per changed kind, `modifiedAt` set, passkey byte-identical; a combined removal moves each credential with its history; both website fields parse the §12.4 result.
    - `totpAcceptsOnlyRawKeyOrOtpauth`; `transferMessagesComeFromCredentialTransferMessage`.

- [ ] **Step 2: Run the tests to verify they fail.** Run: `PRO_TEST VaultSettingsPresentationTests CredentialSettingsTests`. Expected: build failure `value of type 'CredentialSettingsModel' has no member 'vaults'`.

- [ ] **Step 3: Implement** the model additions over the Task 10 managers/store and the four view extensions; wire `WebsiteListField` for both website fields; the trash/versions/vault views never show a locked vault's content.

- [ ] **Step 4: Run the tests to verify they pass.** Run: `PRO_TEST VaultSettingsPresentationTests CredentialSettingsTests VaultTransferLifecycleTests WebsiteFieldEditingTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git add WSurf WSurfTests && git commit -m "feat(credentials): vault picker, Trash, earlier versions and fail-closed screens"`. Review gate (§Execution).

### Task 15: Gate B fixture kit

**Files:**
- Create: `Tools/CredentialFixture/server.py`, `Tools/CredentialFixture/selftest.py`

**Interfaces:**
- Consumes: Python 3 stdlib and the system `openssl` CLI only.
- Produces: `python3 Tools/CredentialFixture/server.py --origin https://HOST[:PORT] --cert PEM --key PEM` (stdlib HTTPS server: password login form, TOTP verification per RFC 6238 with ±1 step via `hmac`, WebAuthn registration and assertion verification for ES256 (SPKI built from COSE x/y, signature checked with `openssl dgst -sha256 -verify`), signature counters, in-memory state, no secret logged) and `python3 Tools/CredentialFixture/selftest.py` (**fixture-server exercise, no native claim**).
Not provided and not invented: the HTTPS origin name, its certificate/trust and DNS/hosts entry, the PRF-capable authenticator and the Apple Account (the user's own; a G2 fixture-dependent check is UNVERIFIED without them).

- [ ] **Step 1: Write `selftest.py` first.** It generates a throwaway localhost CA/certificate and a P-256 key with `openssl`, starts `server.py` on an ephemeral port as a subprocess, then asserts over real HTTPS: wrong password rejected / right password accepted; RFC 6238 vectors (`59`→`94287082`, `1111111109`→`07081804`, `1234567890`→`89005924`) accepted and a code from another step rejected; a WebAuthn registration followed by an assertion signed with the generated key verifies, a tampered signature and a replayed counter are rejected; the server's output contains none of the passwords/secrets used.

- [ ] **Step 2: Run to verify it fails.** Run (Air): `python3 Tools/CredentialFixture/selftest.py`. Expected: FAIL (`server.py` missing).

- [ ] **Step 3: Implement `server.py`** to the contract above.

- [ ] **Step 4: Run to verify it passes.** Run (Air and, once, Pro): `python3 -m py_compile Tools/CredentialFixture/server.py Tools/CredentialFixture/selftest.py && python3 Tools/CredentialFixture/selftest.py`. Expected: exit 0 and the final line `selftest: all checks passed`. No network access beyond localhost.

- [ ] **Step 5: Commit** — `git add Tools/CredentialFixture && git commit -m "test(credentials): Gate B fixture relying party and self-test"`. Review gate (§Execution).

### Task 16: Gate A closure and documentation

**Files:**
- Modify: `CHANGELOG.md` (top `## WSurf`, dated `###` entry), `SECURITY.md` (credential bullet near line 37)

**Interfaces:**
- Consumes: Tasks 1-15 landed and individually reviewed.
- Produces: the integration evidence and the coverage rows in the SDD ledger/PR text (documentation, not a test).

- [ ] **Step 1: Coverage rows.** For each spec item 1-20 and Gate A, write one ledger row `item → suite/test names that executed the assertion` from the Spec coverage section; for any item with no executed assertion, add the missing behavioral test to its owning task's suite (new commit, reviewed) before continuing.
- [ ] **Step 2: Integration gate (Main, Pro).** Run the §Verification integration gate: format check with the pinned SwiftLint 0.65.1, the full suite with coverage, coverage floor read from `.github/workflows/ci.yml`, performance check, acknowledgements unchanged. Also run the Pro-only benchmarks once: `PRO_TEST VaultVerificationBenchmark VaultMoveBenchmark`; record bounded memory and wall time. Expected: all green; any failure is fixed in its owning task's files and re-reviewed.
- [ ] **Step 3: Documentation.** `CHANGELOG.md`: what changed, the one-way migration and `.pre-v2`, downgrade consequence, bounded limits and Apple-side limits; nothing says "synced". `SECURITY.md`: store, registry, RK inside heads, A3 non-cryptographic, logical purge, the policy field in the sealed head, bounded limits (§6.7). Docs checks: `git diff --check`; `test -e` for every path named in both files.
- [ ] **Step 4: Cleanup.** Remove scaffolds and throwaway scripts; `grep -rn "forProfile\|TODO\|FIXME" WSurf/Web/Credentials WSurf/Settings/Pages` returns nothing new; `grep -rni "synced\|erased\|securely cleared" WSurf/Web/Credentials WSurf/Settings/Pages CHANGELOG.md SECURITY.md` shows only negations.
- [ ] **Step 5: Final review.** `review-package` over the whole branch BASE (`46fd7b6`) .. HEAD; one independent whole-branch review against the Review Focus; findings fixed and re-reviewed.
- [ ] **Step 6: Commit** — `git add CHANGELOG.md SECURITY.md && git commit -m "docs(credentials): vault sync changelog and security notes"`.

### Task 17: Delivery (PR, merged-SHA build, artifact checks, guarded install, user acceptance hand-off)

**Files:** none in source. Evidence goes to `.superpowers/sdd/2026-10-12-credential-vault-sync/delivery.md` and the PR. Each step blocks the next; a blocked prerequisite stops the task and is reported, never worked around.

**Interfaces:**
- Consumes: the reviewed feature commits and the Task 16 final-review result; CI evidence (PR head and merged-SHA runs, Steps 1-2). The user's deploy authorization is recorded before Step 9. The user's native Gate B results are not a precondition of any step: they are reported by the user after Step 9 (never produced by this task) and only recorded at Step 10.
- Produces: the exact merged `main` SHA; the signed-artifact provenance (source SHA, SHA-256, entitlement and profile checks); the backup and install verification receipt; the native-acceptance checklist with the user's reported results as UNVERIFIED-until-reported ledger rows. No product code.

- [ ] **Step 1: Branch → PR.** Push `feature/credential-vault-sync-20261012`; open a PR into `main` from Air (`gh` is logged in on Air, not on Pro) meeting the ruleset (`CONTRIBUTING.md`, `RELEASING.md:26-30`); no direct commits to `main`. Expected: PR URL recorded.
- [ ] **Step 2: CI.** CI green on the PR head; merge through the PR; CI green on the exact merged `main` SHA (record it). A PR/feature build is validation only.
- [ ] **Step 3: Source export.** `git archive <merged-sha>` on Air → owned Pro directory `T=/tmp/wsurf-signed-<sha7>.XXXX` (`mkdir -m 700`); record the tree hash; no dirty tree.
- [ ] **Step 4: Pinned tools.** SwiftLint 0.65.1 portable zip with the sha from `.github/workflows/ci.yml` into `$T/tools/`; no global install.
- [ ] **Step 5: Wrapper set.** Re-check existence, then copy into the **new** `$T/out/` the historical Pro wrapper set (`/tmp/wsurf-signed-46fd7b6.htGNp1/out/{run-build-attempt.sh,macros-approval.py,kc-probe,kc-probe.swift}`); re-parametrize `T`, the host/exchange profile UUIDs (`fd8a4cee-f8e7-4aff-831a-ef76ac881b24`, `b4bca0c5-be57-4c7f-9e2e-225093b2aaeb`, re-verified as installed and unexpired) and macro fingerprint/receipt paths; review the diff; never run the old hardcoded wrappers.
- [ ] **Step 6: Signed build on Pro** from the user's GUI Terminal after the user unlocks the login keychain (SSH signing is unverified), one wrapper run at a time (global `pgrep -x xcodebuild` guard), a fresh scoped macro approval from the user if a macro needs it, `DEVELOPER_DIR` explicit; Gate A's targeted suites on the same snapshot first. Expected: a signed app; record its SHA-256.
- [ ] **Step 7: Artifact checks.** `codesign -d --entitlements` and embedded profiles: credential-provider entitlement present, `ASCredentialExchangeActivity` in `NSUserActivityTypes`, extension `SupportsCredentialExchange`, extension has **no** app group or keychain access group, **no** `com.apple.developer.web-browser.public-key-credential`, entitlements ⊆ profile grants.
- [ ] **Step 8: Ship to the Air.** `ditto -c -k --keepParent --sequesterRsrc`, scp to a private (`0700`) staging directory outside `/Applications` and readable by the user's own account (for example under `/Users/Shared/`), verify sha256 equals Pro's, `codesign --verify --deep --strict`, profile membership via `system_profiler -json SPHardwareDataType` `provisioning_UDID` (not `platform_UUID`).
- [ ] **Step 9: G6 guarded install (the user is present for quiescence; no Gate B pre-condition, 2026-10-12 direct instruction).** Preconditions, checked and recorded: Steps 1-8 passed for this exact artifact, the user's deploy authorization is recorded, and no WSurf process is running. Fresh Cmd-Q of every WSurf (including old builds) immediately before the swap. Copy the historical helper (`/Users/klukacin/projects/wsurf/.worktrees/credentials-integration-20261010/.build/credential-takeover-20261010/air-deploy-swap.py`, existence re-checked, receipts in `…/air-deploy-artifacts-20261011/`) into an owned private directory, record its sha, review any diff, run `python3 <copy> <SIGNED_APP> <host cdhash>` with `WSD_SANDBOX` unset. Inside it: lock, private (`0700`) whole-data Library-relative backup (WAL-consistent, every `Credentials.*`, settings) and previous-bundle backup, production-data checksums before and after, copy the bundle next to `/Applications/WSurf.app`, `RENAME_SWAP`, verify the code signature and provenance (source SHA, artifact SHA-256 equal to Pro's), production data byte-unchanged **before** the user launches. Backups and the previous bundle stay as rollback (old app + pre-launch data backup, never the migrated store opened by the old app). The agent never launches the installed app and never touches production credentials; the one-way migration happens only at the user's own first unlock behind the §10 confirmation. Record SHA, artifact hash, backup paths and the authorization. Nothing is tagged, published or released. Expected: the user launches the deployed app themselves.
- [ ] **Step 10: Native acceptance hand-off (user-run on their own macOS and Apple accounts, after Step 9; agents run none of it).** Prepare the checklist from spec §16 G1-G5, one ledger row each with status **UNVERIFIED**, adding one row in which the user reads every transfer message wording (§13.5), the Empty Trash confirmation and the blocked-restore message once and reports whether it is truthful (no unit test pins that text). G2 uses Task 15's fixture only if the user provides an origin; otherwise its fixture-dependent checks stay UNVERIFIED. G4 is the user's own first unlock of the real legacy vault (migration confirmation, original passkey, reported unlock time); the agent never migrates or copies real data. G1 unsupported ⇒ **blocked**. Record what the user reports, verbatim and dated; no item is marked passed from agent evidence, an artifact check or a PR build. Expected: the checklist delivered to the user and the ledger holding their reported results as they arrive.
