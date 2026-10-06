# Per-Profile Credential Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement WSurf-owned per-profile passwords, website passkeys, and TOTP for both browser engines, with external PRF-only vault unlocking and verified three-type, two-direction Apple Passwords exchange.

**Architecture:** One encrypted vault per normal profile serves settings, password/TOTP autofill, and the native WebAuthn authenticator. Reuse `BrowserPage`, native suggestion/save UI, and the existing account-step tracker; engine adapters provide trusted context and transport, never credential ownership. AuthenticationServices handles external unlock ceremonies and user-mediated exchange, not website-credential fallback.

**Tech Stack:** Swift 6 / Swift Testing, SwiftUI / AppKit, Foundation, Synchronization, CryptoKit, LocalAuthentication, AuthenticationServices, WebKit, existing CefSwift; a Python-stdlib HTTPS fixture with an independent OpenSSL verifier.

**Spec:** `docs/superpowers/specs/2026-10-05-profile-credential-manager-design.md`

**Status:** Approved on 2026-10-06 for Subagent-driven execution. Consequential external actions still require exact interactive approval at their point of risk.

**Source baseline:** `origin/main` at `9606f9d4d14669798049f32c37aa8f8beab7e2c8`, fetched on 2026-10-06. Continue on `feat/profile-credentials-20261006` in `/Users/klukacin/projects/wsurf/.worktrees/profile-credentials-20261006`; do not restart from the old private source snapshots.

## Global Constraints

- Independent vault, encryption key, and lock state for each normal profile.
- At most 1,000 account items and 4,000,000 decrypted payload bytes per profile. Validate bounded input before decoding or mutating storage.
- Generate a random 256-bit data-encryption key for each vault. Encrypt the account payload with CryptoKit AES-GCM. Use a fresh nonce on each write and bind the format version and profile/vault identity as authenticated data.
- Keep the existing five-minute authentication/context ceiling; webpage activity does not silently prolong authorization.
- Use the controlled `wsurf.app` relying party for app-native unlock ceremonies. Associated Domains must contain `webcredentials:wsurf.app`; verify the actual signed application identifier against AASA's `5X68L55TNU.io.wsagency.wsurf`.
- There is no recovery key, master password, or operating-system Keychain fallback for the new vault. Losing every external unlock passkey permanently loses access to the encrypted vault.
- Start with empty vaults. Do not build migration, legacy recovery, or migration/cutover UI.
- Private pages do not read or write a normal profile's saved credentials or create a persistent private vault. Every request uses the originating page's native profile ID.
- Do not maintain a plaintext index of vault usernames, URLs, passwords, or TOTP secrets. Preserve payment-card, contact, assistant API-key, and MCP credential storage.
- Numeric TOTP generators support 6 through 10 digits and positive periods representable by UInt16. Defaults are 6 digits and a 30-second period; support SHA-1, SHA-256, and SHA-512 with a 64-bit Unix-time counter.
- Generate and import ES256/P-256 website credentials. Reject unsupported algorithms before mutation; use no hardware/enterprise attestation claim and a zero signature counter for transferable software credentials.
- `userVerification: required` needs fresh successful native user verification, not merely a previously unlocked vault. No secret key or TOTP seed reaches JavaScript.
- Register an exchange extension with `SupportsCredentialExchange = YES` and `SupportedCredentialExchangeVersions = ["1.0"]`. FIDO2 extension exchange fields require macOS 26.4 or later.
- No silent Apple website-credential fallback, automatic bidirectional synchronization, CSV substitute, cloud-vault sync, or new cryptography dependency.
- Native builds/tests run on Pro with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; preserve its established project and builds. App target currently supports macOS 26.0; do not raise its floor to avoid availability handling.
- Stage mode is DEBUG-only. Copy a separate Debug app to the Air, set `WSURF_STAGE=1` and an owned `WSURF_STAGE_HOME`, and never use a Release launch or production browsing data as an isolated smoke run.
- Confirm exact external credential creation/transfer, signing-portal changes, publication, permission grants, and sensitive-data access at the point of risk. Provider safety approval remains interactive; use owned test credentials only.
- Every source/documentation edit, commit, build and test uses this task's linked feature worktree; native source work on Pro requires its own linked feature worktree, not an owned source snapshot.
- Follow current main's PR/release policy: local Debug validation is allowed on the feature branch; release/signed-preview publication requires a reviewed PR-merged main commit and successful CI.

## Review Focus

1. A profile switch or lock races the last disk-write/delivery boundary: a pre-commit operation cannot mutate a revoked profile, while a completed write must be reported as committed. Tasks 4, 5, 11, and 13.
2. Two accounts share a display username or differ only in username case: neither a password update nor a second login step may silently choose the other account. Tasks 7 and 8.
3. An imported TOTP has no approved website origin, crosses a time step, or uses 10 digits: manual display works, contextual fill stays blocked without association, and freshly computed digits remain intact. Tasks 6, 8, and 12.
4. A child frame navigates while its top page stays unchanged, or submits a forged policy/origin: neither engine may deliver a result to the replacement document. Tasks 9 and 11.
5. An exported/imported passkey carries optional FIDO2 state or an unsupported key algorithm: preserve supported state and key identity, reject lossy/unsupported transfer before mutation, and never describe API success as Apple acceptance. Tasks 3, 10, 12, and 13.

---

## Scope, dependency graph, and gates

This is one coordinated plan: all three credential types share account identity, vault authorization, native request validity, and exchange. Separate independent product plans would duplicate those contracts. Tasks 1–3 are independently reviewable integration gates; Tasks 4–8 deliver the manager, Tasks 9–11 its website authenticator, and Tasks 12–13 exchange. Task 14 accepts the whole feature, not a reduced password-only release.

Dependency order: `1 → 4 → 5`; `4 → 6`; `5 + 6 → 7 → 8`; `2 → 9`; `4 + 5 + 9 → 10`; `5 + 8 + 10 → 11`; `2.fixture → 3`; `3 + 4 + 6 + 10 → 12`; `5 + 7 + 12 → 13`; all preceding tasks feed 14. Tasks 1 and 2 are independent; Task 3 needs Task 2's verifier fixture, not a successful browser transport gate. One owner edits project signing/activity registration. Tasks 6 and 9 can proceed independently after their prerequisites. Never parallelize shared-file mutations without an integration owner.

