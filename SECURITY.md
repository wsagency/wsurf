<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Security

WSurf keeps API keys in the macOS Keychain. An agent operates live web pages,
and the app installs extensions from the Chrome Web Store. If you find a
security defect in one of these areas, report it privately.

## Reporting a vulnerability

Use GitHub’s private vulnerability reporting on this repository
([**Security › Report a vulnerability**](https://github.com/wsagency/wsurf/security/advisories/new)).
Do not open a public issue for an exploitable vulnerability.

You get an acknowledgment in one week or less. There is no bounty program,
because this is a small open-source project. The release notes give credit to
each person who reports a defect. If you do not want this credit, say so in
your report.

## Scope

- External MCP connections (`WSurf/MCP`). Connecting must disclose no browser
  data without an explicit tab-and-origin grant. Site denials, read-only access,
  private browsing, revocation, and profile boundaries also apply. A connection
  must not inherit the assistant's consequential-action approvals or operate
  controls from another connection's observation.
- The assistant’s action policy. The assistant asks before it does anything
  with consequences, and refuses to fill a sensitive field
  (`WSurf/Web/Privacy/SensitiveAction.swift`,
  `WSurf/Web/Assistant/AgentActionPolicy.swift`).
- Installing, verifying and updating extensions
  (`WSurf/Extensions/CRXVerifier.swift`,
  `WSurf/Extensions/ExtensionUpdates.swift`). WSurf checks the Chrome Web Store
  for updates daily. Updates requiring additional access wait for user approval.
  Granting that access without approval is a defect.
- Credentials (`WSurf/Agent/Providers/CredentialStore.swift`). A key goes only
  in the Authorization header of the provider it belongs to.
- The opt-in Credential Manager and credential-exchange extension
  (`WSurf/Web/Credentials`, `WSurf/Web/Credentials/Store`,
  `WSurfCredentialExchange`). Passwords, passkeys, and one-time codes belong
  to one profile, and any window leaving that profile revokes the
  authorization epoch for all of its windows. A request must pass the origin,
  relying-party, and native policy checks; a stale epoch is refused. A commit
  changes a credential and its related state atomically. A path that crosses
  profiles, acts after revocation, or commits partly is a defect. The
  extension is exchange-only and holds no credential store.
  - Store. A profile keeps one encrypted store (`Credentials.store`) of up to
    16 active vaults, each with its own key and passkey unlock and a linked
    Trash that opens with its source vault. A registry authenticated with a
    registry key lists every vault and the digests of its heads and wrappers.
    That key is sealed inside every active vault's head, so a holder of any
    one unlocked vault can read it and re-authenticate a forged registry;
    it opens no other vault. The vault's password-saving policy (blocked
    origins) lives in its sealed head. The profile's witness (a preferences
    value holding the store id) is not cryptographic: it detects accidental
    loss or replacement, not an attacker. Missing, foreign, unreadable or
    leftover files fail closed with the paths listed and Retry as the only
    action; nothing is moved or deleted to recover. Not solved: loss of the
    store, its stub, the witness and every migration leftover together reads
    as a first run (a surviving `Credentials.vault.pre-v2` or other leftover
    fails closed instead); restoring a whole older consistent store loses
    later changes undetected; the vault list before an unlock is not
    authenticated.
  - Upgrade. The upgrade of a pre-store vault is one-way. It writes a
    verified backup, `Credentials.vault.pre-v2`, and older builds can no
    longer open the vault. The backup holds the old vault under its old
    wrappers: it does not contain later changes, is not covered by purge and
    still decrypts anything purged later for whoever can unlock those
    wrappers. WSurf never deletes or overwrites it.
  - Removal. Removing an unlock passkey stops its normal unlock of the current
    vault only. The vault key is not rotated, so a removed passkey that still
    has a copy of the vault file containing its wrapper can decrypt that copy
    and later versions of the same vault. Removal is not forward revocation.
    A purge is a logical row purge, not secure erasure: it replaces the
    chosen entries and their earlier versions with identifier-only records,
    and older database pages, backups and the pre-upgrade backup may still
    hold the data.
  - Bounds and exchange. Per vault: 1,000 accounts, 4,000,000 bytes of live
    data, 32 wrappers; 16 active vaults per profile (each Trash in addition);
    a history row is capped at 8,000,000 bytes and history has no count
    limit. An export hands data to the system and records only that hand-off; Apple Passwords decides what
    it does with it, WSurf gets no receipt and cannot see or undo it, so a
    hand-off is never reported as accepted, written or synced.
- Download filenames (`WSurf/Web/System/DownloadManager.swift`). The app does
  not run in a sandbox, so treat a filename from a server as a path until you
  have proved it safe. WSurf quarantines each completed file for Gatekeeper to
  examine, and a path that skips the quarantine stamp is a defect. The list of
  finished downloads is written to disk; a private download never is.
- Certificate exceptions (`WSurf/Web/Privacy/CertificateTrust.swift`). WSurf
  sends every server-trust challenge to the system and allows certificate
  exceptions only when enabled in Privacy settings. An exception belongs to one
  host paired with one certificate fingerprint. The app holds it in memory only.
  A path that accepts a certificate without a prompt, that keeps an exception
  after the setting goes off, or that applies an exception to a different
  certificate on the same host, is a defect.
- Profile separation (`WSurf/Profiles/Profile.swift`,
  `ProfileStore.swift`). Each profile has its own website data store,
  database, permission file and extension directory. A path that lets data
  from one profile reach another is a defect.
- Embedded browser boundaries (`WSurf/Web/Engines`). Chromium uses the native
  CEF sandbox and separate profile request contexts; private contexts have no
  persistent cache. Switching engines must not copy cookies or replay a POST.
  CEF frame/document IDs, security origins, and unique execution contexts must
  stay current across asynchronous script and permission operations. Page
  bindings belong to their isolated world and must not authorize another frame.
- Website permissions (`WSurf/Web/Privacy/SitePermissions.swift`,
  `PermissionCenter.swift`, `NotificationBridge.swift`). A permission belongs to
  one origin: the scheme, the host and the port. A page that is not on TLS is
  refused without asking the person. Camera, microphone, location and
  notifications are for the main frame only, and what a page is told about its
  permission has to match what WSurf stored. A frame using the containing page’s
  permission, or a page receiving an incorrect permission status, is a defect.
- The lyrics lookup (`WSurf/Media/Lyrics/LyricsModel.swift`). WSurf sends the
  track and artist names to lrclib.net, only while the setting is on and never
  for a private tab. A lookup from a private tab, or one made while the setting
  is off, is a defect.
