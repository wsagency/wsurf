# Per-Profile Credential Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Develop a separate encrypted per-profile manager for WSurf passwords, website passkeys, and TOTP across WebKit and Chromium, with explicit two-direction Apple Passwords exchange of all three types. Existing Keychain SavedPassword/SecureAutofillVault, password settings/autofill, and data remain unchanged and active by default; no automatic migration, deletion, or cutover.

**Architecture:** One encrypted vault per normal profile serves the new manager. Build the protected store and manager independently of native PRF-provider feasibility; Apple PRF remains the preferred unlock path and is integrated/verified late. Never use fake production keys or plaintext fallback. Manager selection is explicit and mutually exclusive with legacy password autofill.

**Tech Stack:** Swift 6 / Swift Testing, SwiftUI / AppKit, Foundation, Synchronization, CryptoKit, LocalAuthentication, AuthenticationServices, WebKit, existing CefSwift; a Python-stdlib HTTPS fixture with an independent OpenSSL verifier.

**Spec:** `docs/superpowers/specs/2026-10-05-profile-credential-manager-design.md`

**Status:** Approved plan, reconciled with binding 2026-10-09 direction below. Consequential external actions still require exact interactive approval at their point of risk.

**Source baseline:** `origin/main` at `9606f9d4d14669798049f32c37aa8f8beab7e2c8`, fetched on 2026-10-06. Continue on `feat/profile-credentials-20261006` in `/Users/klukacin/projects/wsurf/.worktrees/profile-credentials-20261006`; do not restart from the old private source snapshots.

## Current-main integration

See `docs/superpowers/plans/2026-10-10-credential-current-main-integration.md`. The old path above (`feat/profile-credentials-20261006` in the Air worktree) remains current until an explicit freeze/handoff. The next integration starts from freshly fetched `origin/main` as a selected, credential-only port, not a merge of this branch.

## Global Constraints

- Independent encrypted vault, key, and lock state for each normal profile. At most 1,000 account items and 4,000,000 decrypted payload bytes per profile; validate bounded input before decoding or mutation.
- Random 256-bit data-encryption key per vault; CryptoKit AES-GCM, fresh nonce per write, authenticated format/profile/vault identity. Keep account metadata encrypted.
- Keep the five-minute authentication/context ceiling; webpage activity does not extend authorization.
- Preferred unlock is external passkey PRF at controlled `wsurf.app`; use fresh assertions/challenges and do not persist PRF outputs or derived wrapping keys. Core storage/crypto/tests do not wait for platform PRF proof. Native Apple registration/unlock is a late gate requiring exact interactive approval. No fake production key, plaintext fallback, recovery key, master password, or new Keychain fallback.
- Existing Keychain `SavedPassword`/`SecureAutofillVault`, password settings/autofill, and records remain unchanged and active by default. No migration, automatic read-through, deletion, replacement, or cutover. The new manager is separate. Its selection is explicit, follows current settings conventions, and is mutually exclusive with legacy password autofill: never simultaneous autofill writers. Switching changes the selected provider only; it does not rewrite either store.
- Private pages never access normal-profile credentials or create persistent private vaults. Every request uses its native originating profile ID.
- Never maintain plaintext indexes for the new vault. Preserve legacy and unrelated payment-card, contact, assistant API-key, and MCP credential storage.
- TOTP: 6–10 digits, positive UInt16 period, SHA-1/256/512, 64-bit Unix-time counter; defaults 6 digits/30 seconds.
- Website passkeys: ES256/P-256; reject unsupported algorithms before mutation; no hardware/enterprise attestation claim and zero counter for transferable software credentials. Fresh native verification for `userVerification: required`; no secret key/seed to JavaScript.
- Explicit Apple exchange only: system-mediated transfer of passwords, website passkeys, and TOTP in both directions. Do not claim provider acceptance absent use verification. Credential-provider extension registration uses `SupportsCredentialExchange = YES` and `SupportedCredentialExchangeVersions = ["1.0"]`; Task 3 follows the extension/activity/token contract in spec §4. Do not claim eligibility from configuration alone. No silent fallback, automatic synchronization, CSV substitute, cloud sync, new crypto dependency. FIDO2 exchange fields require macOS 26.4+.
- Native builds/tests on Pro with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; keep app deployment floor macOS 26.0 and handle availability.
- Stage mode DEBUG-only; use a separate stage app/home, never Release or production data. Confirm exact external credential creation/transfer, signing changes, publication, permissions, and sensitive-data access at risk. Provider approval stays interactive.
- All work stays in the assigned Air feature worktree; native source/build/test uses the dedicated Pro feature worktree when actually available and explicitly dispatched. Do not use another checkout as source mirror.
- Follow PR/release policy. No commit before the assigned verification phase.

## Review Focus

1. Lock/profile race at disk-write/delivery boundary; completed commits report receipts.
2. Duplicate/case-distinct account usernames never select another account.
3. TOTP origin association, fresh code, and 10-digit boundary correctness.
4. Child-frame replacement, forged policy/origin, and stale-document delivery fail closed.
5. Exchange preserves key identity/optional metadata, rejects unsupported/lossy paths, and distinguishes API success from recipient acceptance.

---

## Scope, dependency graph, and gates

All fourteen tasks remain; no password-only subset. Tasks 4 and 6 form the independent encrypted credential core; Task 5 adds lifecycle/unlock semantics, implementing the preferred PRF boundary without blocking core work on Apple feasibility. Tasks 7–8 add the new manager/settings/autofill, but preserve legacy files, records, and behavior. Task 8 includes explicit mutually exclusive manager selection, defaulting to legacy. Tasks 9–11 implement WebAuthn. Tasks 12–13 implement explicit transfer. Tasks 1–3 are late native integration/acceptance gates, not prerequisites for core development; Task 14 is whole-feature acceptance.

Dependency graph: Task 1 is a late PRF integration gate (no prerequisite for Tasks 4–8); Task 2 is a late native two-engine acceptance gate (no prerequisite for Tasks 9–11 implementation); Task 3 is a late Apple Passwords participation gate (no prerequisite for Tasks 12–13 implementation). Task 4 is the stable core API producer. Task 5 depends on 4; Task 6 depends on 4; Task 7 depends on 4+5+6; Task 8 depends on 4–7 and adds explicit mutually exclusive manager selection; Task 9 depends on existing native engine context APIs and core account data (not Task 2 acceptance), with its own security acceptance retained; Task 10 depends on 4+5+9; Task 11 depends on 5+9+10; Task 12 depends on 4+6+10; Task 13 depends on 5+7+12; Task 14 depends on every preceding task and every named acceptance outcome. All fourteen remain. Shared-file mutations require one owner; never parallelize shared-file edits.

**Gate evidence:** Record OS/build/signing identity, owned fixture, observable result, and blocker without secrets. Injected PRF/crypto-vector tests establish crypto correctness only, not Apple PRF support. If Apple PRF is unavailable, preserve the encrypted store and legacy default; report the exact native blocker, never weaken protection. If verified engine context fails, stop the affected website authenticator integration. If Apple Passwords lacks a direction/type, report that cell while preserving completed independent core and legacy behavior; never substitute CSV.

The following file map assigns ownership; binding legacy-preservation and late native-gate constraints are stated above.

Keep the existing file map below with these binding constraints: Task 1 is late PRF integration; Task 3 is late exchange/provider integration. Tasks 7–8 add the new manager without deleting `SavedPassword.swift`, `PasswordSettingsModel.swift`, `PasswordSettings.swift`, old settings/autofill behavior or data. Task 8 owns an explicit mutually exclusive manager selection following existing settings conventions. Do not replace `SecureAutofillVault` or password-only paths as part of this plan.

## File responsibilities

Paths marked **new** are deliberate additions, not existing helpers. Source/test directories are synchronized by the Xcode project; only the new extension needs an explicit new target.