**Gate evidence:** Record OS/build/signing identity, exact owned fixture, observable result, and blocker without secrets. Existing static SDK availability, configured entitlements, certificate names, or generic API success do not satisfy a gate. If PRF fails, stop dependent vault work; if verified transport/context fails, stop dependent website-authenticator work; if Apple Passwords lacks one requested direction/type, stop dependent Apple exchange work and report the exact missing prerequisite. Reachable independent work may continue, but the overall feature remains incomplete. Do not substitute CSV or another provider.

## File responsibilities

Paths marked **new** are deliberate additions, not existing helpers. Source/test directories are synchronized by the Xcode project; only the new extension needs an explicit new target.

| Files | Responsibility / owning task |
|---|---|
| `WSurf/Stage/CredentialIntegrationProbe.swift`, `CredentialWebAuthnProbe.swift` **temporary**, `WSurf/Stage/StageRun.swift` | Explicit Debug-only native gate UI and ephemeral PRF/WebAuthn/exchange assertions; Tasks 1–3. Remove both probes and their entry after final smoke proof. |
| `Tools/CredentialFixture/server.py` **new** | Owned HTTPS login/WebAuthn fixture, independent registration/assertion verification with OpenSSL, deterministic account/TOTP fixtures; Tasks 2–3, 14. No production service. |
| `WSurf/WSurf.entitlements`, `WSurf/Info.plist`, `WSurf.xcodeproj/project.pbxproj`, `WSurf.xcodeproj/xcshareddata/xcschemes/WSurf.xcscheme`, `WSurf/App/AppDelegate.swift` | Signed Associated Domains, embedded exchange extension, activity dispatch, termination locking; Tasks 1, 3, 5, 13. |
| `WSurfCredentialExchange/Info.plist`, `WSurfCredentialExchange/WSurfCredentialExchange.entitlements`, `WSurfCredentialExchange/CredentialExchangeProvider.swift` **new** | Capability-only credential-provider extension `io.wsagency.wsurf.CredentialExchange`; exchange eligibility, not general AutoFill or a second credential store; Task 3. |
| `WSurf/Web/Credentials/CredentialAccount.swift` **new** | Bounded account/passkey/TOTP value types, encrypted account metadata and exchange identifiers, canonical HTTPS login scopes; Task 4. |
| `WSurf/Web/Credentials/CredentialVault.swift`, `CredentialVaultCrypto.swift` **new** | Per-profile actor, bounded encrypted file, authenticated wrappers, atomic mutations, revocable authorization and commit receipts; Task 4. |
| `WSurf/Web/Credentials/PasskeyKeyEncoding.swift` **new** | Strict P-256 PKCS#8 validation before vault mutation, reused by authenticator/exchange; Task 4. |
| `WSurf/Web/Credentials/PasskeyVaultUnlocker.swift`, `CredentialManager.swift` **new** | Native PRF requests/cancellation, observable profile state and security-event invalidation; Task 5. |
| `WSurf/Web/Credentials/TOTP.swift` **new** | Validated setup, RFC 6238 calculation and lifetime; Task 6. |
| `WSurf/Settings/Pages/CredentialSettings.swift`, `WSurf/Web/Credentials/CredentialSettingsModel.swift` **new** | Replace password-only settings/model; account editor, unlock management, secret display/copy and exchange controls; Tasks 7, 13. |
| `WSurf/Settings/Pages/AutofillSettings.swift`, `WSurf/Settings/BrowserSettings.swift`, `WSurf/Extensions/ExtensionManager.swift`, `WSurf/App/AppCoordinator.swift` | Settings entry and explicit provider policy; remove obsolete password-extension arbitration, retain unrelated extension behavior; Tasks 7–8. |
| `WSurf/Web/Autofill/PasswordAutofill.swift`, `PasswordAutofillScript.swift`, `AutofillFormScript.swift`, `AutofillSuggestionScript.swift`, `AutofillSaveScript.swift` | Existing shared transport/classification plus password and OTP field operations; Task 8. Keep password adapter name rather than churn its callers. |
| `WSurf/Web/Autofill/AutofillSuggestions.swift`, `AutofillSaveCoordinator.swift`, `AutofillSubmissionTracker.swift`, `AutofillSaveCandidate.swift`, `AutofillSuggestion.swift`, `AutofillSaveIndex.swift`, `SecureAutofillVault.swift` | Account-aware native selection, save/update, one login context, clean password-storage/index cutover; Task 8. Shared card/contact code remains. |
| `WSurf/UI/Content/AutofillSuggestionList.swift`, `AutofillSavePopover.swift`, `AutofillSaveReview.swift`, `WSurf/Settings/Pages/AutofillSavePromptReset.swift` | Existing native picker/review and per-kind prompt reset; Task 8. |
| `WSurf/Profiles/Profile.swift`, `WSurf/App/AppCoordinator+Profiles.swift`, `WSurf/Web/Model/BrowserModel+Switching.swift` | Profile invalidation/removal and adoption; Tasks 5, 8. |
| `WSurf/Web/Engines/BrowserPage.swift`, `BrowserFrame.swift`, `ChromiumDevTools.swift`, `ChromiumPage.swift`, `WSurf/Web/Tabs/BrowserTab.swift`, `BrowserTab+WebKitDelegates.swift`, `BrowserTab+PageLifecycle.swift` | Native document/frame generation, lifecycle cancellation, engine policy evidence and adapter installation; Tasks 9, 11. |
| `WSurf/Web/Credentials/WebAuthnContext.swift`, `RelyingPartyPolicy.swift`, `public_suffix_list.dat` **new** | Verified request context and licensed bundled Mozilla PSL; Task 9. Do not use `SiteName`'s display heuristic. |
| `WSurf/Web/Credentials/WebsiteAuthenticator.swift`, `WebAuthnEncoding.swift` **new** | ES256 ceremonies, UP/UV and WebAuthn encoding; Task 10. |
| `WSurf/Web/Credentials/WebAuthnAdapter.swift`, `WebAuthnScript.swift` **new** | Common native request registry and document-start public-key API adapter; Task 11. |
| `WSurf/Web/Credentials/CredentialExchangeCodec.swift`, `CredentialExchangeCoordinator.swift` **new** | Lossless bounded Apple records, import conflicts, system-token/export UI flow; Tasks 12–13. |
| `WSurfTests/Web/CredentialVaultTests.swift`, `CredentialLifecycleTests.swift`, `TOTPTests.swift`, `CredentialSettingsTests.swift`, `CredentialAccountSelectionTests.swift`, `WebAuthnContextTests.swift`, `WebsiteAuthenticatorTests.swift`, `WebAuthnAdapterTests.swift`, `CredentialExchangeTests.swift` **new** | Permanent consumer-visible boundaries and transitions; Tasks 4–13. |
| `WSurfTests/Helpers/WebAuthnVerifier.swift` **new**, existing `HTTPFixtureServer.swift`, `TestClock.swift`, `WebKitMessages.swift` | Independent Security-framework verification and existing deterministic engine/clock fixtures; Tasks 9–11. No real Apple account access in the ordinary test suite. |
| Existing `WSurfTests/Web/SecureAutofillVaultTests.swift`, `PasswordAutofillScriptTests.swift`, card/contact/save tests | Replace obsolete password contracts, preserve shared storage fixture and unaffected behavior; Tasks 7–8. |
| `WSurf/Web/Autofill/SavedPassword.swift`, `PasswordSettingsModel.swift`, `WSurf/Settings/Pages/PasswordSettings.swift` | Delete once consumers cut over; move still-needed password generation/origin behavior to the new account/settings code, not aliases; Tasks 7–8. |
| `WSurf/Web/Autofill/README.md`, `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `RELEASING.md` | Update actual manager behavior and signed verification/release procedure after smoke proof in the owning tasks. |

## Execution and verification conventions

Before execution, read both documents and the current `AGENTS.md`, load the selected execution skill and `using-git-worktrees`, and reuse this task's local branch/worktree. Sync its resolved sources into the dedicated Pro branch `feature/profile-credentials-main-refresh-20261006` at `/Users/klukacin/projects/wsurf/.worktrees/profile-credentials-main-refresh-20261006`, not Pro's main checkout or another task's worktree. Set `PRO_WORKTREE` to that path and `PRO_DERIVED_DATA` to `$PRO_WORKTREE/.build/DD`; clone the owned dependency cache into `$PRO_WORKTREE/.build/SourcePackages` without changing its original. `CEF_PACKAGE` is `$PRO_WORKTREE/.build/SourcePackages/checkouts/CefSwift`, pinned at `59cad64e124b8efdb6b2ee811963097bb6e689e8`, and is used by `Tools/embed-chromium.sh`. Record separate owned `AIR_STAGE_APP` and `STAGE_HOME` values for the actual smoke run.

Before changing/removing an exported symbol, query LSP references and migrate every caller; use repository pattern checks only for non-symbol strings or when no language server is available. Follow Main Actor isolation by default; mark pure Sendable value/crypto types `nonisolated` and keep AppKit/browser objects on Main Actor. Assertion snippets below pin outcomes on the owned fixtures named in the same task; they are tests, not additional production interfaces.

Every RED/GREEN suite step below means run this concrete command with `SUITE` set to the named Swift Testing suite; sync the changed feature files to the Pro worktree before running it and verify its branch/path:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes pro \
  "cd '$PRO_WORKTREE' && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer WSURF_CEF_PACKAGE='$CEF_PACKAGE' xcodebuild test -project WSurf.xcodeproj -scheme WSurf -destination 'platform=macOS,arch=arm64' -derivedDataPath '$PRO_DERIVED_DATA' -clonedSourcePackagesDirPath '$PRO_WORKTREE/.build/SourcePackages' -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation -skipPackagePluginValidation -only-testing:WSurfTests/$SUITE CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="
```

