# WSurf Per-Profile Credential Manager

Date: 2026-10-05

Status: Approved architectural design; this workstream's binding 2026-10-09 direction supersedes the historical PRF-first and legacy-cutover decisions below. Existing Keychain `SavedPassword`/`SecureAutofillVault`, password settings/autofill, and data remain unchanged and active by default. The new encrypted manager is developed alongside them, with no automatic migration/deletion/cutover. No native/provider success is implied.

## Intent and agreed scope

WSurf owns its password, website-passkey, and TOTP manager. Each normal browsing profile has its own encrypted vault. The manager lives in the app and behaves consistently with both WebKit and Chromium; switching engines does not change credential ownership or create another credential store.

The user's concrete multi-account case is approximately ten Gmail logins. The site/login URL and entered username identify the relevant account. The selected account can continue through separate username, password, and TOTP pages without filling a different account's secrets.

Apple has two distinct roles:

1. Externally held WSurf unlock passkeys supply PRF-derived keys for vault unlocking.
2. User-mediated exchange copies selected passwords, website passkeys, and TOTP generators between WSurf and Apple Passwords, if runtime verification establishes Apple Passwords participation in the exchange API. Apple synchronizes credentials held by its provider across the user's approved Apple devices.

The new encrypted vault is designed around the preferred Apple PRF input path, but its storage, crypto, validation, tests, and manager can be developed without proving platform PRF feasibility. Do not create fake production keys or a plaintext fallback. No recovery key, master password, or new Keychain fallback is added. Real Apple registration/unlock is a late, explicit interactive-approval gate; if unavailable, retain the protected encrypted store and report the blocker.

Existing password records and behavior remain intact. Do not migrate, delete, replace, or automatically read legacy records. The old manager remains the active default until the user explicitly selects the new manager; selection is mutually exclusive so only one autofill writer is active.

### Required outcomes

- Independent vault, encryption key, and lock state for each normal profile.
- Password saving, updating, editing, and contextual account selection.
- App-owned website-passkey registration and assertion on both engines.
- Local TOTP setup, generation, display, and contextual filling.
- Multiple external PRF-capable unlock passkeys per vault.
- Explicit import/export of all three credential types, including secrets rather than screenshots or current OTP codes.
- No silent Apple website-credential fallback or automatic bidirectional Apple synchronization.
- Real native and server-side verification before claiming an integration works.

### Non-goals

- Automatic migration, legacy recovery, or deletion/cutover of existing password records. Preserve existing legacy password manager as active default until explicit mutually exclusive selection.
- Changes to payment-card, contact, assistant API-key, or MCP credential storage.
- WSurf account servers, cloud-vault synchronization, recovery escrow, or a new cryptography dependency.
- General macOS AutoFill-provider functionality outside WSurf. An exchange extension does not replace the app-owned manager.
- CSV as a substitute for the requested password/passkey/TOTP exchange.

## Current code and reuse boundaries

`BrowserPage` already carries the engine, profile identity, native page lifecycle, script installation, frame messaging, and JavaScript execution for WebKit and Chromium. Reuse that boundary instead of creating two managers.

Existing password code stores `SavedPassword` records as per-profile Data Protection Keychain JSON. It does not implement a PRF-encrypted local vault, local website-passkey signing, TOTP, or credential exchange. `SavedPassword` currently retains origin, username, and password, but not login URLs or passkey/TOTP data.

Reuse the relevant behavior in:

- `WSurf/Web/Engines/BrowserPage.swift` and the existing engine adapters.
- `WSurf/Web/Autofill/PasswordAutofill.swift` and the shared form/suggestion scripts.
- `WSurf/Web/Autofill/AutofillSuggestions.swift` for native selection and live-document checks.
- `WSurf/Web/Autofill/AutofillSaveCoordinator.swift` for save/update offers and `UsernameStep`.
- Existing password settings and profile-switch/security-event handling.

The current password suggestion index exposes account metadata outside the password blob. Do not extend that legacy index with metadata from the new vault; the new manager must not maintain a plaintext index of vault usernames, URLs, passwords, or TOTP secrets. Keep the old password paths intact and preserve unrelated card/contact behavior.

An enabled third-party password extension currently suppresses WSurf's native password flow. The app-owned manager must not silently disappear because another installed extension is recognized. Provider arbitration must remain explicit and must not select Apple Passwords as the primary manager implicitly.