| Files | Responsibility / owning task |
|---|---|
| `WSurf/Stage/CredentialIntegrationProbe.swift`, `CredentialWebAuthnProbe.swift` **temporary**, `WSurf/Stage/StageRun.swift` | Explicit Debug-only native gate UI and ephemeral PRF/WebAuthn/exchange assertions; Tasks 1–3. Remove probes after their late native smoke proof. |
| `Tools/CredentialFixture/server.py` **new** | Owned HTTPS login/WebAuthn fixture, independent registration/assertion verification with OpenSSL, deterministic account/TOTP fixtures; Tasks 2–3, 14. No production service. |
| `WSurf/WSurf.entitlements`, `WSurf/Info.plist`, `WSurf.xcodeproj/project.pbxproj`, `WSurf.xcodeproj/xcshareddata/xcschemes/WSurf.xcscheme`, `WSurf/App/AppDelegate.swift` | Signed Associated Domains, embedded exchange extension, activity dispatch, termination locking; Tasks 1, 3, 5, 13. |
| `WSurfCredentialExchange/Info.plist`, `WSurfCredentialExchange/WSurfCredentialExchange.entitlements`, `WSurfCredentialExchange/CredentialExchangeProvider.swift` **new** | Capability-only credential-provider extension `io.wsagency.wsurf.CredentialExchange`; exchange eligibility, not general AutoFill or a second credential store; Task 3. |
| `WSurf/Web/Credentials/CredentialAccount.swift` **new** | Bounded account/passkey/TOTP value types, encrypted account metadata and exchange identifiers, canonical HTTPS login scopes; Task 4. |
| `WSurf/Web/Credentials/CredentialVault.swift`, `CredentialVaultCrypto.swift` **new** | Per-profile actor, bounded encrypted file, authenticated wrappers, atomic mutations, revocable authorization and commit receipts; Task 4. |
| `WSurf/Web/Credentials/PasskeyKeyEncoding.swift` **new** | Strict P-256 PKCS#8 validation before vault mutation, reused by authenticator/exchange; Task 4. |
| `WSurf/Web/Credentials/PasskeyVaultUnlocker.swift`, `CredentialManager.swift` **new** | Preferred native PRF requests/cancellation, observable profile state and security-event invalidation; Task 5. Provider-independent core is implemented/tested without claiming native PRF proof. |
| `WSurf/Web/Credentials/TOTP.swift` **new** | Validated setup, RFC 6238 calculation and lifetime; Task 6. |
| `WSurf/Settings/Pages/CredentialSettings.swift`, `WSurf/Web/Credentials/CredentialSettingsModel.swift` **new** | Add new manager alongside existing password settings; account editor, unlock management, secret display/copy and exchange controls; Tasks 7, 13. |
| `WSurf/Settings/Pages/AutofillSettings.swift`, `WSurf/Settings/BrowserSettings.swift`, `WSurf/Extensions/ExtensionManager.swift`, `WSurf/App/AppCoordinator.swift` | New manager entry and explicit mutually exclusive provider selection; preserve legacy password settings/autofill/data and unrelated extension behavior; Tasks 7–8. |
| `WSurf/Web/Autofill/PasswordAutofill.swift`, `PasswordAutofillScript.swift`, `AutofillFormScript.swift`, `AutofillSuggestionScript.swift`, `AutofillSaveScript.swift` | Existing shared transport/classification plus new-manager password and OTP operations; Task 8. Keep password adapter name and legacy behavior. |
| New-manager callsites in `AutofillSuggestions.swift`, `AutofillSaveCoordinator.swift`, `AutofillSubmissionTracker.swift`, `AutofillSaveCandidate.swift`, `AutofillSuggestion.swift`, `AutofillSaveIndex.swift` | Account-aware selection/save/update and one login context behind explicit new-manager selection; keep legacy password paths and shared card/contact behavior unchanged. |
| `WSurf/UI/Content/AutofillSuggestionList.swift`, `AutofillSavePopover.swift`, `AutofillSaveReview.swift`, `WSurf/Settings/Pages/AutofillSavePromptReset.swift` | Existing native picker/review and per-kind prompt reset; Task 8. |
| `WSurf/Profiles/Profile.swift`, `WSurf/App/AppCoordinator+Profiles.swift`, `WSurf/Web/Model/BrowserModel+Switching.swift` | Profile invalidation/removal and adoption; Tasks 5, 8. |
| `WSurf/Web/Engines/BrowserPage.swift`, `BrowserFrame.swift`, `ChromiumDevTools.swift`, `ChromiumPage.swift`, `WSurf/Web/Tabs/BrowserTab.swift`, `BrowserTab+WebKitDelegates.swift`, `BrowserTab+PageLifecycle.swift` | Native document/frame generation, lifecycle cancellation, engine policy evidence and adapter installation; Tasks 9, 11. |
| `WSurf/Web/Credentials/WebAuthnContext.swift`, `RelyingPartyPolicy.swift`, `public_suffix_list.dat` **new** | Verified request context and licensed bundled Mozilla PSL; Task 9. Do not use `SiteName`'s display heuristic. |
| `WSurf/Web/Credentials/WebsiteAuthenticator.swift`, `WebAuthnEncoding.swift` **new** | ES256 ceremonies, UP/UV and WebAuthn encoding; Task 10. |
| `WSurf/Web/Credentials/WebAuthnAdapter.swift`, `WebAuthnScript.swift` **new** | Common native request registry and document-start public-key API adapter; Task 11. |
| `WSurf/Web/Credentials/CredentialExchangeCodec.swift`, `CredentialExchangeCoordinator.swift` **new** | Lossless bounded Apple records, import conflicts, system-token/export UI flow; Tasks 12–13. |
| `WSurfTests/Web/CredentialVaultTests.swift`, `CredentialLifecycleTests.swift`, `TOTPTests.swift`, `CredentialSettingsTests.swift`, `CredentialAccountSelectionTests.swift`, `WebAuthnContextTests.swift`, `WebsiteAuthenticatorTests.swift`, `WebAuthnAdapterTests.swift`, `CredentialExchangeTests.swift` **new** | Permanent consumer-visible boundaries and transitions; Tasks 4–13. |
| `WSurfTests/Helpers/WebAuthnVerifier.swift` **new**, existing `HTTPFixtureServer.swift`, `TestClock.swift`, `WebKitMessages.swift` | Independent Security-framework verification and existing deterministic engine/clock fixtures; Tasks 9–11. No real Apple account access in the ordinary test suite. |
| Existing `WSurfTests/Web/SecureAutofillVaultTests.swift`, `PasswordAutofillScriptTests.swift`, card/contact/save tests | Preserve legacy contracts and add new-manager selection/context coverage; Tasks 7–8. |
| `WSurf/Web/Autofill/SavedPassword.swift`, `PasswordSettingsModel.swift`, `WSurf/Settings/Pages/PasswordSettings.swift`, `SecureAutofillVault.swift`, password-only index/cache/factory paths | Preserve existing behavior, settings, storage and records unchanged as legacy default; no delete or migration. |
| `WSurf/Web/Autofill/README.md`, `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `RELEASING.md` | Update actual manager behavior and signed verification/release procedure after smoke proof in the owning tasks. |

## Execution and verification conventions

Use the assigned Air feature worktree for documentation/source changes. The Pro linked feature worktree is the only native source/build/test target; verify actual path, branch, and dirty state before any later explicitly assigned sync or gate. Never overwrite unrelated dirty content or treat the Pro mirror as merge source.

Before changing an exported symbol, query LSP references and migrate every caller. Follow Main Actor isolation and existing Swift Testing conventions. A crypto test using known PRF input proves cryptography only, not native Apple provider behavior.

Verification is performed only by the director-designated verification worker after explicit authorization. That worker captures the full remote log and exact failures. Editing workers do not run builds, tests, lint, or formatters. Use the durable native execution runbook below when a gate is explicitly assigned.

### Native execution runbook (Pro/Air; only after explicit gate authorization)

Set the owned Pro paths before an assigned remote test/build:

```bash
PRO_WORKTREE=/Users/klukacin/projects/wsurf/.worktrees/profile-credentials-main-refresh-20261006
PRO_DERIVED_DATA="$PRO_WORKTREE/.build/DD"
CEF_PACKAGE="$PRO_WORKTREE/.build/SourcePackages/checkouts/CefSwift"
```

The Pro source/dependency worktree must be the assigned feature worktree; keep its existing SourcePackages cache and verify the CEF checkout is pinned to `59cad64e124b8efdb6b2ee811963097bb6e689e8`. For a specifically assigned Swift Testing suite, set `SUITE` to its plan name and use:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes pro \
  "cd '$PRO_WORKTREE' && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer WSURF_CEF_PACKAGE='$CEF_PACKAGE' xcodebuild test -project WSurf.xcodeproj -scheme WSurf -destination 'platform=macOS,arch=arm64' -derivedDataPath '$PRO_DERIVED_DATA' -clonedSourcePackagesDirPath '$PRO_WORKTREE/.build/SourcePackages' -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation -skipPackagePluginValidation -only-testing:WSurfTests/$SUITE CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="
```

This unentitled test command does not prove native integration. For an assigned native gate/smoke, build the signed **Debug** app with real target entitlements and provisioning:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes pro \
  "cd '$PRO_WORKTREE' && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer WSURF_CEF_PACKAGE='$CEF_PACKAGE' xcodebuild build -project WSurf.xcodeproj -scheme WSurf -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath '$PRO_DERIVED_DATA' -clonedSourcePackagesDirPath '$PRO_WORKTREE/.build/SourcePackages' -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation -skipPackagePluginValidation"
```

Inspect signed entitlements and embedded provisioning; verify `codesign --verify --deep --strict` on Pro and Air. Copy a separate Debug app to the Air and record owned `AIR_STAGE_APP` and `STAGE_HOME` paths. Launch only the copied executable with `WSURF_STAGE=1 WSURF_STAGE_HOME="$STAGE_HOME"`; for the prepared Task 1/2 probes, additionally use `WSURF_CREDENTIAL_PROBE=1 WSURF_CREDENTIAL_FIXTURE_ORIGIN=https://localhost:57443`. These flags expose test UI, not authorization. Never use Release, production browsing data, or the installed app as the isolated stage.