A missing symbol may establish initial RED; subsequent RED must show the named incorrect behavior, not a missing import or broken fixture. GREEN is the selected suite with zero failures/skips; inspect the generated result bundle under the owned derived-data `Logs/Test` directory, not a truncated console summary. Tests use existing Swift Testing conventions, `.boundedWebViews` for live WebKit views and existing exclusive-access traits for shared process state; inject time, not sleeps. Unit tests never open a real Keychain vault or prompt Apple Passwords.

Native gate/smoke builds use the same project/scheme, **Debug**, and owned paths, but retain real app/extension entitlements and provisioned signing. The ad-hoc test command above does not prove Apple integrations. Inspect signed entitlements and embedded provisioning before launching; verify `codesign --verify --deep --strict` on Pro and Air. Launch the copied stage executable with `WSURF_STAGE=1 WSURF_STAGE_HOME="$STAGE_HOME"`; leave the installed app untouched. A locked Air desktop is a human-unlock prerequisite, not permission to bypass login.

For the prepared Task 1/2 gates, also launch with `WSURF_CREDENTIAL_PROBE=1 WSURF_CREDENTIAL_FIXTURE_ORIGIN=https://localhost:57443`; the first flag exposes the explicit credential-probe menu, and the second matches the still-running memory-only fixture's exact origin. These flags expose the UI, not authorization to create/assert/transfer external credentials or bypass provider approval. Leave the probe flag unset for an ordinary main-integration smoke.