The current password vault bounds are 1,000 records and 4,000,000 encoded bytes. Retain bounded storage and unique identifiers in the new format: at most 1,000 account items and 4,000,000 decrypted payload bytes per profile. Validate bounded input before decoding or mutating storage.

## 1. Architecture and data ownership

A native per-profile vault owns the credential data and cryptographic operations. Password autofill, TOTP, settings, and WebAuthn use the same vault. An engine adapter supplies verified page/frame context and delivers only the result authorized for that request.

The shared logic must not depend on a concrete `WKWebView` or Chromium browser object. Engine-specific code implements script installation, message transport, native context/liveness checks, field filling, and result delivery through the existing page boundary.

### Account data

An account item has a stable internal identifier, username/display information, approved HTTPS origins, sanitized login URLs, and its associated credentials. It can hold a password, one or more website passkeys, and a TOTP generator without requiring all three. Standalone passkey and TOTP accounts are supported.

A password stores its secret under the account identity. Updating one account does not replace every password on the same domain.

A website passkey stores its credential ID, RP ID, user handle, display information, algorithm, private-key material, and required authenticator/extension state. RP ID and user handle remain authoritative for WebAuthn; a display username is not a replacement for them.

A TOTP generator stores raw secret bytes, hash algorithm, period, digits, issuer, and source username. Its account association controls contextual selection. An issuer name such as "Google" is not permission to fill a code on a domain.

Account metadata is encrypted with the credential secrets. Unlock discovery metadata is separate and described below.

### Profile and private-browsing rules

- Every request is bound to the originating page's native profile ID, not a profile ID supplied by JavaScript.
- Switching profiles invalidates the previous profile's unlocked state and pending credential operations.
- Requests never search all profiles or expose another profile's account list.
- Preserve the current private-browsing isolation: private pages do not read or write a normal profile's saved credentials or create a persistent private vault.

## 2. Encryption, unlock, and lifecycle

### Key hierarchy

Generate a random 256-bit data-encryption key for each vault. Encrypt the account payload with CryptoKit AES-GCM. Use a fresh nonce on each write and bind the format version and profile/vault identity as authenticated data.

Each external unlock credential has a stable, random PRF input and a separately encrypted copy of that vault's data-encryption key. Obtain its PRF output through a native AuthenticationServices assertion. Derive a wrapping key with HKDF-SHA-256, using a domain-separated context that binds the vault/profile identity. Bind the credential ID and PRF input to its authenticated key wrapper.

The assertion challenge is fresh for each ceremony; the PRF input remains stable for that credential/vault. Persist neither the PRF output nor the derived wrapping key. Release references after the operation. Do not promise complete physical RAM erasure by Swift object disposal.

Only discovery information needed before unlocking is outside the encrypted payload: format/profile/vault identifiers, unlock credential IDs, public PRF inputs, nonces, and authenticated encrypted key wrappers. Passwords, account usernames, login URLs, website private keys, and TOTP secrets are not part of that manifest.

### External unlock credentials

Use the controlled `wsurf.app` relying party for app-native unlock ceremonies. Unlock passkeys remain outside the vault they unlock. They are not ordinary website-passkey records and are not exported as part of a selected account.

Native passkey use requires the Associated Domains entitlement with `webcredentials:wsurf.app` and an AASA entry matching the actual signed application identifier. The deployed AASA currently lists `5X68L55TNU.io.wsagency.wsurf`; this must be verified against the chosen signing profile, not assumed from a certificate name.

Multiple unlock registrations need distinct user IDs: registering another passkey for the same RP and user ID can replace the previous Apple-held credential.
Keep the PRF input stable for each external credential. Repeating an assertion for the same credential and stable input must produce the same PRF output so the same wrapping key can be recovered; an incorrect output must fail authenticated unwrap. Missing output is an explicit `unsupportedPRF` failure, never a fallback. Multiple registrations use distinct random user IDs so adding a second does not replace the first; both credentials must remain independently usable, including after restart.

### Lifecycle and mutation