The owned HTTPS fixture starts with `python3 Tools/CredentialFixture/server.py --port 57443 --cert CERT --key KEY`; it binds only to `127.0.0.1` and keeps credential/challenge state in memory (there is no `--host` or `--state` option). Its self-check is `python3 Tools/CredentialFixture/server.py --self-check`; exit 0 requires independent valid registration/assertion and deliberately invalid challenge/signature cases. Preserve the running fixture process for identity continuity. Use `https://localhost:57443` and fixture-only trust in the owned stage; never change global Keychain trust or bypass production TLS. Keep private fixture data out of logs and commits.

StageRun reseeds browsing tabs at launch. Restart evidence must compare persisted account/credential IDs and successfully use their secrets in the same owned stage home; seeded tabs alone do not prove persistence. Before fetching an OS transfer token, verify the launched recipient's PID, app path, and stage home. If the token is routed to the installed/production app, do not fetch it; stop and correct routing only with explicit approval for any registration change. A locked Air desktop is a human-unlock prerequisite, not permission to bypass login.


### Current execution checkpoint

- Historical setup/signing/profile statements remain historical; Associated Domains setup is done and must not be repeated. Managed Browser Requests was declined and is not a prerequisite for the distinct owned-RP PRF path. Never blindly strip entitlements or resubmit a managed request.
- Air feature worktree is the active documentation/coordination workspace. Pro mirror path and branch exist remotely; current dirty state is recorded in `.superpowers/sdd/2026-10-06-profile-credential-manager/orchestration-coordination.md`. It is a build/source mirror, not a merge source; preserve all existing dirty files.
- No native PRF, both-engine WebAuthn, or Apple Passwords participation gate has been accepted by this plan. Keep all fourteen tasks, all six transfer cells, engine security checks, and exact point-of-risk approvals.

### Task 1: Late native integration gate for preferred PRF unlock

**Files:** Reuse prepared temporary `WSurf/Stage/CredentialIntegrationProbe.swift` and `StageRun.swift` entry, existing entitlement/signing settings; update `RELEASING.md` only after proof.

**Interfaces:** Consumes AuthenticationServices registration/assertion and `ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues`. Produces a gate record for stable PRF input, distinct credential IDs, AES-GCM wrapping/unwrapping and cancellation; never persists PRF output or DEK.

- [ ] **RED:** Verify that repeat assertions for one credential with its stable PRF input yield the same PRF output/derived wrapping key; a wrong output cannot unwrap. Missing output must produce `unsupportedPRF`, with no substitute. Report native-provider outcomes separately from crypto tests.
- [ ] Register at least two owned passkeys for the same RP with distinct random user IDs (Apple may replace a credential registered with the same user ID). After registering the second and after restart, assert both credentials remain independently usable; verify stable per-credential PRF inputs and the required repeat-assertion result for each.
- [ ] Run only at late native integration after provider-independent implementation. Do not block Task 4, TOTP, manager, WebAuthn implementation, or conversion work.
- [ ] Complete the explicit probe UI and `webcredentials:wsurf.app`, using fresh 32-byte challenges, stable random PRF input per credential, distinct random user IDs, retained native completion delegate, and cancellation.
- [ ] Obtain exact interactive approval before creating test credentials. Verify signed identifier/provisioning/AASA and both independent credential paths with the repeat, wrong-output, missing-output, and continued-usability assertions above.
- [ ] If unavailable, report the native blocker; keep the encrypted store protected and legacy behavior active. No substitute key, plaintext fallback, recovery feature, or any-RP browser capability.
- [ ] Commit only after the separately assigned verification phase.

### Task 2: Late two-engine WebAuthn integration gate

**Files:** Reuse `Tools/CredentialFixture/server.py`, temporary probe and existing `BrowserPage`/engine APIs.

**Interfaces:** Native page/frame transport to the independent verifier. Real server-accepted ceremonies are native acceptance evidence only after both actual engine adapters exist.

- [ ] **RED:** Preserve verifier checks for valid registration/assertion and changed challenge/origin/RP hash/signature rejection.
- [ ] Implement/test fixture and production context boundaries independently; native two-engine acceptance is late and does not block encrypted-core work.
- [ ] At native acceptance, exercise actual create/get, abort/navigation/frame replacement, invalid RP and required UV on both engines. Missing native policy evidence blocks that path; fail closed.
- [ ] No CDP virtual authenticator or echo response as production proof.
- [ ] Commit only after assigned verification.

### Task 3: Late Apple Passwords integration gate for all six transfers

**Files:** Exchange extension/project/activity registration and temporary probe.

**Interfaces:** AuthenticationServices import/export API; evidence matrix is password/passkey/TOTP × both directions, each verified by use. Follow the extension construction, activity registration, and token-routing contract in spec §4; exact capability keys are in Global Constraints.

- [ ] **RED:** Keep owned fixture password, P-256 PKCS#8 passkey and RFC 6238 seed; API return/item count is not acceptance.
- [ ] Implement SDK/model conversion and coordinator independently of Apple Passwords participation. Native integration is late and does not block Tasks 4–12.
- [ ] Embed the credential-provider extension at `com.apple.authentication-services-credential-provider-ui`, with `ASCredentialProviderViewController` as principal class and an accessible configuration view explaining exchange is managed in WSurf. It is not a general password/passkey/OTP AutoFill provider and adds no second store or app-group/shared-secret data channel.
- [ ] Register the containing app activity using the documented Info.plist `NSUserActivityTypes` entry `ASCredentialExchangeActivityType`; match the delivered runtime activity against SDK constant `ASCredentialExchangeActivity` and retrieve its UUID from `userInfo[ASCredentialImportToken]`. This documentation/runtime naming discrepancy is intentional; do not assume the Info.plist spelling is an exported SDK symbol or infer provider eligibility from registration.
- [ ] Keep probe/transfer secrets ephemeral or in the owned encrypted fixture; never stage plaintext credential files.
- [ ] Obtain point-of-risk approval before external credential creation/transfer; verify all six cells by password login, server-accepted passkey, and matching TOTP sequence/parameters.
- [ ] Report unavailable cells precisely; no CSV substitute, false acceptance claim, or disabling the protected store/legacy behavior.
- [ ] Commit only after the separately assigned verification phase.


### Task 4: Implement bounded accounts and the atomic encrypted vault

**Files:** Create `CredentialAccount.swift`, `CredentialVaultCrypto.swift`, `CredentialVault.swift`, `PasskeyKeyEncoding.swift` under `WSurf/Web/Credentials/`; create `WSurfTests/Web/CredentialVaultTests.swift`.

**Interfaces:** Produces the following native-only types and methods; later tasks consume these exact names.

- `CredentialAccount: Codable, Sendable, Identifiable`: `id: UUID`, `username: String`, `displayName: String?`, `origins: [String]`, `loginURLs: [URL]`, `password: String?`, `passkeys: [WebsitePasskey]`, `totp: TOTPGenerator?`, `exchangeAccountID: Data?`, and `exchangeItemID: Data?`. Origins are canonical HTTPS strings; login URLs retain origin/path only.
- `WebsitePasskey: Codable, Sendable, Identifiable`: internal `id: UUID`, `credentialID: Data`, `rpID: String`, `userHandle: Data`, `userName: String`, `userDisplayName: String`, `algorithm: Int`, `privateKeyPKCS8: Data`, `backupEligible: Bool`, `backupState: Bool`, `exchangeFIDO2Metadata: Data?`. `algorithm == -7`; new transferable credentials have `backupEligible = true`, `backupState = false`, not an inferred cloud-sync claim.
- `TOTPGenerator: Codable, Sendable`: `secret: Data`, `algorithm: TOTPAlgorithm` (`sha1`, `sha256`, `sha512`), `period: UInt16`, `digits: UInt16`, `issuer: String?`, `userName: String?`.
- Account validators: `CredentialAccount.validate() throws`, `CredentialAccount.origin(for url: URL) -> String?`, `CredentialAccount.sanitizedLoginURL(_ url: URL) throws -> URL`, and `TOTPGenerator.validate() throws`. Produce `PasskeyKeyEncoding.importPKCS8(_ data: Data) throws -> P256.Signing.PrivateKey` and `exportPKCS8(_ key: P256.Signing.PrivateKey) throws -> Data`; every stored/imported passkey is validated as usable P-256, not merely tagged `-7`.
- `VaultUnlockProof` is a non-Codable ephemeral value containing `credentialID: Data`, `prfInput: Data`, `prf: SymmetricKey`; native flows produce it only after an assertion verifies a new registration or existing unlock path. `VaultAccess(profileID: UUID, epoch: UInt64, deadline: ContinuousClock.Instant)` is a revocable Sendable permit; `revoke()` is synchronous. The actor associates an access object with its DEK only after a successful create/unlock; merely constructing a permit grants no access.
- `VaultSnapshot { revision: UInt64, accounts: [CredentialAccount], blockedPasswordOrigins: Set<String> }`; `VaultCommitReceipt { revision: UInt64 }`; `VaultUnlock { credentialID: Data, prfInput: Data }`; `VaultDiscovery { vaultID: UUID, unlocks: [VaultUnlock] }`. `CredentialVault(profileID: UUID, directory: URL, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) throws` is an actor and rejects the private profile.
- Actor methods: `discovery() throws -> VaultDiscovery`; `create(unlock: VaultUnlockProof, access: VaultAccess) throws`; `unlock(credentialID: Data, prf: SymmetricKey, access: VaultAccess) throws`; `snapshot(using: VaultAccess) throws -> VaultSnapshot`; `commit(_ accounts: [CredentialAccount], expectedRevision: UInt64, using: VaultAccess) throws -> VaultCommitReceipt`; `updatePasswordSavePolicy(_ blockedOrigins: Set<String>, expectedRevision: UInt64, using: VaultAccess) throws -> VaultCommitReceipt`; `addUnlock(_ proof: VaultUnlockProof, using: VaultAccess) throws -> VaultCommitReceipt`; `removeUnlock(credentialID: Data, verifiedRemaining: VaultUnlockProof, using: VaultAccess) throws -> VaultCommitReceipt`; `lock()`. The vault has no erase operation; `lock()` nondestructively revokes/clears actor-held access and key state. Read the clock **inside** the actor at each access/commit boundary, never trust an instant captured before an actor hop.

