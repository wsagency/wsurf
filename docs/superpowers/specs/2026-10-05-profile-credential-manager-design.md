# WSurf Per-Profile Credential Manager

Date: 2026-10-05

Status: All five conversational design sections approved. Written-spec review is the next approval gate. Product implementation is not authorized by this document alone.

## Intent and agreed scope

WSurf owns its password, website-passkey, and TOTP manager. Each normal browsing profile has its own encrypted vault. The manager lives in the app and behaves consistently with both WebKit and Chromium; switching engines does not change credential ownership or create another credential store.

The user's concrete multi-account case is approximately ten Gmail logins. The site/login URL and entered username identify the relevant account. The selected account can continue through separate username, password, and TOTP pages without filling a different account's secrets.

Apple has two distinct roles:

1. Externally held WSurf unlock passkeys supply PRF-derived keys for vault unlocking.
2. User-mediated exchange copies selected passwords, website passkeys, and TOTP generators between WSurf and Apple Passwords, if runtime verification establishes Apple Passwords participation in the exchange API. Apple synchronizes credentials held by its provider across the user's approved Apple devices.

The user explicitly chose unlock passkeys only. There is no recovery key, master password, or operating-system Keychain fallback for the new vault. Losing every external unlock passkey permanently loses access to the encrypted vault, even when a ciphertext backup exists.

The user reports there are no existing WSurf passwords in use. Start with empty vaults. Do not build migration, legacy recovery, or migration/cutover UI.

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

- Existing-password migration or a parallel legacy password store.
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

The current password suggestion index exposes account metadata outside the password blob. The new manager must not maintain a plaintext index of vault usernames, URLs, passwords, or TOTP secrets. Replace password-only consumers of that index; preserve unrelated card/contact behavior.

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

### Lifecycle and mutation

- Creating a vault requires a PRF-capable external unlock passkey and a verified wrapping/unwrapping round trip.
- Missing PRF output or unsupported PRF is an explicit failure, never a different key derivation or Keychain fallback.
- Adding an unlock credential requires an already unlocked vault and successful verification of the new wrapper before committing it.
- Removing an unlock wrapper must leave at least one valid unlock path. It does not delete the external Apple credential automatically.
- Removing a wrapper affects the current vault state; it cannot revoke access to historical copies containing that wrapper.
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

Native WSurf confirmation identifies the actual domain and selected account before registration or assertion. The app generates ES256 website credentials; other requested algorithms must either be genuinely implemented/validated or produce the standard unsupported result. Imported key formats are validated before acceptance, and unsupported private-key algorithms are explicit import conflicts rather than silently accepted unusable records.

Returned objects must satisfy the WebAuthn response contract used by the page, including byte buffers and relevant response/helper methods. A test-only CDP virtual authenticator is not the production implementation.

Passwords and current OTP codes intentionally filled into a webpage can be read by that page. The page never receives a TOTP seed, website private key, PRF key, or vault key.

## 4. Credential exchange and failure behavior

### Apple API contract

Use `ASCredentialImportManager` and `ASCredentialExportManager` on supported macOS versions. Register a credential-provider extension with `SupportsCredentialExchange = YES` and `SupportedCredentialExchangeVersions = ["1.0"]`, and configure the containing app's exchange user activity handling. Proper app/extension signing, entitlements, and provisioning are required.

A signing certificate signs the app; it is not a grant to read the entire Apple Passwords vault. The browser's managed public-key entitlement, the AutoFill-provider entitlement, Associated Domains, and credential-exchange registration are separate surfaces. Do not add a managed any-RP Apple-browser capability merely to implement app-owned website cryptography or own-RP unlock.

Import starts with a user-initiated export in the source app. WSurf receives the system token and asks for the target profile, unlock, and record/conflict confirmation before committing data. Do not stage plaintext credential files while waiting for unlock.

Export selects account credentials in WSurf and uses the out-of-process system destination/risk UI. An account can export its password, website passkey, and TOTP together while preserving their association. The transfer API does not write a credential file.

The API supports genuine passkey private keys in PKCS#8 representation and TOTP secret bytes with issuer, username, algorithm, period, and digits. Preserve identifiers, parameters, and supported extension metadata. FIDO2 extension exchange APIs require macOS 26.4 or later where relevant; do not claim PRF-extension preservation on an OS that lacks those fields.

### Named Apple Passwords prerequisite

Public Apple exchange documentation establishes transfer between participating credential-manager apps. It does not establish that Apple Passwords participates in every requested direction/type; its current import guide describes CSV passwords.

Before accepting Apple Passwords integration as implemented, demonstrate WSurf to Apple Passwords and Apple Passwords to WSurf transfer of a password, a usable passkey, and a TOTP generator on the target OS. Verify the received secrets by actual use. If the target app does not participate or rejects a type, report the exact blocker and stop that dependent work. Do not substitute CSV, export screenshots, or mark a generic exchange API wrapper as complete.

Apple synchronizes credentials it holds. The exchange API is not an inventory/readback channel, does not prove remote synchronization completeness, and does not provide automatic bidirectional WSurf updates. Changes in either manager require another explicit transfer. Synchronizing an unlock passkey does not synchronize WSurf's encrypted vault file.

### Conflicts and errors

Validate imported record types, identifiers, key encoding/algorithms, URL scopes, TOTP parameters, and payload limits before modifying the vault. Preview conflicts per account/credential; matching a domain alone is insufficient for overwriting a different password or seed. Do not infer a permitted website origin from a TOTP issuer string.

Cancellation, token mismatch/expiration, unsupported data, authentication failure, wrong-profile context, and lock/profile changes have explicit outcomes. Preserve the prior valid vault on failed operations and do not expose secrets in diagnostics. The export UI must distinguish API transfer success from unverified destination acceptance/synchronization. Do not delete source credentials automatically after export.

There is no migration branch or legacy-password fallback. Remove obsolete password-only storage/index paths during the clean cutover while retaining shared code still used by cards or contacts.

## 5. Development sequence and verification

Develop in dependency order, retaining every required outcome:

1. **Integration gates:** approved isolated probes for native PRF, app-owned WebAuthn bridging on both engines, and Apple Passwords exchange of all three types. Use owned test credentials and properly signed apps. A failed prerequisite stops the dependent portion and is reported, not bypassed.
2. **Vault and password/TOTP manager:** independent per-profile encrypted storage, multiple PRF wrappers, lock lifecycle, settings/editor, contextual selection, and multi-step login. No migration code.
3. **App-owned website passkeys:** registration/assertion, discovery and consent behavior, security validation, and both engine adapters against a real verifying server.
4. **Credential exchange:** selected records/profile, preserved secrets and account links, conflict decisions, and verified Apple Passwords transfer in both directions.

This is the architectural development order, not an implementation plan or permission to execute probes. After written-spec approval, write an implementation plan and obtain the user's execution-method choice. Where separate development cycles need their own detailed specs/plans, retain this common ownership/security contract and obtain their reviews; do not shrink the end-to-end scope silently.

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

User approval of this design is not permission to access real production passwords, publish a probe, change account/security settings, or silently create/delete Apple credentials. Confirm exact consequential actions at their point of risk; keep provider safety approval interactive.

## Approval and handoff

The five in-chat sections and the removal of migration were approved. Review this written document before the planning handoff. Written-spec approval permits writing the implementation plan only; product implementation also requires review of that plan and selection of its execution method.

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