- Creating a vault requires a PRF-capable external unlock passkey and a verified wrapping/unwrapping round trip.
- Missing PRF output or unsupported PRF is an explicit failure, never a different key derivation or Keychain fallback.
- Adding an unlock credential requires an already unlocked vault and successful verification of the new wrapper before committing it.
- Removing an unlock wrapper must leave at least one valid unlock path. It does not delete the external Apple credential automatically.
- Removing a wrapper affects the current vault state only. It denies that wrapper's normal unlock of the current manifest, but the vault data key is unchanged (`CredentialVault.removeUnlock` re-seals the payload under the same key). A removed wrapper and its PRF output can still recover that key from any copy of the vault file that contains the wrapper, and with it decrypt later envelopes obtained from the same vault, not only an old backup. This is a stated boundary, not forward revocation: there is no key rotation, and no anti-rollback, power-loss durability or cross-process guarantee is claimed.
- Manual lock, profile switch, screen lock, sleep, exit, and authentication timeout invalidate credential access and pending operations. A late callback cannot reopen or mutate a different/currently locked profile.
- Keep the existing five-minute authentication/context ceiling; webpage activity does not silently prolong authorization.

Store the encrypted payload and manifest consistently with atomic replacement. Failed decoding, authentication, validation, or pre-commit writes preserve the previous valid state. A callback canceled after a successful commit must not pretend no mutation occurred.

## 3. Passwords, TOTP, and app-owned WebAuthn

### Password capture and contextual selection

On first use, offer to save the observed account and login context. Save/update requires the user's confirmation. A changed password updates the selected account, not a domain-wide slot.

Remember the login URL's HTTPS origin and path, excluding user information, query parameters, and fragments. Origin is a security boundary; URL/path is a relevance hint. Another origin must be explicitly associated with the account rather than inferred from a domain suffix or issuer name.

When the username field is empty, present the active profile's matching accounts in native WSurf UI. Partial input filters the visible list. An exact entered username narrows the candidate set; ambiguous matches require a choice. Do not globally lowercase or otherwise rewrite arbitrary usernames in a way that merges distinct accounts.

Filling starts from a native user selection. The selected account can continue through username, password, and TOTP steps in the same tab and origin for up to five minutes. Changing the entered username invalidates the old selection. Reuse `UsernameStep` where appropriate, extending the account context rather than creating a second login tracker.

Carry account identity, not a cached password or OTP code. Every new document and target field receives fresh native origin/profile/frame/liveness and visibility/focus checks before retrieving the secret.

### TOTP

Compute codes locally according to RFC 6238 using CryptoKit HMAC. Support SHA-1, SHA-256, and SHA-512; preserve imported periods and digit counts. Numeric generators support 6 through 10 digits and positive periods representable by the exchange API's UInt16. Default manual setup is 6 digits and a 30-second period. Invalid or unsupported parameters are reported before storage mutation, not normalized silently.

Support setup from a secret or `otpauth://totp` URI and from credential exchange. The entered secret is decoded and validated before saving. A six-digit login code cannot be used to reconstruct a generator. HOTP and nonnumeric vendor-specific code schemes are not TOTP inputs.

Show the current code and its remaining lifetime only while the relevant profile is unlocked. Copy/fill is an explicit native user action. Recompute at the moment of copy/fill and after wake; do not use a code cached from an earlier document or time step. Use current Unix time and a 64-bit time counter, including times beyond 2038.

A TOTP field receives the generator associated with the selected account. Lack of a verified origin association allows manual viewing in the manager but not contextual autofill. Locking clears the displayed code and access to its secret.

### Website-passkey path

Install an app-owned adapter for the public-key branches of `navigator.credentials.create()` and `get()` at document start on both engines. Non-public-key Credential Management operations retain their existing engine behavior. Public-key failures do not silently fall through to Apple website credentials.

The adapter sends request options to native WSurf code. It does not send private keys, decide authorization, or supply a trusted origin. The native request is tied to the actual page, profile, frame, document/navigation generation, and outstanding request ID.

Native WebAuthn handling must enforce:

- Secure context and correctly canonicalized native origin.
- RP ID rules, including public-suffix rejection and valid origin/RP relationships.
- Top/frame origin and effective Permissions Policy for iframe ceremonies; fail closed where those conditions cannot be verified.
- Allowed/excluded credential lists, user handle, selected account, and algorithm negotiation.
- Correct client data, authenticator data, challenge binding, registration result, and assertion signature.
- Actual user-presence and user-verification semantics; never invent UP/UV flags from a background request.
- Cancellation, AbortSignal, timeout, page close, navigation, engine/process termination, profile switch, and lock invalidation.
- Truthful feature-detection and conditional-mediation behavior. Conditional discovery does not prompt for or sign a credential in the background.