- [ ] **RED:** `wrongKeyOrIdentityPreservesVault` checks wrong PRF/profile and altered format/header/ciphertext fail and prior bytes still unlock; corrupting an **unselected** wrapper also invalidates the authenticated manifest. `boundsAndUniqueIDsAreAtomic` accepts 1,000 items and exactly 4,000,000 payload bytes, rejects 1,001 / 4,000,001 / duplicate account or credential IDs before replacement. `wrappersRemainIndependent` unlocks with either wrapper, rejects last-path removal, corrupt new wrappers and removal without successful verification of another remaining path. `revocationAndRevisionGuardCommit` checks revoked/expired access and stale revision cannot write, failed replacement preserves old bytes, and post-commit cancellation does not erase the receipt.

  ```swift
  #expect(accepted.accounts.count == 1_000)
  #expect(acceptedPayloadBytes == 4_000_000)
  #expect(bytesAfterRejectedMutation == originalDiskBytes)
  #expect(firstUnlocked.accounts.map(\.id) == secondUnlocked.accounts.map(\.id))
  #expect(receipt.revision == before.revision + 1)
  #expect(throws: (any Error).self) {
      try TOTPGenerator(secret: seed, algorithm: .sha1, period: 0, digits: 6, issuer: nil, userName: nil).validate()
  }
  ```

  Include oversized/truncated/wrong-curve PKCS#8 and no-partial-write assertions in `invalidCredentialsCannotEnterVault`; preserve password save-prompt policy through unrelated account commits.
- [ ] Run RED with `SUITE=CredentialVaultTests`.
- [ ] Implement format version `1` at `Profile.supportDirectory/Credentials.vault`: a **single** length-bounded binary property-list envelope containing discovery manifest and encrypted JSON payload `{revision, accounts, blockedPasswordOrigins}`. Cap on-disk input at 8,000,000 bytes and wrappers at 32; cap decoded payload at 4,000,000 before JSON decoding, records at 1,000 and nested variable data by the same bounded payload budget. These envelope limits are implementation ceilings, not a larger plaintext allowance; surface wrapper-limit rejection. Discovery exposes only vault identity and public unlock inputs, never account metadata.
- [ ] Implement shared record validation and strict bounded PKCS#8 `PrivateKeyInfo` parsing/encoding for id-ecPublicKey + prime256v1. Check embedded public key/curve against the private scalar; CryptoKit's EC DER must not be assumed to be PKCS#8. Use independent key-use tests; Apple-provider proof is not needed here. TOTP record validation checks nonempty bounded secret, algorithm, digits 6–10 and positive UInt16 period; setup parsing/calculation remains Task 6.
- [ ] Implement AES-GCM fresh nonces; payload AAD is length-delimited `(format, profileID, vaultID, manifestDigest)`, where `manifestDigest` is SHA-256 of canonical public unlock records, including wrapper nonces/ciphertext. Wrapper AAD binds `(format, profileID, vaultID, credentialID, prfInput)`. HKDF-SHA-256 uses domain label `WSurf vault wrapping v1` plus profile/vault binding. Verify new/remaining wrappers recover the current DEK before adding/removing paths; any wrapper-set change reseals the payload under its new manifest digest. Atomic `Data.write(options: .atomic)` replaces manifest+payload together; validate IDs/scopes/revision/access before replacement. Retain no PRF/wrapping key after use.
- [ ] Run GREEN with `SUITE=CredentialVaultTests`.
- [ ] Smoke an owned file: create, restart/unlock, add/remove a wrapper, mutate and recover old state after a failed write.
- [ ] Review the vault result and update storage/security docs after proof.
- [ ] Commit `feat(credentials): Add atomic profile vault`.

### Task 5: Add profile unlock management and unconditional lifecycle locking

**Files:** Create `PasskeyVaultUnlocker.swift`, `CredentialManager.swift`; modify lifecycle/profile files as required; create `CredentialLifecycleTests.swift`. The PRF implementation is integrated late and must not block provider-independent lifecycle/core tests.

**Interfaces:** Consumes Task 4. Produces `@MainActor @Observable CredentialManager`, `static forProfile(_ profile: Profile) throws -> CredentialManager`, `isUnlocked: Bool`, `unlockCredentials: [VaultUnlock]`, `unlock(in anchor: ASPresentationAnchor) async throws`, `create(in anchor: ASPresentationAnchor) async throws`, `addUnlock(in anchor: ASPresentationAnchor) async throws`, `removeUnlock(credentialID: Data, in anchor: ASPresentationAnchor) async throws -> VaultCommitReceipt`, `lock(reason: CredentialLockReason)`, `snapshot() async throws -> VaultSnapshot`, `commit(_ accounts: [CredentialAccount], expectedRevision: UInt64) async throws -> VaultCommitReceipt`, and `updatePasswordSavePolicy(_ blockedOrigins: Set<String>, expectedRevision: UInt64) async throws -> VaultCommitReceipt`. `CredentialLockReason` cases: manual/profileSwitch/screenLock/sleep/termination/timeout. `VaultUnlockRegistration` carries `credentialID`, stable `prfInput`, and optional registration PRF output. `PasskeyVaultUnlocker.register(in anchor: ASPresentationAnchor) async throws -> VaultUnlockRegistration`; `verifyRegistration(_ registration: VaultUnlockRegistration, in anchor: ASPresentationAnchor, beforeAssertion: () throws -> Void) async throws -> VaultUnlockProof` performs the mandatory fresh assertion/PRF check before the first wrapper write; `assert(among unlocks: [VaultUnlock], in anchor: ASPresentationAnchor) async throws -> VaultUnlockProof` is the actual existing-path assertion API; `cancel()` owns AuthenticationServices ceremony lifetime.

- [ ] **RED:** `lateUnlockCannotReopenRevokedProfile` revokes a pending access epoch before its PRF result and asserts no unlocked state/file write. `authorizationExpiresAtFiveMinutes` accepts 299 seconds, rejects 300, and repeated webpage activity does not extend the deadline. `securityEventsRevokeAccess` checks each named reason clears account/code UI and rejects subsequent snapshot/commit; `profilesAndPrivatePagesStayIsolated` checks a second profile and private page cannot use the first access.

  ```swift
  #expect(!manager.isUnlocked)
  #expect(bytesAfterLateUnlock == originalDiskBytes)
  #expect(accessWorksAt299Seconds)
  #expect(!accessWorksAt300Seconds)
  #expect(!otherProfileCanRead && !privatePageCanRead)
  ```

- [ ] Run RED with `SUITE=CredentialLifecycleTests`; use revocable epochs and injected instants, not mocked Apple-response forwarding.
- [ ] Implement profile-scoped registry/observable state and the preferred native PRF unlock path without treating Apple provider availability as a prerequisite to building/testing the encrypted store. Create revocable pending access before a ceremony; lock synchronously revokes pending/current access, cancels native requests and notifies adapters, then releases actor-held key references. Check captured epoch after every await; never create a new epoch to rescue a canceled callback. Crypto tests may supply real test-only PRF input material directly to the vault API; label this as crypto verification, never Apple-provider evidence.
- [ ] Before wrapper removal, use `PasskeyVaultUnlocker.assert(among: remainingUnlocks, in: anchor)` for a fresh assertion of a different remaining credential and pass its `VaultUnlockProof` to the actor. `CredentialVault.removeUnlock` independently checks that the proof unwraps the current DEK before mutating wrappers. An unavailable/corrupt remaining path rejects removal unchanged. Keep profile/access checks across the ceremony; no external credential is deleted.
- [ ] Add concrete initializer `CredentialManager(profile: Profile, directory: URL, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) throws`; `forProfile` uses the profile support directory. Tests use owned files and a mutex-backed instant source. The internal `beginAccess() -> VaultAccess` / `completeUnlock(credentialID: Data, prf: SymmetricKey, access: VaultAccess) async throws` transition is shared by the real native completion and lifecycle tests, not a fake provider protocol.
- [ ] Install security observers independently of settings visibility: screen lock, sleep/session resignation and termination, plus profile switch/removal and a monotonic five-minute timer. Profile retirement unregisters and marks the manager retired, synchronously revokes access/cancels pending native ceremonies, then awaits nondestructive `CredentialVault.lock()` actor drain before `Profile.erase(_:)` performs the Profile-owned `supportDirectory` deletion. `Profile.erase` currently does not call `CredentialManager.retire(profileID:)`; wire this production hook before relying on profile erasure. Keep card/contact LA sessions unchanged. Expose actionable unsupported-PRF and permanent-loss/last-wrapper-removal warnings; removal does not delete the external credential or claim historical-backup revocation.
- [ ] Run GREEN with `SUITE=CredentialLifecycleTests`.
- [ ] Smoke the real stage: create/unlock, independent second wrapper, manual lock, profile switch, sleep/wake, timeout and restart; displayed metadata disappears and pending operations cannot finish.
- [ ] Review the lifecycle result and update docs after proof. Release Swift key/secret references; do not promise physical RAM erasure.
- [ ] Commit `feat(credentials): Manage PRF unlock and lock lifecycle`.