Signed native build command (per-target app/extension provisioning is established in Tasks 1 and 3; do not apply the app's profile to every target):

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes pro \
  "cd '$PRO_WORKTREE' && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer WSURF_CEF_PACKAGE='$CEF_PACKAGE' xcodebuild build -project WSurf.xcodeproj -scheme WSurf -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath '$PRO_DERIVED_DATA' -clonedSourcePackagesDirPath '$PRO_WORKTREE/.build/SourcePackages' -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation -skipPackagePluginValidation"
```

StageRun reseeds browsing tabs at launch; restart proof must compare persisted account/credential IDs and successfully use their secrets in the same owned stage home, not infer persistence from seeded tabs. Before an OS transfer fetch, verify the launched recipient's PID/app path/stage home. A token routed to the installed/production app must not be fetched; stop and correct routing with explicit approval for any registration change.

The HTTPS fixture starts with `python3 Tools/CredentialFixture/server.py --port 57443 --cert CERT --key KEY`; it binds only `127.0.0.1` and keeps credential/challenge state in memory, with no `--host` or `--state` option. Preserve its running process for fixture identity continuity. Use `https://localhost:57443`, an explicit fixture-only trust decision in the owned stage, and no global Keychain trust changes or production TLS bypass. Its initial self-check command is `python3 Tools/CredentialFixture/server.py --self-check`; success is exit 0 after independent valid registration/assertion and deliberately invalid challenge/signature cases. Keep private fixture data out of logs and commits.

Before each task's commit, review its observable result and exact diff, and update user-facing docs only after its real smoke path works. Commit only the task's listed files with a Conventional Commit subject. Never stage the repository wholesale. A fresh reviewer gate is per task in subagent-driven execution; native execution still self-reviews each task and obtains a fresh whole-branch review before delivery. No build/lint/tests/formatters run inside delegated mid-flight slices; the integration owner runs each completed task's RED/GREEN gates.

### Current execution checkpoint

- Checkpoint `36652ce` preserves the prepared PRF/WebAuthn probes, fixture and signing declarations; it accepts no credential integration gate. Reuse them instead of repeating source preparation.
- Task 1 still needs a valid authorized Mac App Development profile for `io.wsagency.wsurf` and genuine signed external-PRF/restart evidence. Do not repeat the unchanged failed signing build, enable provisioning updates, or remove restricted entitlements to bypass this gate.
- Task 2's independent fixture and scoped-HTTPS component checks passed before the main refresh; native WebKit/Chromium credential ceremonies remain unproved. Preserve the running owned fixture and its test identities. An ad-hoc main-integration build/smoke is not PRF, WebAuthn or Apple Passwords acceptance.
- Main-integration verification on 2026-10-06: the whole ad-hoc Debug app builds on Pro; the focused native result bundle records 129 passed tests, zero failures, and one skipped installed-Codex-CLI check across thirteen suites. Deep/strict signature verification passes on Pro and on the separate Air stage copy. The owned stage launches and persists its sample session, but Air's current loginwindow blocks visual/interactive UI acceptance. This is not signed credential-gate evidence.
- Next native gate work resumes after the signing prerequisite and exact interactive credential/provider approvals. Keep the fourteen-task dependency order and all six Apple Passwords transfer cells; no narrower password-only scope or fallback.

### Task 1: Prove signed external PRF-only unlocking

**Files:** Reuse prepared temporary `WSurf/Stage/CredentialIntegrationProbe.swift` and the `StageRun.swift` entry, `WSurf.entitlements` and signing settings in `project.pbxproj`; complete their native proof and update `RELEASING.md` after proof.

**Interfaces:** Consumes `ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "wsurf.app")`, native registration/assertion requests and `ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues(saltInput1:saltInput2:)`. Produces a gate record with PRF stability, independent credential IDs, AES-GCM wrap/unlock success and cancellation outcomes; no persistent PRF output or DEK.

- [ ] **RED:** Add an executable native probe assertion: two assertions for one credential and stable PRF input recover the same ephemeral 256-bit key; a wrong output cannot decrypt it; two registrations with different random user IDs leave both external credentials usable. Missing PRF output must result in `unsupportedPRF`, not a substitute key.

  ```swift
  precondition(firstRecoveredDEK == originalDEKBytes)
  precondition(secondRecoveredDEK == originalDEKBytes)
  precondition(firstCredentialID != secondCredentialID)
  precondition(wrongPRFWasRejected && missingPRFWasRejected)
  ```

- [ ] Run the approved signed Debug stage before implementation; record the absent Associated Domains/ceremony failure as RED, without trying production credentials.
- [ ] Implement the explicit probe UI and `webcredentials:wsurf.app`; generate a fresh 32-byte challenge per ceremony, a stable random 32-byte PRF input per credential, and a different random user ID per registration. Use native AuthenticationServices, retain controller/delegate for completion, and cancel pending ceremonies on probe dismissal.
- [ ] Confirm the exact test credential registrations interactively; inspect the actual signed identifier/provisioning and deployed AASA, then run assertions on the Air. GREEN requires both independent credentials and a verified PRF wrapping/unwrapping round trip after restart; keep only encrypted/public discovery fixture data if restart needs it.
- [ ] Review gate evidence. Stop Task 4 if unsupported/missing PRF or association/signing fails; do not add recovery or any-RP Apple browser access.
- [ ] Commit `test(credentials): Prove signed PRF unlock prerequisites`.

### Task 2: Prove the WebAuthn bridge on both engines with a real verifier

**Files:** Reuse `Tools/CredentialFixture/server.py`, temporary `WSurf/Stage/CredentialWebAuthnProbe.swift` and its `CredentialIntegrationProbe` foreground entry; use existing `BrowserPage`/engine script APIs without changing production credential ownership.

**Interfaces:** Consumes `BrowserPage.installScript(_:in:injectionTime:forMainFrameOnly:)`, `addScriptMessageHandler(name:in:handler:)`, `callAsyncJavaScript(_:arguments:in:contentWorld:)`, and native `BrowserScriptMessage.page/frameInfo`. Produces server-accepted ephemeral ES256 registration/assertion evidence for **WebKit and Chromium**, plus transport/context limitations feeding Task 9.

- [ ] **RED:** Fixture self-check asserts valid ES256 registration/assertion succeeds, changed challenge/origin/RP hash/signature fails, and excluded IDs cannot register again. The browser fixture asserts document-start interception, byte-exact buffers, cancellation, and unchanged non-public-key behavior; without the owned adapter, those calls cannot reach its native handler.

  ```python
  assert accepted_registration and accepted_assertion
  assert not accepted_changed_challenge
  assert not accepted_changed_origin
  assert not accepted_changed_rp_hash
  assert not accepted_changed_signature
  ```

- [ ] Run `python3 Tools/CredentialFixture/server.py --self-check` and the unmodified page APIs in both owned stage engines; record RED separately from TLS/CEF setup errors.
- [ ] Implement the stdlib HTTPS fixture with single-use challenges and an OpenSSL verification path independent of native credential code. Add a foreground-only ephemeral probe authenticator with native consent and fresh LocalAuthentication for UV-required requests; return real client/authenticator/attestation data, not a CDP virtual authenticator or echo response.
- [ ] Run actual `navigator.credentials.create/get` on both engines; require server acceptance and actual response/helper behavior. Test abort, navigation, hidden/replaced frame, invalid RP and `userVerification: required`; no result may go to a stale document. Record whether native policy evidence is available; unknown iframe policy must reject, not use page-supplied booleans.
- [ ] Review the two-engine evidence. Stop dependent website-authenticator work if a secure native-context/transport prerequisite cannot be satisfied.
- [ ] Commit `test(credentials): Prove native WebAuthn transport`.

### Task 3: Prove Apple Passwords participation for all six transfers

**Files:** Create `WSurfCredentialExchange/{Info.plist,WSurfCredentialExchange.entitlements,CredentialExchangeProvider.swift}`; modify project/scheme, containing `Info.plist`/`AppDelegate.swift`, and the temporary probe. Update `RELEASING.md` after proof.

**Interfaces:** Consumes `ASCredentialImportManager.importCredentials(token: UUID) async throws -> ASExportedCredentialData`, `ASCredentialExportManager.requestExport(for: String?) async throws -> ExportOptions`, and `exportCredentials(_:) async throws`. Produces a six-cell evidence matrix: password/passkey/TOTP × WSurf→Apple Passwords / Apple Passwords→WSurf, each verified by use.

- [ ] **RED:** Prepare three owned fixture records: a password accepted by the controlled login, a P-256 PKCS#8 passkey accepted by the verifying server, and an RFC 6238 seed with known parameters. Assert no transfer is accepted as complete merely because an API returned or the recipient item count changed.

  ```swift
  // Evaluate separately for each of the two actual transfer directions.
  precondition(passwordLoginAccepted)
  precondition(passkeyServerAccepted)
  precondition(totpSequenceAndParametersMatch)
  ```

- [ ] Launch the signed stage and inspect the real system destination/source flow before registration changes; record missing exchange eligibility/participation as RED, not as consent to bypass it.
- [ ] Embed/provision extension bundle `io.wsagency.wsurf.CredentialExchange`, extension point `com.apple.authentication-services-credential-provider-ui`, and the capability keys from Global Constraints. Do not advertise general password/passkey/OTP AutoFill services. Use an `ASCredentialProviderViewController` principal class and an accessible configuration view explaining that exchange is managed in WSurf; no second vault, shared-secret file, or app-group data channel is needed.
- [ ] Register the containing app using the SDK value of `ASCredentialExchangeActivityType` and retrieve the UUID at `ASCredentialImportToken`; do not assume a documentation symbol spelling is its runtime string value. Probe secrets stay ephemeral/in the owned encrypted fixture, never plaintext files. Confirm each exact external creation/transfer interactively, then exercise all six cells with Apple Passwords and validate the received password, server signature and matching TOTP sequence/parameters.
- [ ] Review actual recipient participation, cancellation and token errors. If any cell is unavailable, report OS/app/direction/type and stop dependent exchange work; the generic manager wrapper is not this deliverable.
- [ ] Commit `test(credentials): Verify Apple Passwords exchange participation`.

### Task 4: Implement bounded accounts and the atomic encrypted vault

**Files:** Create `CredentialAccount.swift`, `CredentialVaultCrypto.swift`, `CredentialVault.swift`, `PasskeyKeyEncoding.swift` under `WSurf/Web/Credentials/`; create `WSurfTests/Web/CredentialVaultTests.swift`.

**Interfaces:** Produces the following native-only types and methods; later tasks consume these exact names.

- `CredentialAccount: Codable, Sendable, Identifiable`: `id: UUID`, `username: String`, `displayName: String?`, `origins: [String]`, `loginURLs: [URL]`, `password: String?`, `passkeys: [WebsitePasskey]`, `totp: TOTPGenerator?`, `exchangeAccountID: Data?`, and `exchangeItemID: Data?`. Origins are canonical HTTPS strings; login URLs retain origin/path only.
- `WebsitePasskey: Codable, Sendable, Identifiable`: internal `id: UUID`, `credentialID: Data`, `rpID: String`, `userHandle: Data`, `userName: String`, `userDisplayName: String`, `algorithm: Int`, `privateKeyPKCS8: Data`, `backupEligible: Bool`, `backupState: Bool`, `exchangeFIDO2Metadata: Data?`. `algorithm == -7`; new transferable credentials have `backupEligible = true`, `backupState = false`, not an inferred cloud-sync claim.
- `TOTPGenerator: Codable, Sendable`: `secret: Data`, `algorithm: TOTPAlgorithm` (`sha1`, `sha256`, `sha512`), `period: UInt16`, `digits: UInt16`, `issuer: String?`, `userName: String?`.
- Account validators: `CredentialAccount.validate() throws`, `CredentialAccount.origin(for url: URL) -> String?`, `CredentialAccount.sanitizedLoginURL(_ url: URL) throws -> URL`, and `TOTPGenerator.validate() throws`. Produce `PasskeyKeyEncoding.importPKCS8(_ data: Data) throws -> P256.Signing.PrivateKey` and `exportPKCS8(_ key: P256.Signing.PrivateKey) throws -> Data`; every stored/imported passkey is validated as usable P-256, not merely tagged `-7`.
- `VaultUnlockProof` is a non-Codable ephemeral value containing `credentialID: Data`, `prfInput: Data`, `prf: SymmetricKey`, used after registration or verification of an existing unlock path. `VaultAccess(profileID: UUID, epoch: UInt64, deadline: ContinuousClock.Instant)` is a revocable Sendable permit; `revoke()` is synchronous. The actor associates an access object with its DEK only after a successful create/unlock; merely constructing a permit grants no access.
- `VaultSnapshot { revision: UInt64, accounts: [CredentialAccount], blockedPasswordOrigins: Set<String> }`; `VaultCommitReceipt { revision: UInt64 }`; `VaultUnlock { credentialID: Data, prfInput: Data }`; `VaultDiscovery { vaultID: UUID, unlocks: [VaultUnlock] }`. `CredentialVault(profileID: UUID, directory: URL, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) throws` is an actor and rejects the private profile.
- Actor methods: `discovery() throws -> VaultDiscovery`; `create(unlock: VaultUnlockProof, access: VaultAccess) throws`; `unlock(credentialID: Data, prf: SymmetricKey, access: VaultAccess) throws`; `snapshot(using: VaultAccess) throws -> VaultSnapshot`; `commit(_ accounts: [CredentialAccount], expectedRevision: UInt64, using: VaultAccess) throws -> VaultCommitReceipt`; `updatePasswordSavePolicy(_ blockedOrigins: Set<String>, expectedRevision: UInt64, using: VaultAccess) throws -> VaultCommitReceipt`; `addUnlock(_ proof: VaultUnlockProof, using: VaultAccess) throws -> VaultCommitReceipt`; `removeUnlock(credentialID: Data, verifiedRemaining: VaultUnlockProof, using: VaultAccess) throws -> VaultCommitReceipt`; `lock()`; `erase() throws`. Read the clock **inside** the actor at each access/commit boundary, never trust an instant captured before an actor hop.

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
- [ ] Implement shared record validation and strict bounded PKCS#8 `PrivateKeyInfo` parsing/encoding for id-ecPublicKey + prime256v1. Check embedded public key/curve against the private scalar; CryptoKit's EC DER must not be assumed to be PKCS#8. Reuse the gate's independent OpenSSL key-use fixture. TOTP record validation checks nonempty bounded secret, algorithm, digits 6–10 and positive UInt16 period; setup parsing/calculation remains Task 6.
- [ ] Implement AES-GCM fresh nonces; payload AAD is length-delimited `(format, profileID, vaultID, manifestDigest)`, where `manifestDigest` is SHA-256 of canonical public unlock records, including wrapper nonces/ciphertext. Wrapper AAD binds `(format, profileID, vaultID, credentialID, prfInput)`. HKDF-SHA-256 uses domain label `WSurf vault wrapping v1` plus profile/vault binding. Verify new/remaining wrappers recover the current DEK before adding/removing paths; any wrapper-set change reseals the payload under its new manifest digest. Atomic `Data.write(options: .atomic)` replaces manifest+payload together; validate IDs/scopes/revision/access before replacement. Retain no PRF/wrapping key after use.
- [ ] Make access expiry/revocation and the final synchronous commit boundary linearizable with `Synchronization.Mutex`; hold no lock across `await`. Revocation before the boundary rejects, revocation after a completed boundary returns its commit receipt. Use concrete state/stdlib, not a storage-provider abstraction; filesystem failure tests use owned temporary directories. Add a `ponytail:` comment for the bounded whole-file rewrite and 32-wrapper ceiling.
- [ ] Run GREEN with `SUITE=CredentialVaultTests`.
- [ ] Smoke an owned file: create, restart/unlock, add/remove a wrapper, mutate and recover old state after a failed write.
- [ ] Review the vault result and update storage/security docs after proof.
- [ ] Commit `feat(credentials): Add atomic profile vault`.

### Task 5: Add native unlock management and unconditional lifecycle locking

**Files:** Create `PasskeyVaultUnlocker.swift`, `CredentialManager.swift`; modify `AppDelegate.swift`, `AppCoordinator+Profiles.swift`, `BrowserModel+Switching.swift`, `Profiles/Profile.swift`; create `CredentialLifecycleTests.swift`. Reuse proven native request code from Task 1 rather than retain two implementations.

**Interfaces:** Consumes Task 4. Produces `@MainActor @Observable CredentialManager`, `static forProfile(_ profile: Profile) throws -> CredentialManager`, `isUnlocked: Bool`, `unlockCredentials: [VaultUnlock]`, `unlock(in anchor: ASPresentationAnchor) async throws`, `create(in anchor: ASPresentationAnchor) async throws`, `addUnlock(in anchor: ASPresentationAnchor) async throws`, `removeUnlock(credentialID: Data, in anchor: ASPresentationAnchor) async throws -> VaultCommitReceipt`, `lock(reason: CredentialLockReason)`, `snapshot() async throws -> VaultSnapshot`, `commit(_ accounts: [CredentialAccount], expectedRevision: UInt64) async throws -> VaultCommitReceipt`, and `updatePasswordSavePolicy(_ blockedOrigins: Set<String>, expectedRevision: UInt64) async throws -> VaultCommitReceipt`. `CredentialLockReason` cases: manual/profileSwitch/screenLock/sleep/termination/timeout. `PasskeyVaultUnlocker.register(in anchor: ASPresentationAnchor) async throws -> VaultUnlockProof`, `assert(credentialID: Data, prfInput: Data, in anchor: ASPresentationAnchor) async throws -> SymmetricKey`, and `cancel()` own AuthenticationServices ceremony lifetime.

- [ ] **RED:** `lateUnlockCannotReopenRevokedProfile` revokes a pending access epoch before its PRF result and asserts no unlocked state/file write. `authorizationExpiresAtFiveMinutes` accepts 299 seconds, rejects 300, and repeated webpage activity does not extend the deadline. `securityEventsRevokeAccess` checks each named reason clears account/code UI and rejects subsequent snapshot/commit; `profilesAndPrivatePagesStayIsolated` checks a second profile and private page cannot use the first access.

  ```swift
  #expect(!manager.isUnlocked)
  #expect(bytesAfterLateUnlock == originalDiskBytes)
  #expect(accessWorksAt299Seconds)
  #expect(!accessWorksAt300Seconds)
  #expect(!otherProfileCanRead && !privatePageCanRead)
  ```

- [ ] Run RED with `SUITE=CredentialLifecycleTests`; use revocable epochs and injected instants, not mocked Apple-response forwarding.
- [ ] Implement profile-scoped registry/observable state and native PRF-only requests. Create the revocable pending access **before** a ceremony; lock synchronously revokes pending/current access, cancels native requests and notifies credential adapters, then releases actor-held key references. Check the captured epoch after every `await`; never create a new epoch to rescue a canceled callback.
- [ ] Before wrapper removal, obtain a fresh native assertion for a different remaining credential, construct its `VaultUnlockProof`, and have the actor verify it unwraps the current DEK. An unavailable/corrupt remaining path rejects removal unchanged. Keep profile/access checks across the ceremony; no external credential is deleted.
- [ ] Add concrete initializer `CredentialManager(profile: Profile, directory: URL, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) throws`; `forProfile` uses the profile support directory. Tests use owned files and a mutex-backed instant source. The internal `beginAccess() -> VaultAccess` / `completeUnlock(credentialID: Data, prf: SymmetricKey, access: VaultAccess) async throws` transition is shared by the real native completion and lifecycle tests, not a fake provider protocol.
- [ ] Install security observers independently of settings visibility: screen lock, sleep/session resignation and termination, plus profile switch/removal and a monotonic five-minute timer. Remove managers before erasing profiles. Keep card/contact LA sessions unchanged. Expose actionable unsupported-PRF and permanent-loss/last-wrapper-removal warnings; removal does not delete the external credential or claim historical-backup revocation.
- [ ] Run GREEN with `SUITE=CredentialLifecycleTests`.
- [ ] Smoke the real stage: create/unlock, independent second wrapper, manual lock, profile switch, sleep/wake, timeout and restart; displayed metadata disappears and pending operations cannot finish.
- [ ] Review the lifecycle result and update docs after proof. Release Swift key/secret references; do not promise physical RAM erasure.
- [ ] Commit `feat(credentials): Manage PRF unlock and lock lifecycle`.

### Task 6: Implement validated TOTP setup and fresh generation

**Files:** Create `WSurf/Web/Credentials/TOTP.swift`, `WSurfTests/Web/TOTPTests.swift`.

**Interfaces:** Consumes `TOTPGenerator` / `TOTPAlgorithm` and `TOTPGenerator.validate()`. Produces `TOTP.parse(_ input: String, algorithm: TOTPAlgorithm = .sha1, period: UInt16 = 30, digits: UInt16 = 6) throws -> TOTPGenerator` and `TOTP.code(_ generator: TOTPGenerator, at unixTime: TimeInterval) throws -> TOTPCode`; `TOTPCode { value: String, remainingSeconds: TimeInterval, expiresAt: TimeInterval }`. Parsing a URI preserves its explicit supported parameters rather than overriding them with manual defaults.

- [ ] **RED:** `rfc6238Vectors` pins the published eight-digit SHA-1/256/512 results at 59, 1111111109, 1111111111, 1234567890, 2000000000, and 20000000000. `numericBoundaries` checks leading zeros, 6/10 digits, periods 1/30/65535, and times just before/at a step. `malformedSetupIsRejected` checks bad/empty Base32, duplicate/contradictory URI parameters, `otpauth://hotp`, vendor schemes, numeric login-code input, period 0/65536, digits 5/11, nonfinite/negative/out-of-UInt64-counter-range time, and unknown algorithm.

  ```swift
  // RFC seeds are the reference implementation's 20/32/64-byte ASCII seeds.
  #expect(try TOTP.code(rfcSHA1, at: 59).value == "94287082")
  #expect(try TOTP.code(rfcSHA256, at: 59).value == "46119246")
  #expect(try TOTP.code(rfcSHA512, at: 59).value == "90693936")
  #expect(try TOTP.code(rfcSHA1, at: 1_111_111_109).value == "07081804")
  #expect(try TOTP.code(rfcSHA512, at: 20_000_000_000).value == "47863826")
  ```

- [ ] Run RED with `SUITE=TOTPTests`.
- [ ] Implement strict bounded raw-secret/Base32 and `otpauth://totp` parsing; preserve issuer/source username, reject decimal-only login-code input and unsupported parameters without normalization. Reuse `TOTPGenerator.validate()` for parsed/imported generators. Use CryptoKit `HMAC<Insecure.SHA1>`, `HMAC<SHA256>`, `HMAC<SHA512>`, unsigned 64-bit big-endian counters and `UInt64` decimal modulus so 10 digits cannot overflow/truncate.
- [ ] Run GREEN with `SUITE=TOTPTests` and the independent fixture's seed check.
- [ ] Smoke generation across a real copy-time boundary, not from a cached code.
- [ ] Review the TOTP result.
- [ ] Commit `feat(credentials): Add RFC 6238 TOTP`.

### Task 7: Replace password settings with the complete account manager

**Files:** Create `CredentialSettingsModel.swift` / `CredentialSettings.swift`; modify `AutofillSettings.swift`; remove `PasswordSettingsModel.swift` / `PasswordSettings.swift`; create `CredentialSettingsTests.swift`; update password-generation consumers/tests in `SecureAutofillVaultTests.swift`. Move the existing generator into the editor/model without leaving a compatibility alias.

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
- [ ] Implement existing settings primitives and observable/revision guards: vault creation/unlock/lock, account add/edit/delete, password generation/reveal/copy, explicit origin associations and sanitized login URLs, TOTP setup/code/lifetime, passkey metadata/removal, and add/remove unlock controls. TOTP timers exist only while unlocked; clear UI at lock. Invalid forms must not mutate the vault. Preserve US-English/localizable copy, keyboard access and VoiceOver labels.
- [ ] Run GREEN with `SUITE=CredentialSettingsTests`.
- [ ] Smoke the real stage UI: ten accounts, edit just one, standalone records, explicit cross-origin association, TOTP setup/copy and lock.
- [ ] Review, remove old settings/model consumers without aliases, and update README/changelog after proof.
- [ ] Commit `feat(credentials): Replace password settings with account manager`.

### Task 8: Cut password save/autofill over and retain selected account through TOTP

**Files:** Modify existing autofill scripts/controllers/enums/index and native picker/review files listed in File responsibilities; modify `BrowserSettings.swift`, `ExtensionManager.swift`, `AppCoordinator.swift`, profile adoption/erasure callers; delete `SavedPassword.swift` and password-only factory/cache paths; create `CredentialAccountSelectionTests.swift`; update `SecureAutofillVaultTests.swift` / `PasswordAutofillScriptTests.swift` and affected shared tests.

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
- [ ] Remove `AutofillVaults.passwords`, old password LA cache, password entries/reads in `AutofillSaveIndex`, and all `SavedPassword` consumers; no migration/read fallback. Keep `SecureAutofillVault<AutofillContact>`, card vault and card/contact index/block/reset behavior. Route password prompt block/reset through `VaultSnapshot.blockedPasswordOrigins` and `updatePasswordSavePolicy`, preserving policy on account commits. Remove `passwordExtensionID` auto-provider selection and its init/reset/supplier callers; keep the explicit `fillsPasswords` switch. Explain that third-party extension management is separate and never silently disables WSurf.
- [ ] Run GREEN with `SUITE=CredentialAccountSelectionTests`, `PasswordAutofillScriptTests`, `AutofillContactTests`, `ContactAutofillScriptTests`, `PaymentCardTests`, `PaymentCardScriptTests`, and every affected existing save suite.
- [ ] Smoke WebKit **and** Chromium: first save, update one of ten accounts, username-first login, OTP next step, changed username and hidden/mis-origin field.
- [ ] Review LSP/reference inventory and remove obsolete incidental implementation/copy tests, retaining `MemoryAutofillStorage` used by contact tests; update Autofill README/changelog after proof.
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

**Files:** Create `CredentialExchangeCoordinator.swift`; modify `AppDelegate.swift`, `CredentialSettings.swift` / `CredentialSettingsModel.swift`; extend `CredentialExchangeTests.swift`.

**Interfaces:** Consumes Tasks 3, 5, 7, 12. Produces `@MainActor CredentialExchangeCoordinator.receive(_ activity: NSUserActivity) -> Bool`, `importCredentials(token: UUID, into manager: CredentialManager, in anchor: ASPresentationAnchor) async throws -> VaultCommitReceipt`, `exportCredentials(selection: [CredentialExportSelection], expectedRevision: UInt64, from manager: CredentialManager, in anchor: ASPresentationAnchor) async throws -> CredentialExportOutcome`. `CredentialExportOutcome` distinguishes `.transferred` / `.cancelled`; errors throw and success never implies destination acceptance/synchronization. Receive validates activity type/token and queues only token metadata until explicit profile/unlock/record decisions.

- [ ] **RED:** `tokenProfileAndRevisionStayBound` rejects duplicate/mismatched tokens, changed target profile, revoked access and stale import-preview revision without mutation. `cancelBeforeCommitPreservesVaultAfterCommitReportsReceipt` covers both commit sides. `exportDoesNotDeleteOrClaimRecipientAcceptance` verifies source records remain unchanged and only selected associated credentials are transferred. Expired/system-rejected token and authentication/unsupported-data errors expose no secret diagnostics.

  ```swift
  #expect(bytesAfterCancelledImport == originalDiskBytes)
  #expect(committedReceipt.revision == preview.revision + 1)
  #expect(sourcePasswordAfterExport == sourcePasswordBeforeExport)
  #expect(sourcePasskeyAfterExport.credentialID == sourcePasskeyBeforeExport.credentialID)
  #expect(unselectedCredentialIdentities.isDisjoint(with: transferredCredentialIdentities))
  ```

- [ ] Run RED with `SUITE=CredentialExchangeTests` (coordinator state/commit cases); exercise local state and real vault transitions, not manager-call echo mocks.
- [ ] Handle cold-launch and running-app activity dispatch; ask target profile before fetching secret data, then explicit unlock and import/conflict review. Call `importCredentials(token:)` once for the exact pending token. Keep received secrets in memory under the captured access epoch; no plaintext staging file or all-profile search. Apply accepted decisions through one revision-checked atomic vault commit and return its receipt even if UI cancellation arrives after it.
- [ ] Export only explicitly selected account credential types. Call `requestExport(for:)` on a presentation-anchored manager and use its actual negotiated format and OS destination/risk UI; then fetch/revalidate selected secrets, profile/access and `expectedRevision`, rejecting a changed selection revision before `exportCredentials`. Never bypass interactive provider approval, add an Apple inventory/readback path, delete source records, or label transfer as automatic sync. Clear in-memory transfer data on completion/lock/profile change.
- [ ] Run GREEN with `SUITE=CredentialExchangeTests`.
- [ ] Smoke all six Apple Passwords transfers through finished settings/import UI with exact interactive approvals; verify login, server-accepted passkey and matching TOTP generator, plus cancellation/expiry/wrong-profile preservation.
- [ ] Review native transfer result and update README/changelog/release docs after proof.
- [ ] Commit `feat(credentials): Complete user-mediated Apple exchange`.

### Task 14: Accept the complete native feature and remove probe-only code

**Files:** All affected callsites/tests/docs; remove temporary `CredentialIntegrationProbe.swift`, `CredentialWebAuthnProbe.swift` and their `StageRun.swift` entry after production paths have smoke evidence. Keep the controlled verifier fixture and permanent behavioral tests.

**Interfaces:** Consumes the full plan; produces a reviewed branch plus native/server evidence for every required outcome. No partial release or replacement of the installed app is authorized by this task.

- [ ] Run all new suites and affected existing card/contact/autofill/profile/page suites on Pro, then the full existing suite and project format/performance checks once after integration. Report the already-observed unrelated framework-fixture failures separately; do not claim a clean full suite or rerun just to reconfirm known failures. A newly broken affected consumer contract must be fixed, not skipped/re-pinned.
- [ ] Build the **whole** signed Debug app and embedded extension on Pro from this task's linked feature worktree, copy to a separate Air stage, and verify signing on both hosts. Component CryptoKit/CEF probes or Swift syntax checks are not whole-app evidence.
- [ ] Exercise real native settings/unlock/account UI and controlled HTTPS login in both engines: first save, update one of ten accounts, ambiguous/case-distinct usernames, username-first password/TOTP navigation, time-step refresh and copy/fill, private refusal, profile switch, manual/screen lock, sleep/wake, five-minute expiry, independent wrapper removal and restart. Record fresh screenshots/accessibility and field/server outcomes; never inspect production credentials.
- [ ] Exercise actual public-key create/get, supported feature detection/conditional behavior, fresh UV, server verification, invalid RP, abort/stale frame/page/process/profile cancellation on both engines. Repeat actual Apple Passwords password/passkey/TOTP transfers in both directions with secret-use proof and no false synchronization claim.
- [ ] Remove probe-only entry/code after smoke proof; update final docs and capability/signing/PSL-refresh instructions. Confirm no obsolete password store/index/extension-selection fallback callers or temporary plaintext fixtures remain; retain all shared card/contact paths. Check exported-symbol removals with LSP references and repository pattern checks, not compatibility aliases.
- [ ] Obtain a fresh whole-branch security/correctness review.
- [ ] Address findings and run the specifically affected verification.
- [ ] Commit `feat(credentials): Accept native profile credential manager`; report exercised evidence and exact blockers. Integration-gate failure leaves the corresponding required outcome incomplete; do not describe the overall feature as delivered.

## Parent self-review and handoff

Author self-review: spec sections 1–2 map to Tasks 1/4/5, password/TOTP to 6–8, website passkeys to 2/9–11, exchange to 3/12/13, and all permanent/native acceptance criteria to the owning tests and Task 14. The review corrected dependencies, encrypted save policy, post-await OTP timing, actor-local expiry checks, authenticated wrapper-set integrity, verified remaining unlock paths, per-credential transfer decisions and production-app routing; all five Review Focus cases have named tests. This plan contains interface/fixture/assertion decisions rather than implementation bodies.

Human review approved the full plan and selected **Subagent-driven** on 2026-10-06. Vault commit/lock, engine-origin trust and transfer fidelity remain independently reviewable security contracts whose mistakes can expose credentials or make the only vault copy unusable. Signed Apple gates remain unproved; approval is not an integration-success claim or permission to bypass provider safety prompts.