Native WSurf confirmation identifies the actual domain and selected account before registration or assertion. Generate and import ES256/P-256 website credentials in this design. A registration with no ES256 option and an imported non-ES256 private key produce an explicit unsupported result before mutation; do not accept an unusable key. Use no hardware/enterprise attestation claim and a zero signature counter for transferable software credentials. `userVerification: required` needs fresh successful native user verification, not merely a previously unlocked vault.

Returned objects must satisfy the WebAuthn response contract used by the page, including byte buffers and relevant response/helper methods. A test-only CDP virtual authenticator is not the production implementation.

Passwords and current OTP codes intentionally filled into a webpage can be read by that page. The page never receives a TOTP seed, website private key, PRF key, or vault key.

## 4. Credential exchange and failure behavior

### Apple API contract

- Register the credential-provider extension with `SupportsCredentialExchange = YES` and `SupportedCredentialExchangeVersions = ["1.0"]`; Task 3 and Global Constraints retain these exact keys. This configuration does not prove that Apple Passwords participates or that any transfer is eligible.

The containing app handles the import `NSUserActivity`; use the documented `ASCredentialExchangeActivityType` spelling in its `NSUserActivityTypes` registration, match runtime `activityType` using the SDK's `ASCredentialExchangeActivity` value, and read the UUID from `userInfo[ASCredentialImportToken]`. The documentation registration name and exported runtime symbol are not interchangeable; do not invent a different identifier or infer recipient eligibility from registration.

Embed the extension at `com.apple.authentication-services-credential-provider-ui` and use an `ASCredentialProviderViewController` principal class. Its accessible configuration view explains that exchange is managed in WSurf. This exchange-only extension does not advertise general password/passkey/OTP AutoFill services, create a second credential store, or use an app-group/shared-secret data channel. Route the system token only to the intended staged recipient after verifying that recipient's process, app path, and owned stage home; never fetch a token routed to the installed/production app.

A signing certificate signs the app; it is not a grant to read the entire Apple Passwords vault. The browser's managed public-key entitlement, the AutoFill-provider entitlement, Associated Domains, and credential-exchange registration are separate surfaces. Do not add a managed any-RP Apple-browser capability merely to implement app-owned website cryptography or own-RP unlock.

Import starts with a user-initiated export in the source app. WSurf receives the system token and asks for the target profile, unlock, and record/conflict confirmation before committing data. Do not stage plaintext credential files while waiting for unlock.

The system's import token is single use and is spent as soon as an import is claimed. A queued token can be dismissed from the settings page whether or not the vault is unlocked; dismissing spends it without touching an import already under review, and no queue replaces it automatically. Once a claimed import fails, is cancelled, goes stale or is discarded by a lock, the staged data is gone with the token, so the message says that the credentials must be sent again from the source app; "reload and try again" is used only while the token is still queued or a review is still open. Cancelling is bound to the profile's own manager: a closing or stale profile page can end only its own claim, review or running commit, never a successor's or another profile's, and a cancel while the commit runs claims nothing about whether the write landed.

The review is per credential, not per file. A record that matches a stored credential by the exporter's identifiers is a conflict and needs an explicit decision (skip, replace the stored one, add separately, or merge into a named account); every other record is added unless the user skips it or merges it. The review names the profile the credentials are imported into and, for every record, where it ends up and which websites it will work on, taken from the same decisions the commit applies: a new account works on exactly the websites the exporter approved for the item; a credential saved into a stored account (a merge, a replacement, or a refresh of the same exporter item) works on that account's own websites, listed in full, and the exporter's websites that the account does not already approve are listed as not added, never merged in. A passkey always keeps the website (relying-party ID) it was created for. A login or TOTP seed with no approved website is flagged as needing manual association. Nothing is written until the user confirms, and the confirmed decisions are applied in one revision-checked commit; a lock, re-unlock or cancel discards the staged data.

Export selects account credentials in WSurf and uses the out-of-process system destination/risk UI. An account can export its login (a password, or a username with or without one), website passkey, and TOTP generator setup together while preserving their association; the transfer carries the generator's secret and parameters, not today's code. The destination app can read what is sent, the transfer API does not write a credential file, and the vault keeps its own copy.