### Task 6: Implement validated TOTP setup and fresh generation

**Files:** Create `WSurf/Web/Credentials/TOTP.swift`, `WSurfTests/Web/TOTPTests.swift`.

**Interfaces:** Consumes `TOTPGenerator` / `TOTPAlgorithm` and `TOTPGenerator.validate()`. Produces `TOTP.parse(_ input: String, algorithm: TOTPAlgorithm = .sha1, period: UInt16 = 30, digits: UInt16 = 6) throws -> TOTPGenerator` and `TOTP.code(_ generator: TOTPGenerator, at unixTime: TimeInterval) throws -> TOTPCode`; `TOTPCode { value: String, remainingSeconds: TimeInterval, expiresAt: TimeInterval }`. Parsing a URI preserves its explicit supported parameters rather than overriding them with manual defaults.

**Status:** Task 6 implementation, native TOTP suite, actual-source counter smoke, and review are complete. Branch commit remains pending coordinated integration.

- [x] **RED:** `rfc6238Vectors` pins the published eight-digit SHA-1/256/512 results at 59, 1111111109, 1111111111, 1234567890, 2000000000, and 20000000000. `numericBoundaries` checks leading zeros, 6/10 digits, periods 1/30/65535, and times just before/at a step. `malformedSetupIsRejected` checks bad/empty Base32, duplicate/contradictory URI parameters, `otpauth://hotp`, vendor schemes, numeric login-code input, period 0/65536, digits 5/11, nonfinite/negative/out-of-UInt64-counter-range time, and unknown algorithm.

  ```swift
  // RFC seeds are the reference implementation's 20/32/64-byte ASCII seeds.
  #expect(try TOTP.code(rfcSHA1, at: 59).value == "94287082")
  #expect(try TOTP.code(rfcSHA256, at: 59).value == "46119246")
  #expect(try TOTP.code(rfcSHA512, at: 59).value == "90693936")
  #expect(try TOTP.code(rfcSHA1, at: 1_111_111_109).value == "07081804")
  #expect(try TOTP.code(rfcSHA512, at: 20_000_000_000).value == "47863826")
  ```

- [x] Run RED with `SUITE=TOTPTests`.
- [x] Implement strict bounded raw-secret/Base32 and `otpauth://totp` parsing; preserve issuer/source username, reject decimal-only login-code input and unsupported parameters without normalization. Reuse `TOTPGenerator.validate()` for parsed/imported generators. Use CryptoKit `HMAC<Insecure.SHA1>`, `HMAC<SHA256>`, `HMAC<SHA512>`, unsigned 64-bit big-endian counters and `UInt64` decimal modulus so 10 digits cannot overflow/truncate.
- [x] Run GREEN with `SUITE=TOTPTests` and the independent fixture's seed check.
- [x] Smoke generation at real post-2038/UInt64 counter boundaries and fresh step boundaries, not from a cached code.
- [x] Review the TOTP result.
- [ ] Commit `feat(credentials): Add RFC 6238 TOTP`.

### Task 7: Add credential manager settings alongside legacy settings

**Files:** Create `CredentialSettingsModel.swift` / `CredentialSettings.swift`; add an entry under existing `AutofillSettings.swift` patterns without replacing or deleting `PasswordSettingsModel.swift` / `PasswordSettings.swift`; create `CredentialSettingsTests.swift`. Keep existing password-generation behavior and legacy settings intact.

**Interfaces:** Consumes `CredentialManager` and `TOTP`. Produces `CredentialSettingsModel(profile: Profile, pasteboard: NSPasteboard = .general)`, `load() async`, `save(_ account: CredentialAccount, expectedRevision: UInt64) async throws -> VaultCommitReceipt`, `remove(accountID: UUID, expectedRevision: UInt64) async throws -> VaultCommitReceipt`, `copyPassword(accountID: UUID) async throws`, and `copyTOTP(accountID: UUID, now: @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }) async throws`. Evaluate `now` after the final asynchronous secret/context lookup, immediately before copying. Native views read secret-free summaries; reveal/copy obtains the selected account under current authorization. Tests inject a uniquely named pasteboard, never overwrite the user's clipboard.

- [ ] **RED:** `editingOneAccountPreservesItsNeighbours` updates one of ten same-origin accounts and checks all others' secrets/passkeys/TOTP are unchanged, including duplicate display usernames and case-distinct usernames. `standaloneCredentialsRemainEditable` saves passkey-only/TOTP-only accounts. `lockClearsVisibleSecrets` checks revealed password/current OTP and summaries disappear on lock. `copyComputesCurrentTOTP` checks a boundary-time copy uses the new code.

  ```swift
  #expect(updatedPassword == "new-selected-password")
  #expect(neighbourPasswords == originalNeighbourPasswords)
  #expect(savedPasskeyOnlyAccount.password == nil)
  #expect(savedTOTPOnlyAccount.password == nil)
  #expect(testPasteboard.string(forType: .string) == freshBoundaryCode)
  ```

- [ ] Run RED with `SUITE=CredentialSettingsTests`.
- [ ] Implement the new manager's settings primitives and revision guards: vault creation/unlock/lock, account add/edit/delete, password generation/reveal/copy, explicit origin associations and sanitized login URLs, TOTP setup/code/lifetime, passkey metadata/removal, and unlock controls. Existing legacy settings remain unchanged. TOTP timers exist only while unlocked; clear new-manager UI at lock. Invalid forms must not mutate the vault. Preserve localizable copy, keyboard access and VoiceOver labels.
- [ ] Run GREEN with `SUITE=CredentialSettingsTests`.
- [ ] Smoke the real stage UI: ten accounts, edit just one, standalone records, explicit cross-origin association, TOTP setup/copy and lock.
- [ ] Review the new manager result and update README/changelog after proof; preserve old settings/model consumers and aliases are not introduced.
- [ ] Commit `feat(credentials): Add credential manager settings`.

### Task 8: Add explicit manager selection and contextual credentials without changing legacy behavior

**Files:** Add new-manager selection and contextual account behavior using existing autofill settings/picker patterns. Do not delete or rewrite `SavedPassword.swift`, `SecureAutofillVault.swift`, password-only caches/indexes, existing settings, or their tests/data. New-manager flows may add callsites and selection policy while legacy paths remain callable and unchanged. Create `CredentialAccountSelectionTests.swift`; preserve affected shared card/contact behavior.

**Interfaces:** Consumes Tasks 4–7 and existing suggestion/request validation. Extend **the existing** `AutofillSaveSession.UsernameStep` with `accountID: UUID?`, `profileID: UUID`, native tab identity, canonical origin and a monotonic selection deadline; preserve save-attempt correlation. Produce `AutofillSaveSession.selectedAccount(in page: BrowserPage, origin: String, enteredUsername: String?, now: ContinuousClock.Instant) -> UUID?` and `selectAccount(_ id: UUID, username: String, in: BrowserPage, origin: String, now: ContinuousClock.Instant)`. Context retains identity, never a secret/code.

- [ ] **RED:** `tenAccountsRequireTheIntendedNativeSelection` checks empty/partial/exact input, ambiguous duplicate usernames, case-distinct usernames, path relevance and no automatic secret fill. `usernameChangeInvalidatesNextStep` checks selected account carries across same-tab/origin username→password→OTP navigation for 299 seconds but not 300; changed username, new tab/origin/profile, lock or stale frame cannot retrieve the previous secret. `passwordUpdateNeedsSelectedAccountAndConsent` preserves other nine accounts and all passkeys/TOTP. `totpFillNeedsAssociationAndFreshCode` blocks issuer-only scope and computes at delivery time.

  ```swift
  #expect(chosenAccountID == gmailAccount7.id)
  #expect(caseDistinctAccounts.map(\.id) == [upperCaseAccount.id, lowerCaseAccount.id])
  #expect(session.selectedAccount(in: page, origin: origin, enteredUsername: changedUsername, now: t0) == nil)
  #expect(session.selectedAccount(in: page, origin: origin, enteredUsername: selectedUsername, now: t0.advanced(by: .seconds(300))) == nil)
  #expect(unrelatedPasswordsAfterUpdate == unrelatedPasswordsBeforeUpdate)
  ```

- [ ] Run RED with `SUITE=CredentialAccountSelectionTests` and the affected cases in `PasswordAutofillScriptTests`; use actual nonpersistent engine form fixtures, not mocked JS echoes.
- [ ] Query encrypted account metadata only after explicit unlock and native request checks. Reuse the existing native picker, request geometry/focus/visibility and final field validation. Exact/partial username comparison must not globally case-fold identities. Add `.totp` field handling without sending seeds to JS or treating a submitted OTP as a saved password; preserve card/contact classification and submission behavior.
- [ ] Save first accounts/changed passwords only after existing native review confirms the exact account. Sanitize observed HTTPS origin/path (strip userinfo/query/fragment); URL relevance never grants another origin. Record a normal-profile manager revision and revalidate page/profile/field/access after every await and before retrieval/delivery. Username change invalidates selected identity, while verified same-tab/same-origin step navigation may retain it within the original deadline.
- [ ] Keep legacy password storage/settings/autofill untouched and active by default. Add explicit selection between legacy and the new manager following existing settings patterns; switching changes only the selected provider, never either data store. Ensure exactly one password autofill writer is active. Keep card/contact storage and flows unchanged. Preserve explicit third-party extension/provider behavior rather than silently suppressing WSurf.
- [ ] Run GREEN with `SUITE=CredentialAccountSelectionTests`, `PasswordAutofillScriptTests`, `AutofillContactTests`, `ContactAutofillScriptTests`, `PaymentCardTests`, `PaymentCardScriptTests`, and every affected existing save suite.
- [ ] Smoke WebKit **and** Chromium: first save, update one of ten accounts, username-first login, OTP next step, changed username and hidden/mis-origin field.
- [ ] Review the new-manager selection/context flows and update Autofill README/changelog after proof; no legacy path deletion or migration.
- [ ] Commit `feat(autofill): Use profile accounts for password and TOTP`.

### Task 9: Establish trusted WebAuthn context and correct RP policy

**Files:** Create `WebAuthnContext.swift`, `RelyingPartyPolicy.swift`, bundled `public_suffix_list.dat`, `WebAuthnContextTests.swift`; modify `BrowserPage.swift`, `BrowserFrame.swift`, `ChromiumDevTools.swift`, `ChromiumPage.swift` and lifecycle delegates where required.

**Interfaces:** Consumes native `BrowserPage.profileID/isPrivate/isClosed`, actual frame security origin, engine document identity and lifecycle. Produces `@MainActor BrowserPage.credentialContext(for frame: BrowserFrame, operation: WebAuthnOperation) async throws -> WebAuthnContext` and `validateCredentialContext(_ context: WebAuthnContext) async throws`; `WebAuthnOperation` is `.create` / `.get`. Context contains native page/profile/frame/document-generation identity, canonical origin/topOrigin, crossOrigin and verified effective policy, not JS-authorized values. Produces `RelyingPartyPolicy.validate(rpID: String?, origin: URL) throws -> String`.

- [ ] **RED:** `rpRulesUseRealSuffixes` covers exact host, valid parent, unrelated host, bare public suffix, PSL wildcard/exception/private suffix, IDNA and nondefault port. `forgedOriginAndPolicyCannotAuthorize` rejects JS-supplied claims, opaque/insecure origins and private pages. `frameNavigationRetiresContext` replaces only a child document and asserts the old context is invalid despite unchanged top URL. `unknownIframePolicyFailsClosed` checks unknown/denied policy; verified permitted iframe cases succeed only with actual top/frame evidence.

  ```swift
  #expect(try RelyingPartyPolicy.validate(rpID: "example.com", origin: URL(string: "https://login.example.com:8443")!) == "example.com")
  #expect(throws: (any Error).self) {
      try RelyingPartyPolicy.validate(rpID: "com", origin: URL(string: "https://login.example.com")!)
  }
  #expect(throws: (any Error).self) {
      try RelyingPartyPolicy.validate(rpID: "attacker.example", origin: URL(string: "https://login.example.com")!)
  }
  ```

- [ ] Run RED with `SUITE=WebAuthnContextTests`, parameterized over WebKit/Chromium where engine state is involved.
- [ ] Bundle the Mozilla list from `https://publicsuffix.org/list/public_suffix_list.dat`, preserve its license/source/snapshot date, and implement exact/wildcard/exception matching including private suffixes and IDNA normalization of list entries. Enforce WebAuthn origin/RP rules, including secure localhost for the controlled loopback fixture; do not treat a local fixture as permission for an unrelated/public-suffix RP. Do not reuse `SiteName.domain` or add a network updater; mark the bundled-list refresh ceiling with `ponytail:`.
- [ ] Bind WebKit captured `WKFrameInfo` to a native-issued document nonce validated in an isolated world and retire it on navigation/handshake replacement; JS/page-world document IDs are not authority. Retain Chromium loader/context IDs and native frame liveness. Add a page-scoped monotonic generation and lifecycle invalidation point without overwriting existing tab callbacks.
- [ ] Query Chromium `Page.getPermissionsPolicyState` for the captured live frame/document and the specific public-key feature. For WebKit main documents, record actual final response headers through `WKNavigationResponse.response`, then enforce `Permissions-Policy` for that native navigation generation; combine available engine-native policy evidence, never request JSON. If effective iframe policy cannot be established, reject that iframe explicitly, even same-origin. Missing/unverifiable main-document policy evidence also fails closed. Revalidate context after asynchronous native confirmation and before completion; the gate must prove the chosen main-document path works on both engines.
- [ ] Run GREEN with `SUITE=WebAuthnContextTests`.
- [ ] Smoke both-engine fixture attempts at forged origin, invalid RP and detached/navigated frame.
- [ ] Review the context/policy result.
- [ ] Commit `feat(webauthn): Verify native context and relying party`.

### Task 10: Implement ES256 ceremonies and genuine UP/UV

**Files:** Create `WebsiteAuthenticator.swift`, `WebAuthnEncoding.swift`, `WebsiteAuthenticatorTests.swift`, `Helpers/WebAuthnVerifier.swift`; reuse Task 4's `PasskeyKeyEncoding.swift`.

**Interfaces:** Consumes Task 4 snapshots/commits and PKCS#8 key conversion, Task 5 manager and Task 9 context/RP validation. Produces Sendable `WebAuthnRequest` (`requestID: UUID`, typed creation/assertion options, monotonic deadline), `WebAuthnResult` (credentialID/clientDataJSON plus attestation/authenticatorData/signature/userHandle/extension results as appropriate), and `@MainActor WebsiteAuthenticator.perform(_ request: WebAuthnRequest, context: WebAuthnContext, manager: CredentialManager, in anchor: ASPresentationAnchor) async throws -> WebAuthnResult`. Its nonisolated cryptographic core exposes `makeRegistration(_ request: WebAuthnRequest, client: WebAuthnClientData, account: CredentialAccount, consent: WebAuthnConsent) throws -> WebsiteRegistration` and `makeAssertion(_ request: WebAuthnRequest, client: WebAuthnClientData, passkey: WebsitePasskey, consent: WebAuthnConsent) throws -> WebAuthnResult`. `WebAuthnClientData { origin: String, topOrigin: String?, crossOrigin: Bool, rpID: String }` carries canonical verified data; `WebAuthnConsent { requestID: UUID, userPresent: Bool, userVerified: Bool }` is native-only, request-bound and never derived from cached vault access. `WebsiteRegistration { result: WebAuthnResult, account: CredentialAccount }`. Tests exercise this core without OS prompts; the facade obtains real consent/fresh UV. Request decoding ceilings: 256 KiB total, challenge at most 1024 bytes (no invented 16-byte client minimum), user handle 1–64 bytes, at most 1,000 allow/exclude descriptors, each credential ID 1–1024 bytes; reject oversized input explicitly.

- [ ] **RED:** `independentVerifierAcceptsOnlyBoundCeremonies` validates COSE P-256 registration, RP hash, single-use challenge/client origin, attestation format `none`, DER ECDSA signature and zero counter, then rejects modified components. `allowExcludeAndUserHandleAreAuthoritative` checks IDs, account selection and discoverable assertions without using display usernames as identity. `requiredUVIsFresh` cannot set UV from cached vault authorization. `pkcs8PreservesKeyIdentity` round-trips a known external P-256 key and rejects RSA/Ed25519/wrong curve/truncated or contradictory DER before vault mutation.

  ```swift
  #expect(independentlyVerifiedSignature)
  #expect(!modifiedChallengeAccepted && !modifiedRPHashAccepted)
  #expect(assertionSignCount == 0)
  #expect(registeredCredentialID == assertedCredentialID)
  #expect(!uvAcceptedFromCachedVaultAccess)
  #expect(importedPublicKeyBytes == originalPublicKeyBytes)
  ```