Export outcomes keep the phase they happened in. A cancel before the credential data is handed to the system (destination or format prompt, a changed vault or authorization, the caller's cancellation) is a clean cancel and the sheet stays open. Once the hand-off call has started, no failure or cancellation can claim that nothing was sent: any error, including a system cancellation code or task cancellation, is reported as an explicit uncertain outcome, and success means only that the system accepted the hand-off, never that the other app received or imported anything. Either result is shown as a neutral, secret-free status in settings (also while locked, and when it arrives after the user left the page) until dismissed. WSurf never retries or re-exports on its own, and the real Apple cancellation behaviour after hand-off remains an acceptance item.

A merge never discards the exporter's item name or metadata (tags, dates, collections, account name): the credential is merged only into the same exporter item, whose metadata is refreshed, or into an account that has no exchange identity of its own and no different name, which then takes the item's name, identifiers and metadata. An account that already stands for a different exporter item, or that the user has named differently, is not offered as a merge target. An item's identifiers belong to exactly one account: when its credentials are split across destinations, the first (or the stored account that already holds them) keeps the identifiers, and every other destination gets fresh identifiers with a remapped copy of the same name and metadata. The vault keeps passkey credential IDs unique, so a passkey whose credential ID is already stored can be skipped or replace the stored one, but is never added separately or merged, and is never silently re-keyed.

The API supports genuine passkey private keys in PKCS#8 representation and TOTP secret bytes with issuer, username, algorithm, period, and digits. Preserve identifiers, parameters, and supported extension metadata. FIDO2 extension exchange APIs require macOS 26.4 or later where relevant; do not claim PRF-extension preservation on an OS that lacks those fields.

### Named Apple Passwords prerequisite

Public Apple exchange documentation establishes transfer between participating credential-manager apps. It does not establish that Apple Passwords participates in every requested direction/type; its current import guide describes CSV passwords.

Before accepting Apple Passwords integration as implemented, demonstrate WSurf to Apple Passwords and Apple Passwords to WSurf transfer of a password, a usable passkey, and a TOTP generator on the target OS. Verify the received secrets by actual use. If the target app does not participate or rejects a type, report the exact blocker and stop that dependent work. Do not substitute CSV, export screenshots, or mark a generic exchange API wrapper as complete.

Apple synchronizes credentials it holds. The exchange API is not an inventory/readback channel, does not prove remote synchronization completeness, and does not provide automatic bidirectional WSurf updates. Changes in either manager require another explicit transfer. Synchronizing an unlock passkey does not synchronize WSurf's encrypted vault file.

### Conflicts and errors

Validate imported record types, identifiers, key encoding/algorithms, URL scopes, TOTP parameters, and payload limits before modifying the vault. Preview conflicts per account/credential; matching a domain alone is insufficient for overwriting a different password or seed. Do not infer a permitted website origin from a TOTP issuer string.

Cancellation, token mismatch/expiration, unsupported data, authentication failure, wrong-profile context, and lock/profile changes have explicit outcomes. Preserve the prior valid vault on failed operations and do not expose secrets in diagnostics. The export UI must distinguish API transfer success from unverified destination acceptance/synchronization. Do not delete source credentials automatically after export.

Import/export does not delete source credentials. Existing legacy password storage/index/settings stay unchanged; this workstream performs no migration, replacement, or cutover. Keep new-vault account metadata encrypted.

## 5. Development sequence and verification

Develop the new protected credential store and manager independently of Apple PRF feasibility. The preferred unlock integration is Apple PRF; implement its input/proof boundary without using fake production keys. Keep the encrypted vault protected even when the native provider is unavailable. Existing password settings/autofill remain active and unchanged by default; selecting the new manager is explicit and mutually exclusive, never a simultaneous autofill writer or silent cutover.

1. **Independent credential core:** bounded encrypted per-normal-profile storage, account types, TOTP, lifecycle, settings/editor, and contextual behavior; support passwords, website passkeys, and TOTP. Preserve legacy store/settings/autofill unchanged.
2. **Engine integration:** shared WebAuthn/authentication and contextual credential behaviors on WebKit and Chromium, after the relevant native context checks.
3. **Explicit manager selection:** use the existing settings patterns for one explicit choice between legacy password autofill and the new manager. Default remains legacy; no data migration, deletion, or simultaneous autofill. Define and test switching without rewriting either store.
4. **Late native gates and exchange:** integrate and verify actual Apple PRF unlock, both-engine native WebAuthn, and explicit Apple Passwords transfers of all three credential types in both directions. These require exact interactive approval. A crypto-vector or injected-PRF test is not Apple-provider proof. Any unavailable native prerequisite is reported without disabling the protected store or legacy behavior.

This is the architectural sequence, not permission to perform external actions. Preserve all security and acceptance outcomes. The native Apple registration/transfer flow remains a late exact-interactive-approval gate. No new recovery or master-password feature is in scope.

### Permanent behavioral checks

Use the existing Swift Testing conventions. Retain consumer-visible checks, not mock forwarding or source-text assertions:

- Wrong unlock key, wrong profile, modified ciphertext/header, missing PRF output, and invalid records fail without exposing or overwriting data.
- A second wrapper unlocks the same vault independently; adding/removing wrappers preserves valid access and removing the last is rejected.
- Lock/profile/navigation changes invalidate late callbacks and prevent credential delivery to stale documents.
- Ten-account fixtures select the intended username; changing it prevents the previous password or OTP from being filled. Context does not cross tabs, origins, or profiles.
- RFC 6238 vectors for all three hashes, leading zeros, time-step boundaries, nondefault periods/digits, post-2038 counters, and malformed setup/import data.
- WebAuthn signatures/challenges/RP validation and cancellation are checked against an independent verifier rather than an echoing mock.
- Import conflict decisions preserve unrelated accounts and reject unusable key/TOTP data without partial mutation.

### Real integration and native acceptance

Build the app with full Xcode on Pro and verify on the Air using an owned stage app/home. Stage mode is DEBUG-only in the current code; a Release launch with `WSURF_STAGE=1` is not isolated stage verification.

Exercise the real settings/unlock/account UI and the same controlled login fixtures on WebKit and Chromium. Include a first save, update, ten-account selection, username-first navigation, TOTP refresh, profile switch, lock, and restart.

For WebAuthn, invoke the actual page APIs and have a real server validate registration and assertions. Exercise abort/stale-frame and invalid RP requests. Confirm results are behaviorally equivalent on both engines.

For exchange, exercise the real OS chooser and recipient/source apps with owned credentials. Reimport and verify the password, server-accepted passkey, and matching TOTP generator rather than checking that an item count grew.

User approval of this design does not authorize access to real production passwords, publishing a probe, changing account/security settings, or silently creating/deleting Apple credentials. Confirm exact consequential actions at their point of risk; keep provider safety approval interactive.

## Binding 2026-10-09 workstream decisions

The architectural design was approved on 2026-10-06. The binding 2026-10-09 direction in this document supersedes its earlier PRF-first development sequence and approved legacy-removal/cutover assumption. This reconciliation does not claim provider feasibility or native integration success.
- Preserve existing Keychain `SavedPassword`/`SecureAutofillVault`, settings, autofill behavior, and data. They remain active by default; no migration, deletion, or automatic cutover.
- Develop the new encrypted store independently of real Apple PRF feasibility. Never use fake production keys or plaintext fallback.
- New-manager selection is explicit and mutually exclusive with legacy password autofill; use existing settings patterns and never run simultaneous autofill writers.
- Scope remains passwords, website passkeys, and TOTP on both engines, plus explicit Apple Passwords transfer of all three types in both directions. No recovery/master-password additions.
- Native Apple registration and transfers require exact point-of-risk interactive approval.

### Implemented status: explicit manager selection and contextual credentials (Task 8, 2026-10-09)

Source and automated checks only; this is not native acceptance.

- Provider choice is a per-profile setting. Legacy is the default; the manager is used only after an explicit choice, and each request is bound to the provider, profile, unlock epoch and vault revision it started under, so a later switch cannot turn a legacy request into a manager fill or the reverse. Legacy data, settings and callers are unchanged.
- Manager metadata is shown in the native picker only after an explicit unlock. Exact, case-distinct and duplicate usernames keep distinct account IDs with enough label and context to choose.
- The existing `AutofillSaveSession.UsernameStep` carries the selected account ID (never a secret) across username, password and code steps on the same page, origin and unlock under a fixed 300-second deadline; a changed username, tab, origin, profile, lock or expiry drops it.
- A code is generated at delivery, only for an origin the account explicitly lists, and the seed never reaches page JavaScript. A submitted code is never saved as a password.
- Saves and updates write only the exact account the user was shown. If the review changes the target (another stored username, a new username after an update was offered, a changed vault), nothing is written and the new target is offered for confirmation. Neighbouring accounts, passkeys and codes are preserved.
- A fill reads the vault last, then requires the same unlock epoch, revision and write generation (`CredentialManager.stableGeneration`, unavailable while any vault write is in flight) and the request's native authority in the same synchronous turn that invokes the page API.
- Extension precedence: a recognized password extension still takes over filling when the legacy store is the provider (unchanged). An explicit credential-manager choice is not silenced by it; the extension is never disabled or altered and its own scripts remain independent, so the Autofill settings page names it and says it may still fill until the user turns it off. Checked by a contract test over real extension records (the full tab/engine interaction is not natively verified).
- Fill delivery, traced in source (not natively exercised): `AutofillSuggestions.fill` builds a `prepare` closure per provider (`AutofillSuggestions.swift` 435-472). The manager branch materializes the password or code there, under the request's native authority, identity, `stableGeneration` and authorization epoch; the legacy, card and contact branch calls `requireAuthority` before `fillArguments` in the same closure. `BrowserPage.callAsyncJavaScript(prepareArguments:)` runs it at the final dispatch. On WebKit `prepareArguments` and the final dispatch check run in the same synchronous continuation as the native call, with no suspension between them (`BrowserPage.swift` 450-467). On Chromium the awaits (`ensureReady`, frame lookup, execution context, document marker) all complete before `ChromiumDevTools.command`, whose synchronous continuation runs `prepareParameters`, the dispatch check and `send_dev_tools_message` (`ChromiumDevTools.swift` 192-259, 450-510). So a late lock, profile change or edit cannot slip between the secret guard and delivery on either engine. The legacy-branch guard is implemented in source only. `WebAuthnContextTests.finalDispatchRevalidationPreventsStaleJavaScript` covers the transport ordering on both engines only; no automated test drives `fill` end to end, so this is not full fill or UI proof.
- Frame origin, traced in source (not natively exercised): on Chromium, when the engine gives no parseable security origin (for example an opaque or sandboxed frame), the frame origin is derived from the native frame URL and flagged untrusted (`ChromiumDevTools.parseFrame` 893-908); WebKit builds its origin from native `WKFrameInfo` and has no such fallback. WebAuthn and credential contexts (`ChromiumDevTools` 410, `WebAuthnContext` 87, `BrowserPage` 484/534) and the password, TOTP, card, contact and save autofill consumers (`AutofillSuggestions` 140; `AutofillSaveCoordinator` 440, 462, 475, 508) refuse such frames. No automated test drives the autofill case; it needs a TLS fixture and a Chromium sandboxed https frame, and `WebAuthnContextTests` 501 covers only the WebAuthn side on a file:// WebKit frame. How an opaque origin serializes is [INFERENCE], not probed. Native opaque-frame and TLS full-flow validation is pending.
- Not claimed: native UI acceptance; Apple PRF unlock; Apple Passwords transfer. Writers outside the app process are not covered; none exist today.

## Evidence

- [Apple PRF input and deterministic key derivation](https://developer.apple.com/documentation/authenticationservices/asauthorizationpublickeycredentialprfassertioninput-swift.struct)
- [Apple PRF outputs: do not store or export](https://developer.apple.com/documentation/authenticationservices/asauthorizationpublickeycredentialprfassertionoutput-swift.struct)
- [Native passkeys and Associated Domains](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys)
- [Passkey use in alternate browser engines](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)
- [Credential-provider extension](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller)
- [Credential import](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager)
- [Credential export and system-mediated transfer](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager)
- [Exchange passkey private-key format](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/passkey/key)
- [Exchange TOTP parameters and secret](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/totp)
- [Required exchange TOTP algorithms](https://developer.apple.com/documentation/authenticationservices/asimportablecredential/totp/algorithm-swift.enum)
- [Apple Passwords currently documented CSV password import](https://support.apple.com/guide/passwords/import-passwords-mchl2f1a184c/mac)
- [RFC 6238](https://www.rfc-editor.org/rfc/rfc6238)