- [ ] Run RED with `SUITE=WebsiteAuthenticatorTests`; independent verifier uses Security/OpenSSL and its own format decoding, not production encoders to manufacture expected values.
- [ ] Implement P-256 signing with CryptoKit, CBOR/COSE WebAuthn encoding, client data including actual top/cross-origin fields, software backup flags stored consistently, and correct challenge binding. Use `attestation: none`, no enterprise/hardware claims, and counter zero. Honor algorithm negotiation, `excludeCredentials`, `allowCredentials`, resident/discoverable credentials, user handle and explicit selected account. Duplicate exclusions return `InvalidStateError` before creating a key.
- [ ] Show native actual-domain/account confirmation for every completed ceremony. A new `LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)` must succeed for `userVerification: required`; never reuse the Keychain/card cache or prior unlock as UV. Only explicit current confirmation grants UP; canceled/failed verification returns no credential and cannot commit. Revalidate context/access after every await and before mutation/signature delivery.
- [ ] Reuse Task 4's validated PKCS#8 key conversion, without another DER parser. Support `credProps` truthfully; preserve imported supported FIDO2 HMAC/large-blob metadata for exchange without advertising website PRF/largeBlob support merely because bytes were preserved. Unknown required/unsupported security semantics fail explicitly.
- [ ] Run GREEN with `SUITE=WebsiteAuthenticatorTests` and the independent fixture verifier.
- [ ] Smoke native confirmation and fresh UV with server-accepted register/assert results.
- [ ] Review the authenticator result.
- [ ] Commit `feat(webauthn): Add profile ES256 authenticator`.

### Task 11: Install the complete WebAuthn API adapter on both engines

**Files:** Create `WebAuthnAdapter.swift`, `WebAuthnScript.swift`, `WebAuthnAdapterTests.swift`; modify `BrowserTab.swift` installation and common page lifecycle/context delivery points.

**Interfaces:** Consumes Tasks 5, 9, 10. Produces `@MainActor WebAuthnAdapter.install(in page: BrowserPage)`, `cancel(in page: BrowserPage)` and `cancel(profileID: UUID)`; common native request registry keys `(page identity, frame/document generation, requestID, profile access epoch)`. `WebAuthnScript.source: String` installs page-world public-key API wrappers at document start; privileged native context/operation handling remains isolated/native.

- [ ] **RED:** `publicKeyResultsMatchWebContract` invokes actual page APIs and asserts `PublicKeyCredential`-compatible identity/type/rawId, ArrayBuffers, response methods (`getPublicKey`, `getPublicKeyAlgorithm`, `getAuthenticatorData`, `getTransports`), `getClientExtensionResults` and JSON serialization rather than a plain JSON response. `nonPublicKeyStillUsesOriginalEngine` proves non-public-key calls remain unchanged. `abortNavigationAndLockRejectOnce` aborts before/after prompt, navigates/detaches frame, closes page, terminates process and changes profile; each promise settles once and no stale result is delivered. `conditionalDiscoveryDoesNotAuthenticateInBackground` checks no native signing/UV prompt before user selection.

  ```javascript
  assert(registration.type === "public-key");
  assert(registration.rawId instanceof ArrayBuffer);
  assert(registration.response.getPublicKeyAlgorithm() === -7);
  assert(registration.response.getAuthenticatorData() instanceof ArrayBuffer);
  assert(JSON.parse(JSON.stringify(registration)).id === registration.id);
  assert(abortedResult.name === "AbortError" && settledCount === 1);
  ```

- [ ] Run RED with `SUITE=WebAuthnAdapterTests` against real BrowserPage fixtures for both engines; repair fixture problems without suppressing the behavior.
- [ ] Implement bounded option marshalling preserving buffer slices, create/get promise lifecycle, request IDs, AbortSignal and finite timeout. Native code owns authorization and canonical context; page-world code only marshals request/results. Public-key errors map to appropriate DOMExceptions (`SecurityError`, `NotAllowedError`, `NotSupportedError`, `InvalidStateError`, `AbortError`) and **never** call the original Apple/engine public-key path afterward.
- [ ] Return proper browser-facing credential/response objects with byte buffers and helper methods, not test-only virtual-authenticator output. Advertise availability/capabilities from actual implemented behavior and native verification availability. Conditional get performs only discovery until explicit native account selection, then ordinary live-context/UP/UV checks; no background unlock, signing or authentication prompt. Do not advertise unsupported website extensions.
- [ ] Register cancellation for AbortSignal, timeout, page/frame navigation, close, engine replacement/process death, profile switch and manager lock. Retire request before delivery; check captured access and native context immediately before resolving. A committed registration canceled before delivery reports the committed mutation in native UI and rejects stale page delivery, rather than silently deleting or pretending it did not save.
- [ ] Run GREEN with `SUITE=WebAuthnAdapterTests`.
- [ ] Smoke real Air page APIs against the verifying server on both engines: conditional discovery, required UV, abort and wrong RP/frame.
- [ ] Review adapter behavior and update README/Autofill README/changelog after proof.
- [ ] Commit `feat(webauthn): Route both engines through native credentials`.

### Task 12: Implement lossless bounded Apple credential conversion and conflicts

**Files:** Create `CredentialExchangeCodec.swift`, `CredentialExchangeTests.swift`; use Task 4 key encoding and Task 6 TOTP.

**Interfaces:** Consumes `ASExportedCredentialData`, `CredentialAccount`, `VaultSnapshot` and key/TOTP validators. Produces `CredentialExchangeCodec.preview(_ data: ASExportedCredentialData, against: VaultSnapshot) throws -> CredentialImportPreview`; `apply(_ preview: CredentialImportPreview, decisions: [CredentialImportDecision]) throws -> [CredentialAccount]`; `export(_ snapshot: VaultSnapshot, selection: [CredentialExportSelection], format: ASExportedCredentialData.FormatVersion) throws -> ASExportedCredentialData`. `CredentialImportPreview` holds `base: VaultSnapshot`, `revision` computed from `base.revision`, bounded `candidates: [CredentialAccount]`, and `conflicts: [CredentialImportConflict]`. `CredentialIdentity` is `.password(accountID: UUID)`, `.passkey(accountID: UUID, passkeyID: UUID)`, or `.totp(accountID: UUID)`; `CredentialImportConflict` pairs `incoming`/`existing` identities. `CredentialImportDecision` is `.keep(incoming: CredentialIdentity)`, `.add(incoming: CredentialIdentity, targetAccountID: UUID?)`, or `.replace(incoming: CredentialIdentity, target: CredentialIdentity)`; it changes only that credential, preserving other kinds on its account. `CredentialExportSelection { accountID: UUID, password: Bool, passkeyIDs: Set<UUID>, totp: Bool }` selects exact subsets without fabricating password/TOTP UUIDs.

- [ ] **RED:** `allThreeSecretsRoundTripByUse` exports/reimports one linked password/passkey/TOTP account and asserts original credential ID/user handle/private-key signature, password and nondefault TOTP sequence/parameters. `conflictsDoNotOverwriteDomainNeighbours` keeps nine unaffected same-origin accounts and rejects duplicate/ambiguous IDs without decisions. `invalidImportIsAllOrNothing` rejects oversized records, malformed scopes, non-ES256/invalid PKCS#8, invalid TOTP and unknown unusable types without changing prior accounts. `extensionMetadataIsNeverSilentlyDropped` preserves supported 26.4+ FIDO2 metadata and rejects an unavailable/lossy path.

  ```swift
  #expect(receivedPassword == originalPassword)
  #expect(receivedPasskey.credentialID == originalPasskey.credentialID)
  #expect(receivedPasskey.userHandle == originalPasskey.userHandle)
  #expect(importedKeyVerifiedServerChallenge)
  #expect(receivedGenerator.period == 45 && receivedGenerator.digits == 10)
  #expect(receivedPasskey.exchangeFIDO2Metadata == originalPasskey.exchangeFIDO2Metadata)
  #expect(neighbourSecretsAfterImport == neighbourSecretsBeforeImport)
  ```

- [ ] Run RED with `SUITE=CredentialExchangeTests` (codec cases).
- [ ] Implement password, passkey and TOTP variants within a single Apple item/account association. Preserve original external account/item/credential identifiers and canonical user handles/RP ID; preserve supported FIDO2 metadata via availability-guarded Apple value encoding inside the encrypted payload. Reject unknown security-relevant or unsupported data with record-specific nonsecret errors; never downgrade a passkey or export current OTP codes.
- [ ] Validate bounded counts and sizes before constructing/encoding duplicate native data, and final payload size before vault commit. Do not infer an allowed origin from issuer/display domain; valid passkeys use RP scope, while password/TOTP contextual autofill requires explicit approved HTTPS origins. Preview lost/unsupported scope and make manual association explicit. Export includes selected account credential subsets and excludes every vault-unlock credential/wrapper.
- [ ] Run GREEN with `SUITE=CredentialExchangeTests`.
- [ ] Smoke independent key use and the nondefault TOTP sequence, not just model equality.
- [ ] Review the conversion/conflict result.
- [ ] Commit `feat(credentials): Convert Apple exchange records losslessly`.

### Task 13: Complete native system-token import and selected-record export

**Files:** Create `CredentialExchangeCoordinator.swift` and the capability-only `WSurfCredentialExchange` extension target (`CredentialExchangeProvider.swift`, `Info.plist`, sandbox-only entitlements); modify `AppDelegate.swift` (`application(_:continue:restorationHandler:)`), `AppCoordinator.swift` (`receiveCredentialExchange`, cold-start drain), `WSurf/Info.plist` (`NSUserActivityTypes`), `project.pbxproj` (extension target + embed), `CredentialSettings.swift` / `CredentialSettingsModel.swift`; add `CredentialExchangeCoordinatorTests.swift`; extend `CredentialExchangeTests.swift` (codec decisions) and `CredentialSettingsTests.swift` (clipboard clock). Bundle/appex metadata is checked once by a throwaway built-artifact smoke, not a permanent test; real cold/warm delivery stays a native gate.

**Interfaces:** Consumes Tasks 5, 7, 12; Task 3's real Apple Passwords participation is a late acceptance gate, not a prerequisite for codec/coordinator implementation. Import is split so each step is testable without the OS chooser: `@MainActor CredentialExchangeCoordinator.receive(_ activity: NSUserActivity) -> Bool` queues only the token; `claimImport(token:for:)` binds it to one manager and its authorization epoch (a locked manager leaves it queued); `beginImport(token:into:)` claims, calls `ASCredentialImportManager.importCredentials(token:)` once, then `stage(_:into:)` previews the payload against the vault without writing; `importReview` / `choose(_:for:)` / `mergeTargets(for:)` expose and decide per-record choices (`CredentialImportChoice`: skip, replace, add separately, merge into a named account whose websites the review states in full — conflicts must be decided, every other record imports automatically unless a choice is made); `commitImport(into:) async throws -> VaultCommitReceipt` applies the decisions through the codec in one revision-checked vault commit; `cancelImport()` drops the claim and staged data. Each operation is bound to a generation, so a superseded or cancelled one can neither consume nor clear its successor. `exportCredentials(selection:expectedRevision:epoch:from:in:) async throws -> CredentialExportOutcome` (`prepareExport` re-reads and revalidates the selection). `CredentialExportOutcome` distinguishes `.transferred` / `.cancelled`; errors throw and success never implies destination acceptance/synchronization. Receive validates activity type/token and queues only token metadata until explicit profile/unlock/record decisions.

- [ ] **RED:** `tokenProfileAndRevisionStayBound` rejects duplicate/mismatched tokens, changed target profile, revoked access and stale import-preview revision without mutation. `cancelBeforeCommitPreservesVaultAfterCommitReportsReceipt` covers both commit sides. `exportDoesNotDeleteOrClaimRecipientAcceptance` verifies source records remain unchanged and only selected associated credentials are transferred. Expired/system-rejected token and authentication/unsupported-data errors expose no secret diagnostics.

  ```swift
  #expect(bytesAfterCancelledImport == originalDiskBytes)
  #expect(committedReceipt.revision == preview.revision + 1)
  #expect(sourcePasswordAfterExport == sourcePasswordBeforeExport)
  #expect(sourcePasskeyAfterExport.credentialID == sourcePasskeyBeforeExport.credentialID)
  #expect(unselectedCredentialIdentities.isDisjoint(with: transferredCredentialIdentities))
  ```

- [ ] Run RED with `SUITE=CredentialExchangeCoordinatorTests` and `SUITE=CredentialExchangeTests` (coordinator state/commit cases and codec decisions); exercise local state and real vault transitions, not manager-call echo mocks.
- [ ] Handle cold-launch and running-app activity dispatch; ask target profile before fetching secret data, then explicit unlock and import/conflict review. Call `importCredentials(token:)` once for the exact pending token. Keep received secrets in memory under the captured access epoch (lock, re-unlock or cancel drops them); no plaintext staging file or all-profile search. Apply accepted decisions through one revision-checked atomic vault commit and return its receipt even if UI cancellation arrives after it.
- [ ] Export only explicitly selected account credential types. Call `requestExport(for:)` on a presentation-anchored manager and use its actual negotiated format and OS destination/risk UI; then fetch/revalidate selected secrets, profile/access and `expectedRevision`, rejecting a changed selection revision before `exportCredentials`. Never bypass interactive provider approval, add an Apple inventory/readback path, delete source records, or label transfer as automatic sync. Clear in-memory transfer data on completion/lock/profile change.
- [ ] Review rules the tests pin with real codec/vault data: a merge carries the imported item's metadata (same item refreshes it; a plain account adopts its identifiers and metadata) or is not offered; a passkey whose credential ID is already stored offers only skip/replace; a username-only login is selectable and exports without a password; the export sheet states that the destination can read the transfer and that TOTP means generator setup, not the current code. In-flight cancellation tests park the real vault read through a test-only clock gate and a directory watcher rather than polling or sleeping.
- [ ] Settings rules the tests pin with real coordinator/codec/vault data: a queued token can be dismissed (locked or unlocked) and stays spent without touching a review under way; a claimed import that ends (failure, cancel, stale, lock) says the credentials must be sent again from the other app, while a still-queued token or open review keeps the plain retry wording; the review shows each record's destination and effective websites from the commit's own decisions (new account = exporter websites, stored account = its own websites with the exporter's extra websites named as not added, passkey = its relying party) and the target profile; once `exportCredentials(data)` has started, every error or cancellation is the explicit uncertain outcome (never "cancelled"), success claims only that the system accepted the hand-off, and either result is kept as a neutral status until dismissed. Real Apple cancellation behaviour after hand-off stays a late acceptance item.
- [ ] Run GREEN with `SUITE=CredentialExchangeCoordinatorTests` and `SUITE=CredentialExchangeTests`.
- [ ] Smoke all six Apple Passwords transfers through finished settings/import UI with exact interactive approvals; verify login, server-accepted passkey and matching TOTP generator, plus cancellation/expiry/wrong-profile preservation.
- [ ] Review native transfer result and update README/changelog/release docs after proof.
- [ ] Commit `feat(credentials): Complete user-mediated Apple exchange`.

### Task 14: Accept the complete native feature and remove probe-only code

**Files:** All affected callsites/tests/docs; remove temporary `CredentialIntegrationProbe.swift`, `CredentialWebAuthnProbe.swift` and their `StageRun.swift` entry only after corresponding native smoke proof. Keep the controlled verifier fixture and permanent behavioral tests.

**Interfaces:** Consumes the full plan; produces a reviewed branch plus native/server evidence for every required outcome. No partial release or replacement of the installed app is authorized by this task.

- [ ] Run all new suites and affected existing card/contact/autofill/profile/page suites on Pro, then full suite/format/performance gates once after integration under explicit director verification assignment. Capture full logs and exact failures; do not claim clean results without evidence.
- [ ] Build the whole signed Debug app and extension on Pro from the assigned feature worktree; stage separately on Air and verify signatures. No production app/data access.
- [ ] Exercise settings/unlock/account UI and controlled HTTPS login on both engines: first save, update one of ten accounts, ambiguous/case-distinct usernames, username-first password/TOTP navigation, time refresh/copy/fill, private refusal, profile switch, lock, sleep/wake, expiry, wrapper removal, restart. Preserve legacy settings/data and verify switching only changes selected writer.
- [ ] Exercise actual public-key create/get, truthful feature detection/conditional behavior, fresh UV, server verification, invalid RP, abort/stale frame/page/process/profile cancellation on both engines. Complete all six Apple Passwords transfer cells with secret-use proof and no false sync claim.
- [ ] Remove only probe-only entry/code after native smoke proof. Confirm new-manager security boundaries; explicitly preserve all legacy password storage/settings/autofill paths and records. Update final docs and capability/signing/PSL-refresh instructions.
- [ ] Obtain a fresh whole-branch security/correctness review and address findings with director-assigned verification.
- [ ] Commit only after the explicitly assigned verification phase; report exercised evidence and exact blockers. Any failed native gate remains incomplete; do not claim full feature delivery.

## Parent self-review and handoff

Author self-review: spec sections 1–2 map to Tasks 1/4/5, password/TOTP to 6–8, website passkeys to 2/9–11, exchange to 3/12/13, and all permanent/native acceptance criteria to the owning tests and Task 14. The review corrected dependencies, encrypted save policy, post-await OTP timing, actor-local expiry checks, authenticated wrapper-set integrity, verified remaining unlock paths, per-credential transfer decisions and production-app routing; all five Review Focus cases have named tests. This plan contains interface/fixture/assertion decisions rather than implementation bodies.

The original plan approval and execution-method choice were recorded on 2026-10-06. The binding 2026-10-09 direction and later explicit gate assignments supersede conflicting plan workflow/cutover statements. Vault commit/lock, engine-origin trust, and transfer fidelity remain security contracts; signed Apple gates remain unproved and require exact point-of-risk approval.
