<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Changelog
This file preserves release notes inherited from the upstream
[kavoye/linen-browser](https://github.com/kavoye/linen-browser) project. They
describe upstream Linen releases, not releases published by WSurf. New WSurf
release notes will be added above this provenance record.

## WSurf

### 2026-10-15 — Credentials: Unlock works again after the vault locks

After a credential vault locked, **Unlock** could report "Couldn’t find this window to show the passkey prompt". The page remembers its window through a hidden view; that view was attached to the part of the page that changes between locked, unlocked and failed states, so SwiftUI created one per piece of the current state and the page kept whichever was updated last. After a state change the page could be left holding a view that was no longer on screen. The hidden view now sits on the page header, which every state keeps, so there is exactly one. Nothing about unlocking changed: the passkey prompt is still required and is still shown on the window that holds the page, never on another window.

Checked: a small SwiftUI probe in a real (invisible) window reproduced the loss with the old placement after the content changed and kept the window with the new placement, through lock, unlock and lock again; `Tools/check-format.sh` (SwiftLint 0.65.1) reports no violations. Not run: no Xcode build or test, and the real Unlock button was not used. There is no permanent UI regression test, because no reliable test of the real page is available here; the native acceptance is lock, Unlock, lock, Unlock again on the built app.

### 2026-10-15 — Credentials: a refused transfer from Passwords now says why

When a transfer from Passwords was refused ("The transfer could not be read"), the message gave only the position of the record (for example `account[0]/item[0]/credential[1]`), so two different causes looked the same. The message now also gives a fixed reason (not supported, could not be validated, an identifier repeated, over the import limits) and, when the position is a credential, its kind by the system's own case name (for example `note`, `totp`, `passkey`). It never includes a value, a title, a website or the underlying error text. The message no longer says "Export again from Passwords": the transfer is discarded and WSurf does not retry it.

This is a diagnostic only. What WSurf accepts is unchanged: a transfer is still read in full or refused in full, only passwords, passkeys and verification codes are imported, and nothing is written before Review and Import. It does not fix the failure that prompted it: that needs the reason and kind from a new attempt.

Checked: a swiftc build of the import codec and message with synthetic dummy records (a note, a second login, a verification code with period 0 and a malformed passkey key, each after a valid login) gave the expected position, reason and kind and no content in the message, and a valid login with a verification code still imported; `Tools/check-format.sh` (SwiftLint 0.65.1) reports no violations. Not run: no Xcode build or test; the updated unit tests (`CredentialExchangeTests+Import`, `CredentialExchangeCoordinatorTests`) have not been compiled or run.

### 2026-10-15 — Sleep inactive tabs after a time, and named color presets

**Sleep inactive tabs** can now also unload a background tab after it has been idle for a time you choose: 15 minutes, 30 minutes, 1, 2, 3 or 4 hours, or a custom number of minutes or hours. The switch is still off by default, and with no duration set it behaves as before, unloading only under memory pressure, which can still unload earlier. A single repeating check per window runs only while the switch is on and a duration is set. A tab's idle time starts when it leaves the screen, including the other pane of a split, not when it was opened or last in front hours earlier; it is measured with a monotonic clock that keeps counting while the Mac sleeps. Tabs opened or restored in the background start their idle time at that moment, and a tab that was already idle when you turn the setting on counts the time it has been idle. Unloading uses the same path and protections as memory pressure: favorites, Keep Loaded, the active tab and visible split panes, private windows, extension pages, forms with typed text, downloads, media, camera or microphone use and agent activity are never unloaded, and manual unload is unchanged. An unloaded tab reloads when you open it; on Chromium (CEF) pages it restores the address only, not back/forward history or scroll position. The protections rely on the same activity signals on both engines, traced in the source; not yet verified at run time on CEF.

**Color presets** in Settings → Appearance: Catppuccin Latte and Mocha, Nord, Dracula, Gruvbox Light and Dark, and Rosé Pine and Rosé Pine Dawn. A preset sets the real window, sidebar and control-surface colors, the accent, and the text and icon colors, and switches the window to the light or dark mode it was designed for. It draws solid in both window styles, and unloaded tab text keeps at least 4.5:1 contrast. Nothing changes until you choose one. While a preset is on, the Theme, Theme customization, Window style (with Website tint, Tint selected tab and Transparency) and sidebar text color controls are hidden; their saved values are not changed and come back when you press Reset, and a Settings search for one of them opens the Color preset row. A private window is always dark, so a light preset falls back to the standard dark surfaces and standard sidebar text there. Palette values come from each project's published palette (Gruvbox from the MIT-licensed Tinted Theming schemes, Rosé Pine from `@rose-pine/palette` 4.0.1); their notices are in `NOTICE`, the in-app acknowledgements and `Tools/vendored`.

**Sleep after, custom time**: a custom number of minutes or hours is applied only when you press Apply or Return, not while typing; Apply is dimmed while the typed value is already the applied one, and the row shows what is applied. A value that is empty, not a whole number, zero, or larger than 2,147,483,647 minutes is refused with a message that clears after the next good Apply or when you change the unit, and the previous setting stays. A custom value equal to a menu choice, such as 60 minutes, becomes that choice.

Verification. Source/component level (outside Xcode, Command Line Tools only, swiftc with the project's Swift 6, MainActor default isolation and MemberImportVisibility flags): `ThemePreset.swift` compiled with a harness (text and unloaded-text contrast at least 4.5:1 on each sidebar, lowest 4.64 for Rosé Pine Dawn; the ink resolves to the preset color under the light appearance and to the fallback under dark; Rosé Pine Dawn text 575279) and the extracted `SleepAfterRow.minutes(from:factor:)` (accepts 90 minutes, 2 hours and 35,791,394 hours; rejects 35,791,395 hours, empty, 0, negatives, decimals, non-ASCII digits and 20-digit overflow). Earlier component check of the real `TabSleepTimer.swift` with the test clock (repeating ticks; no tick from a sleep that finished just before a stop or restart). SwiftLint 0.65.1 (the CI pin) via `Tools/check-format.sh` reports no violations; `Acknowledgements.json` regenerates identically twice; `swiftc -parse` passes on the changed views and tests. Not run: the Xcode build, the Swift Testing suites (the new and extended tests are authored, not executed), and any Settings UI, private-window, window-backdrop or Chromium idle-unload check in the app.

### 2026-10-14 — Credentials: an Import & Export section, and password CSV files

Credential Settings has one **Import & Export** section (it holds the incoming-credentials row that used to be its own section, and the Export… button that was on the Saved credentials header). **Choose File…** imports a password CSV and **Export to CSV…** writes one. A CSV is read by its header, not by column position: `URL` (or `Url`), `Username` and `Password` are required, `Title` or `Name` is used as the name, and both the 4-column `Title,Url,Username,Password` and the 6-column `Title,URL,Username,Password,Notes,OTPAuth` layouts work. That is compatibility with the layouts public third-party importers read, not a statement of Apple's format. A file over the vault's size limit is refused before it is read.

Import goes through the same review as the system credential exchange and the same single per-account write. Only passwords are imported: notes and verification-code (`OTPAuth`) columns are never imported, and the review lists the line numbers of rows that have them, of rows that cannot be imported (no website, a website that is not `https`, no password, a row that does not match the header) and of unrecognised columns by position (never by their header text). A header that names the URL, Username, Password, title, notes or code column twice is refused, since there is no single right column to read. A website is never completed (`example.com` without `https://` is refused). A username and a password are compared as exact bytes, not as Unicode-equivalent text and never as a delimited string: `Alice` and `alice` are two logins, and so are `é` as one character and as `e` plus an accent. A row identical to a stored login is counted as already saved and skipped. A row whose website and username match a stored login with a different password is a conflict you decide; every such row of the file is its own choice, but one stored login takes only one Replace (a second is refused), and Replace changes only that password and keeps its passkeys, verification code, exchange identifiers and field metadata. Rows of the file that share a website and username but differ in password, and a row that matches several stored logins, are never decided for you: each is marked **Choose…**, nothing is saved until every one is Skipped or Added separately (Replace is offered only for a single named stored login), and the review names the line of the file. An exact duplicate row is reported and skipped. The review counts what the file holds; only the receipt after Import counts what was saved.

Export writes only logins that have both a password and a website, as one row per website, after you have chosen the destination in the save panel (which asks before replacing a file); the selection is checked against the vault again after the panel closes. The file is written as a private (`0600`) temporary file next to the destination and moved into place in one step, so a failure or a change in the vault leaves any existing file exactly as it was; only WSurf's own temporary file is ever removed, and an import reads only an ordinary file up to the size limit. The file is **not encrypted**, WSurf never deletes it, and the export sheet says so, counts the passkeys, verification codes, logins without a website and notes it cannot include, and cautions against opening it in a spreadsheet (values are written unchanged, even when a spreadsheet could read one as a formula). The Import & Export entries are visible but off while the vault is locked or missing, with the reason. WSurf's CSV transfer carries no passkeys and no verification codes (it reports an `OTPAuth` value in a file it reads and does not import it); move those with Export… and the system credential exchange.

Maintenance fix (same day): the first pass of this change failed `Tools/check-format.sh` (SwiftLint 0.65.1, 24 style and size errors). The CSV header lookup now sits in a small private `Columns` type, the shared import value types moved to `CredentialImportReview.swift`, and the settings model's export methods moved to `CredentialSettingsModel+Export.swift`; the model's `manager` is now `private(set)` and its `exchange`, `ownMessage`, `live`, `authorizedSnapshot` and `perform` are internal so that extension can reach them. Behavior is unchanged. After the fix `Tools/check-format.sh` reports no violations and the swiftc CSV component check passes 27 of 27.

Not run: no Xcode build or test of this change has been run; only a swiftc component check of the CSV parsing and staging code.

### 2026-10-13 — Credentials: several vaults per profile, Trash and earlier versions, and a one-way store upgrade

Each profile now keeps its credentials in one encrypted store (`Credentials.store`) that holds up to 16 active vaults, each with a linked Trash. Every vault has its own passkey unlock, its own manager and lock, and a five-minute unlock; a profile lock (profile switch, sleep, screen lock, quit, profile erase) locks every vault of the profile. A locked vault is listed only by number, with no name or content. You can choose a default vault, create a further vault with a new passkey or with a passkey already enrolled in another vault of the profile (vaults sharing a passkey share its exposure: one compromised authenticator opens all of them), and remove an unlock passkey. Creating a vault never reuses or extends an existing unlock. Removing a passkey stops its normal unlock; it does not rotate the vault key, so a copy of the vault file that still holds its wrapper can still be opened with it.

Where a login is saved or filled is decided by the vault that holds it: a match in one unlocked vault goes to that vault; a match in several vaults, or none while another vault is locked, asks you to choose; the default vault takes new logins; a locked default vault asks you to unlock or choose and never falls back silently. Suggestions read only unlocked vaults. A passkey request is bound to the vault it runs on and ends only when that vault locks or the profile's access ends; choosing a vault only selects it and unlocks nothing until the request is checked again afterwards. Credential sheets belong to the task that awaits them, so a cancelled request dismisses its own sheet. Creating the first vault removes the files it built only when it is cancelled or its creation lease is dead; any other failure keeps them as fail-closed evidence and refuses a blind retry.

Each vault has a linked Trash that opens with the vault's own unlock and has no unlock of its own. Removing an account, a password, a one-time code or a passkey moves it, with its earlier versions, to the Trash in one transaction. The Settings page lists the Trash and an account's earlier versions in pages of 50 with counts checked against the stored rows. You can undelete (refused, with nothing written, when a live item has the same id, exchange item, website and username, or passkey, or the owner is gone) and restore an earlier password, one-time code or website-metadata version (passkeys are never restored from a version). Emptying the Trash or removing items for good needs a confirmation and a fresh passkey assertion. Purging is a logical removal, not secure erasure: the chosen entries and their earlier versions are replaced by a record that keeps identifiers only (no password, one-time-code seed or key), but encrypted remnants (older database pages), Time Machine or other backups, and the pre-upgrade backup can still hold the removed data, and WSurf never deletes those copies.

The first unlock of a vault saved by an older WSurf asks for an explicit confirmation, then upgrades it once, in one exclusive step: it writes a verified backup, `Credentials.vault.pre-v2`, builds and verifies the new store, and only then swaps it in. The upgrade is one-way. Older WSurf builds can no longer open the vault and show a corruption-style error; changes made after the upgrade are not in the backup; the backup still holds the vault as it was, under its old unlock wrappers, so anything you later purge stays readable there to whoever can unlock those wrappers; and WSurf never overwrites or deletes it, and a purge does not cover it (its path is shown wherever purge or a fail-closed state is explained). A write by an older build that lands during the swap is kept as `Credentials.vault.cutover-v1` and the vault stays closed with both files shown. An interrupted upgrade resumes at the next unlock without losing the old vault.

Integrity: the store has a registry that lists every vault and the digests of its heads and unlock wrappers, authenticated by a registry key. That key is sealed inside the head of every active vault, so unlocking any one vault can read it and could re-authenticate a forged registry; it opens no other vault and wraps nothing. Each vault's head, rows and history are sealed and checked against journals before any removal, and the vault's password-saving policy (the blocked-origins list) is part of the sealed head. A small witness in the profile's preferences remembers that a store existed for the profile; it is not cryptographic and detects accidental loss or replacement, not an attacker. When files are missing, foreign, unreadable, left over from an interrupted step, or disagree, the page shows the cause and the absolute paths with a Retry button only: WSurf never offers Create, reset or acknowledge there, and moves or deletes nothing to get out. Limits it does not solve: if the store, its stub file, the witness and every migration leftover are all gone, the profile reads as a first run (while `Credentials.vault.pre-v2` or another leftover survives, WSurf fails closed instead); a whole older but consistent copy of the store restored in place passes every check and loses the later changes without a warning; the vault list shown before an unlock is not authenticated.

Bounds: each vault holds at most 1,000 accounts and 4,000,000 bytes of live data, at most 32 unlock wrappers and 4,096 blocked origins; a profile holds at most 16 active vaults (each one's linked Trash is in addition). Earlier versions, Trash entries and purge records have no count limit and are bounded only by disk; each row is capped at 8,000,000 bytes. A write over a live limit is refused whole with the limit named, and nothing is dropped to make room.

Import and export: an import is classified against the destination vault only (new, unchanged, changed remotely, locally or both, no common base, ambiguous, previously removed, passkey conflict), matches by exchange identifiers and an accepted pairing and never by website and username, and never replaces a stored passkey. It applies in one per-account write bound to the version stamps of only the accounts it touches, so editing another account while the review is open no longer discards it; before the write starts, a changed touched account, a lock, a re-unlock or a cancel discards the import and writes nothing; if the vault's access ends or the write fails in a way that proves nothing about the outcome once the write has started, the result may already have landed, WSurf says so and asks you to check Saved Credentials, and it never claims a rollback (only a version-stamp mismatch, a limit, a collision or a malformed record, all refused before the first row is written, proves nothing was written). The review and result list what became of each credential (added, updated, unchanged or skipped; kind, title and website only), and every import and export ends in exactly one message with its next step. The ending belongs to the window and vault that began the transfer, so another window's later ending never replaces it and another window's dismiss never clears it; a system token that is ignored (already queued or spent) does not reopen the credential page, only a refused one does. An export records its hand-off time and a content hash only for still-unchanged chosen accounts; a chosen credential that changed meanwhile, including one whose only change is its password, code seed or passkey key, is named and the sheet asks again. Apple Passwords decides what it adds, skips or replaces and gives no per-item receipt, and WSurf cannot see or undo anything on the Apple side, so "handed to the system" is the strongest claim WSurf makes: it never says an export was accepted, updated in Passwords or synced, and these dates and hashes never mark anything as synced.

Verification: the app builds natively and the full automated test suite passes, including the vault, import/export and Settings model tests. Not yet verified by hand on a Mac, and only possible after installing: the on-screen Settings flows, passkey/PRF unlock with real authenticators, and a real credential exchange with Apple Passwords, which gives WSurf no receipt for what it adds, skips or replaces. Those checks are the user's to report.

### 2026-10-13 — Command palette keeps the focus you give it

The command palette's search field no longer takes keyboard focus back after you have moved it elsewhere, and the Ask mention field respects a focus change made by the system.

### 2026-10-13 — Profile settings fail closed

A named profile's settings never fall back to the original profile's (app-wide) defaults. If its own settings domain cannot be opened, the app stops instead of reading or writing another profile's settings.

### 2026-10-12 — Credential editor website fields

Both website fields of the credential editor (websites and other HTTPS origins) are now plain-text list editors: Return, Shift-Return and keypad Enter insert a new line and never save, a typed comma or Space after a valid address starts the next line, and valid addresses are underlined like links but a click only places the caret and never opens anything. Paste, drop and input-method text are inserted as typed, and save-time validation is unchanged. This is source-level only; the on-screen behaviour has not been exercised in a running app.

### 2026-10-13 — CI tests no longer share the installed app's identity

Debug builds take their bundle identifier from `WSURF_BUNDLE_ID_SUFFIX`, empty by
default; Release identifiers, the tests target and default Debug identifiers do
not change. CI builds with a unique `.ci-<run_id>-<run_attempt>` suffix, then
`Tools/check-built-identity.py` refuses to launch the test host unless the built
app, extension, five Chromium helpers and test bundle carry that identity, the one
generated `.xctestrun` names that app and test bundle, and no Stage environment is
set; only then does `test-without-building -xctestrun` run that exact file, inside
the same total watchdog budget. The test host's standard
preferences and default WebKit data then use that identifier instead of
`io.wsagency.wsurf`. A throwaway check on a uniquely suffixed build confirmed a
preferences key and a `localStorage` key stay in that namespace and that the
production preferences, WebKit and Caches metadata did not change. Test hosts also
keep favicon caches under their per-process test directory instead of
`~/Library/Caches/WSurf/Favicons` (a focused regression and its neighbours passed;
the full suite is not claimed here). Other profile test preference domains still
use random UUID names, not per-process ones. The CI job now selects Xcode through
`DEVELOPER_DIR` without `sudo xcode-select`, installs SwiftLint under
`RUNNER_TEMP`, downloads the Metal toolchain only when `runner.environment` is
`github-hosted` and otherwise only verifies it, no longer passes
`-skipMacroValidation -skipPackagePluginValidation`, no longer uploads every
host crash report, and runs a watchdog check; the watchdog now samples only its
own child and never lists host processes. A final step removes the run's own
preferences, WebKit, Caches, HTTPStorages and Saved Application State by exact
identifier. Limits: the Pro machine's own Gitea runners are distinct from this GitHub
Actions job, whose advertised runtime was GitHub-hosted (`runner.environment`
`github-hosted`); that job's OS isolation and account are not verified here, and the
suffix is namespacing, not OS isolation. macOS-managed
`~/Library/Containers/<id>.CredentialExchange` cannot be removed by `rm` and
stays; a hard-killed runner skips cleanup; the registered-extension `pluginkit -r`
branch has not been exercised. GitHub's fork pull-request approval policy is
unchanged and lets prior contributors' fork runs start without approval, which
stays unsafe until the owner permits a change, so only trusted-branch work may use
this runner.

The narrow probes above passed, but a full native test run then found a real
write to the production `~/Library/Application Support/WSurf/SitePermissions.json`:
two tests built `SitePermissions(storageURL: nil)`, whose implicit default pointed
at the installed app's file. The default is removed. `SitePermissions` now requires
an explicit file URL and those tests use their own, under the per-process test
directory. A targeted native run of the changed callers and their neighbours
(131 tests in 8 suites, including `FormConsumerBoundaryTests`,
`MCPPrivacyTests` and `SitePermissionsTests`) passed, and known production
metadata, including that file and its parent directory, was unchanged across it.
A later full native run on the fixed source ran 3244 tests in 351 suites in about
939 seconds, inside the watchdog budget, with 14 existing disabled tests and no new
skips. One test failed, a separate, not yet diagnosed failure in
`WebAuthnContextBackForwardTests` (its first `route == manager` check, before any
back/forward navigation), so the
full suite did not pass and CI is not green. The privacy part of that run held:
known production metadata, including that file and its parent directory, was
unchanged, and only owned namespace paths were created and cleaned. What the
earlier write changed is unknown: the file's content before it was never recorded,
and it was left untouched. Only the paths named above were checked, so this does
not show that all production data stays unchanged. A later diagnostic build of
`WebAuthnContextBackForwardTests` (extra instrumentation only, not a product fix)
passed its build and artifact guard and the 30-test `WebAuthnContextTests` run, but
the cause of the full-run failure is still unknown and was not reproduced by that
targeted run. The first CI run of this change failed at the Metal
toolchain step (the hosted image lacks it and the verify-only replacement removed the
download); that step is fixed in source and awaits a new run, so no CI result for
this change exists yet.

### 2026-10-11 — Remove managed browser passkey entitlement

WSurf no longer declares or requests Apple's managed
`com.apple.developer.web-browser.public-key-credential` entitlement. Release and
tip validation require it to be absent from the signed app and credential
exchange extension. Provider defaults, routing, data, and migrations do not
change. Native system passkeys for arbitrary relying parties via WebKit are not
guaranteed in legacy/default or private tabs. WSurf's vault-managed WebAuthn,
`wsurf.app` PRF unlock, and Apple Passwords exchange use separate paths.

### 2026-10-11 — Website passkey metadata and Settings

Website passkeys retain optional creation time, local creation/import provenance, and last local signature time in the encrypted vault; imported passkeys have unknown creation time. A local signature timestamp is committed under the expected vault revision and authorization epoch; it records local signing, not website receipt or sign-in success. After that commit succeeds, a later lock, cancellation, navigation, expiry, changed vault state, or vault read failure can still prevent assertion delivery. Stale-revision, authorization, and I/O commit failures refuse delivery; assertions are not retried from stale state.

Credential Settings and the assertion picker show the full immutable passkey UUID; removal confirmation names that exact UUID and RP ID, then removes only that local copy through the existing draft Save. Same-RP/same-user-handle registrations retain each passkey separately; `excludeCredentials` still rejects a matching credential. The user explicitly approved this retain-all deviation for the bounded metadata design and merge/deploy for manual testing; it is not a claim of WebAuthn conformance. Code `21ff6c801659e4129c342332149b199350dfc9ec` passed hosted run 38095943728 (3,019 tests in 334 suites, coverage 52.47%, format and every performance budget; overall success; 500 tab activations averaged 0.004793 s against 0.035 s); the final PR head still needs its own checks. The earlier run 38092727778 on `2c8949e` failed only the performance-budget step (0.036752 s) and is historical, not a current blocker. A dead top-bar coverage state in the tab/split model was removed (the always-false `isUnderTopBar` flag, its refresh loop and 4 calls); the explicit zero-inset resets on page adoption and on fullscreen changes, the `topBarInset` API and the split geometry stay, and one test that only asserted the default flag was removed, not skipped. No cross-run speed-up is claimed. Native acceptance remains pending.

### 2026-10-10 — Credential Manager in source

Implemented in source, not released, and not natively accepted: an opt-in
per-profile encrypted Credential Manager for passwords, ES256 passkeys, and
one-time codes, plus an exchange-only credential-exchange extension. Legacy
SavedPassword, SecureAutofillVault, settings, data and the default provider are
unchanged; the manager is used only when a profile selects it.
`CredentialManager.commit` and `updatePasswordSavePolicy` require the
authorization epoch captured at decision time and refuse with `unauthorized`
after a lock or re-unlock. Verified on the integration branch: WebAuthn nonce, history
(back/forward cache root) and late-resume handling, plus escaped
Permissions-Policy denial. The current proof is the joined 17-suite run, the
strict lint gate and a built-module CLI smoke (synthetic password, passkey and
one-time code through encrypted save, reopen, exchange export/preview/apply
and ES256 verification), recorded in the current-main integration appendix
(`docs/superpowers/plans/2026-10-10-credential-current-main-integration.md`).
Fill delivery (manager, legacy, card and contact) checks the request's
authority at the final dispatch point with no suspension before the engine
send; this is source-traced, with no actual UI fill. Autofill and save refuse
frames the engine flags as untrusted-origin, as WebAuthn already did (source
only). Native PRF, real user presence and verification, Apple Passwords
transfers, Settings accessibility and Stage remain unverified. Removing an
unlock passkey does not rotate the vault key, so a removed passkey that still
has an older copy of the vault file can decrypt later versions; this is a
documented limit, not forward revocation.

Review corrections on the draft PR, source only and unverified natively:
WebAuthn client data is serialized in the specified order and its origin is
checked by the independent verifier; the exchange review says when replacing a
stored login removes its password; Chromium back/forward-cache restores keep
isolated-world contexts and script messages, finish navigation state and
publish correct history controls while credential contexts are still
invalidated. Merge and deploy stay blocked on the unresolved duplicate-passkey
registration policy (D1: a second registration appends instead of overwriting),
and native handoff, signing, PRF and transfer gates remain open. (Superseded
2026-10-11: the user approved the retain-all registration policy for merge/deploy
to manual testing; D1 is no longer a gate. Capability-bearing signing/provisioning
remains a deployment prerequisite.)

External-app offers from a web page no longer depend on a race with the frame
handshake: the navigation decision records the exact document nonce the
registry issued or acknowledged for the source frame and that document's own
navigation, then waits for that frame's native readiness proof of the same
nonce before the offer is shown. A cancelled in-flight navigation no longer
invalidates an offer from the already-loaded page. Pending frames are never
treated as acknowledged, and stale or replaced frames still refuse. Verified
in hosted CI on `5649bbe` (3012 tests, including all handoff, stale-frame and
back/forward-cache cases); the performance-budget step of that run failed
(0.1019 s against 0.100 s) and its cause is unresolved. On `9253f7d` (main
`a2ab7b6` merged in), run 38075169484 passed 3014 tests in 334 suites, all
budgets (start page 0.0774 s) and coverage; the same run started the built
Debug app in an isolated Stage home and drove its bundled MCP relay through
initialize, the 19-tool listing, `listTabs` and EOF. That proves app startup
and relay IPC only, not the credential UI, native user presence or
verification, or the other tools; the earlier performance failure did not
recur but was not explained.

### 2026-10-10 — Tab title test waits for the website title

The website-title removal test now waits for the page's initial title before removing it, instead of reading the tab title the moment loading settles. This is a test-readiness correction; no tab title behavior changed.

### 2026-10-10 — Fresh window registration over a retired key

Registering a browser over a retired extension-window key now retires the old entry and creates a fresh window adapter instead of returning the dead one. Consent captured for the retired window stays invalid. The MCP transport tests now unregister the extension windows they register.

### 2026-10-09 — Actual engine beside address lock

The address bar shows WK or Cr beside the lock for the active page's loaded engine.

### 2026-10-09 — Classic Keychain credential storage

Provider credentials, MCP authorization credentials, and OAuth credentials now
share the classic macOS Keychain store. Durable tombstones keep deleted
credentials from reappearing.

### 2026-10-08 — Complete Linen integration

Integrated all 31 changes from the pinned upstream range through
[PR #8](https://github.com/wsagency/wsurf/pull/8). The list follows the
[source manifest](docs/upstream-migrations.md#complete-source-manifest):

1. Detect both standalone and ChatGPT-bundled Codex CLI layouts for MCP setup,
   retaining WSurf configuration and safe TOML merging.
2. Preserve command-palette editing shortcuts across keyboard layouts.
3. Wait for focused autofill fields to finish layout before delivering input,
   with bounded waits and cancellation.
4. Stop media polling on idle players and hidden pages, including page-cache
   transitions.
5. Show PDF filenames and correct untitled-page names on WebKit and Chromium,
   without overwriting custom tab titles.
6. Remember external-app approvals per website origin and target app, with
   revocation in website settings and session-only private-window grants.
7. Save WebKit PDF viewer documents through the download manager, preserving
   edited PDF bytes, filename reservations, quarantine and handoff deduplication.
8. Open the actual Downloads page from download settings and settings search.
9. Refresh the localization catalog while retaining WSurf-only strings and
   branding.
10. Align global-reset settings copy with the string catalog.
11. Stabilize assistant context test titles while pages load and retain fixture
    servers for their full lifetime.
12. Test external navigation with real WebKit actions and requesting origins
    rather than fabricated navigation objects.
13. Measure result-ranking performance independently of WebKit page loading,
    retaining WSurf performance budgets.
14. Restore saved scroll positions after late WebKit resets; stop restoration
    when the user scrolls, the page moves itself or the document is left.
15. Wait for extension test replies from the expected page instead of accepting
    unrelated responses.
16. Keep headless automation fixtures active without changing production page
    scheduling.
17. Confirm assistant key delivery on trusted keydown, avoiding duplicate input
    when a page consumes keyup.
18. Move native CI to Xcode 27, refresh CI actions and SwiftLint, and upgrade
    AnyLanguageModel to 0.15.1 and swift-collections to 1.7.1. Keep CefSwift pinned
    and enforce locked package resolution.
19. Update README behavior and privacy documentation for WSurf.
20. Install and verify the Metal toolchain before release and preview builds,
    retaining the existing CI setup and deployment gates.
21. Support CPU fallback for OCR and active autofill fixtures on virtual macOS
    runners.
22. Exclude only four unsupported Vision OCR integration tests from hosted CI;
    keep all four enabled in native Pro verification.
23. Improve gray folder-preview icon contrast in dark mode while retaining
    colored folders.
24. Accept object-valued MCP experimental capabilities during initialization
    without changing standard fields or permission grants.
25. Add profile-aware browser windows, live same-profile tab transfer and
    isolated private sessions on both WebKit and Chromium. Bind assistant,
    MCP and extension operations to their owning window, profile and document.
26. Show assistant questions only in the window, space and surface where the
    request began.
27. Fill up to 32 controls per guarded assistant or MCP operation without
    submitting the form. Add bounded rate-limit recovery, pause/Continue and
    visual no-progress detection without replaying completed actions.
28. Reduce idle work and correct startup behavior: event-driven MCP stdio,
    cached speech preparation, visible-playing synchronized lyrics, validated
    media geometry, URL-correct favicons, privacy-safe autofill diagnostics and
    engine-aware page-resource cleanup.
29. Keep sidebar drop targets visible on light websites using the sidebar's own
    appearance.
30. Add Tab-to-search site chips with native editor safeguards and adaptive
    command-palette sizing.
31. Limit Window/Dock page-title labels to 40 grapheme clusters, retaining full
    stored titles and profile/private suffixes.

WSurf compatibility work preserves Favorites, pinned tabs and folders, sidebar
Undo/Redo, split panes and per-website engine selection. History clearing removes
only the owning profile's conversation log; link previews retain that profile's
JavaScript settings. External-app decisions remain bound to live source
documents, with one-time consent for ambiguous or opaque sources. Stage runs can
retain restored sessions with `WSURF_STAGE_SEED=0` without disabling isolation.

Native Pro verification recorded 3,016 passing tests and no failures, including
the four OCR integrations. PR and merged-main CI passed. The
[migration journal](docs/upstream-migrations.md) and
[integration record](https://github.com/wsagency/wsurf/pull/8#issuecomment-6067821179)
separate observed checks from the remaining manual UI checks accepted by the
user. This entry records source integration, not a signed public release.

### Earlier WSurf changes

- Added repository-local omp worktree placement and documented feature-branch,
  PR-only changes to `main`.
- Independent WSurf product, app/project/module and `io.wsagency.wsurf`
  identity, with separate data/defaults and new wave artwork.
- Preserves Apache-2.0 provenance and third-party notices; does not reuse
  the upstream publisher's signing or update keys.
- Extension popup/background, live tab metadata, persistent Apple client
  compatibility and native context cleanup changes pass 35 scoped regressions.
- Local ad-hoc build launches with the WSurf icon/onboarding and loads HTTPS
  pages; restricted browser entitlements are not enabled in this UI smoke.
- Seven update payload/state/layout behavior checks pass. Removed inherited
  wording and configuration-copy assertions rather than pinning new branding.
- Fixed strict SwiftLint header/import/collection/line-length violations.
  The compiled Apple public key still derives the official extension ID.
- Builds extension ZIP test fixtures on the concurrent executor, avoiding
  MainActor Process run-loop reentrancy during WebKit teardown while retaining
  invalid-package and cleanup assertions.
- Extension package extraction also runs off MainActor, with per-library
  serialization so installs cannot overlap writes to the same staging paths.
- Extension controller web views now reuse the browser's pooled configuration,
  preserving the controller's website data store while avoiding process-pool
  destruction during pending IPC callbacks.
- Stable controls receive at least two readiness samples even when the first
  WebKit query is cold; stale, disabled, animated and permission checks remain.
- Repeated or late handoffs of the same native download no longer create
  duplicate transfers. Separate requests for the same URL remain independent.
- Sidebar appearance now includes installed font families, size, weight,
  compact row spacing, and adjustable folder tint. Folder and link labels use
  primary text contrast; expanded folders no longer stack tinted glass.
- Unpinned sidebar X now removes the tab and link; ⌘-click unloads instead.
  Pinned controls unload or load by default and remove with ⌘. Removed the
  obsolete unloaded-tab-action preference; context menus retain explicit actions.
- Added per-profile, icon-only Favorites without duplicate sidebar rows.
  Favorites never auto-sleep, support manual unload, and return to ordinary pins
  when removed from Favorites.
- New Folder and Move to Folder › New Folder reveal and focus inline rename,
  including icons-only mode.
- Native sidebar Undo/Redo restores deleted folders and removed links, including
  names, tree positions, pins, and split panes. ⌘Z and Ctrl-Z preserve text Undo.
- Themes now preview brightness, hue, and a primary-derived palette live, with
  independent control-icon and URL-text colors/opacity, per-theme storage and reset.
- Folder context menus now offer independent Pin/Unpin, including empty
  folders. Pin state and sidebar order persist without changing child bookmarks.
  Fixed context-menu hit testing for folder rows away from the top.
  Child reordering preserves each bookmark; Delete Folder and Move Out keep
  the root pinned section contiguous without changing child bookmarks.
- Initial icon markup no longer invalidates locally cached favicons on every
  navigation. The icon watcher starts after the initial DOM is ready and still
  refreshes icons when the page changes them later.
- Added pastel Light Calm and Dark Calm themes. Light Calm uses a deeper muted
  palette; Calm chrome stays light or dark independently of the website.
- Loaded and unloaded sidebar text/icon colors and opacity persist separately
  for each theme, defaulting to black on light surfaces and white on dark ones.
  Favicons keep their original glyph in monochrome without an unloaded badge.
- Sidebar and folder controls use X only for removal, the curved-down arrow
  only for unload, and Play only for load. Folder unload retains descendant
  links, pins, hierarchy, and existing unload protections.
- Added the dependency-free `wsurf.app/` website and public `webcredentials`
  association for the configured WSurf release identity. Includes responsive
  source/build links, upstream attribution, and deployment requirements;
  no signing secrets or vault data are hosted.
- Move to Folder now follows the sidebar hierarchy instead of listing every
  folder at the first level. Nested menus include Move Here for the parent
  folder and keep invalid self/descendant destinations out of folder moves.
- Added assets-only Cloudflare hosting for `wsurf.app/` with an exact JSON MIME
  override for the hidden association file. Restricted Worker-only deployment
  and public anonymous HTTPS GET/HEAD checks pass with the unchanged app
  identity and domain/DNS binding. The sole GitHub Actions path waits for
  successful CI on the exact PR-merged main SHA and skips superseded commits;
  no PR/fork/tag deploy, account-wide token, DNS grant, native Workers Builds
  connection, or GitHub App grant.
- Added omp.sh to external MCP clients, with automatic CLI detection and setup
  in `~/.omp/agent/mcp.json` using the existing safe JSON merge and backup.
- Added per-website WebKit/Chromium selection with lazy embedded CEF startup,
  separate engine website data, and profile-specific preferences.
- Fixed native Chromium initial navigation, IO-thread tracker policy isolation,
  canonical cache paths, and child-view teardown without closing the app window.
  Native accessibility is enabled; CEF errors remain on standard error without
  a persistent debug log file.
- Engine changes reload rather than replaying submitted requests. Chromium
  unloads restore the URL; WebKit extensions and native Picture in Picture remain
  WebKit-only.
- The WebKit autofill navigation adapter reads the source frame only for a form
  submission, rather than eagerly reading it for unrelated navigation kinds.
- Existing folder pins migrate without changing child bookmark identities.
- Assistant input now targets the verified native page responder. Chromium text
  uses browser-native input; trusted event receipts and sensitive-field checks
  remain in force.
- Engine replacement releases the old page's media-dock ownership. Native
  Picture in Picture return guards and hover shielding remain engine-aware.
- Chromium file dialogs use native content types for MIME and extension filters,
  and request-handler ownership is synchronized with in-flight shutdown.
- WebKit download callbacks acquire their delegates before yielding, including
  resumed transfers. Assistant key presses finish their native press/release
  pair before awaiting the select-all fallback.
- Assistant input makes a final fresh trusted-event receipt check at the polling
  deadline, so a wait or delayed IPC reply does not discard a delivered event.
- Command-palette projection reuses its ranked command matches for promotion
  instead of scoring the full catalog twice; ordering and performance budgets
  remain unchanged.

No signed WSurf release has been published yet. Apple Passwords compatibility
changes are present in source and fixtures, but real PIN, fill, save, OTP,
15-minute idle, lock, and sleep behavior remains unverified in an own signed
build.

## Upstream Linen history

## 0.7.1

### New

- New Tab opens the command palette. Enter an address or search, then choose
  a result to create the tab. Choose Open Start Page to open the start page.
- The assistant can drag and double-click on pages, interact with embedded
  pages, upload files you select, and check downloads. Page permissions apply.

### Improved

- The assistant checks page and download results before marking a task complete
  and reports outcomes it cannot verify.
- Pages opened by the assistant appear in the active tab so you can follow
  its work.
- Conversation context limits now account for the selected provider and model.
- Settings search opens the relevant page and highlights the matching control,
  including controls within OpenAI settings.
- Sleeping tabs release more memory. Reloading can recover pages whose browser
  process has stopped responding.

### Fixed

- The assistant retries temporary provider failures without repeating browser
  actions that already ran.
- Voice configuration uses the provider you selected.
- Moving the pointer over command palette suggestions no longer replaces
  what you typed.
- Autofill can reuse a recent authentication on the same page. It asks again
  after you navigate or switch profiles.
- Writing fields that mention an email address or name no longer trigger
  contact autofill suggestions.
- Repaired update sources for older Firefox extension installations and fixed
  compatibility with extension icons and keyboard shortcuts.
- Certificate checks no longer hang the browser.
- The address bar loading indicator feels smoother when loading the page.

### Removed

- The OpenAI document-search library. You can still attach files to messages.
- The blank-page and custom-homepage options for new tabs.

## 0.7.0

### New

- Save and fill passwords, payment cards, and contact details. Manage saved
  entries in Settings > Autofill. Passwords and cards require system
  authentication. You can also use a password manager extension.
- Attach images, PDFs, and text files to assistant messages.
- Have a voice conversation with the assistant through OpenAI. Choose a voice
  in assistant settings, interrupt a reply, and review the conversation in chat.
- Use OpenAI models to search the web, create images, and work with data.
  Supported tools are available automatically. OpenAI usage charges apply.
- Connect external services to the OpenAI assistant through MCP.
- Use the assistant's page screenshot, pointer, and keyboard tools to interact
  with a page. Browser control requires your permission.
- Connect an external assistant to Linen through its MCP server. Share selected
  tabs with read-only access or permission to control them. Setup is available
  for Codex, Claude Desktop, Claude Code, and Cursor.

### Improved

- The assistant saves progress so you can continue interrupted tasks. It checks
  uncertain actions before retrying them and pauses when it keeps getting stuck.
- Long conversations can compact their working context automatically or on
  demand. A context indicator shows estimated usage.
- Assistant activity now shows progress updates and groups completed work.
- OpenAI settings have separate pages for voice, connections, and privacy
  settings. Advanced options are under Developer Settings.
- Collapse a Peek preview and reopen it without losing the page.
- Use the arrow keys in the address field to preview a suggested address before
  opening it.
- Website icons stay readable against light and dark backgrounds. New settings
  default to website tint and tab color effects.
- Website permission controls and download progress are easier to read.
- Diagnostic logs omit page content, conversation text, and raw provider errors.

### Fixed

- Page commands now act on the visible Peek preview.
- Updating a pinned page no longer moves it within the sidebar.
- Starting a new tab no longer shows a loading state for its background warm-up.

## 0.6.1

### New

- Right-click a link for Open Link in Peek and Summarize Link.
- Sign in to websites with a passkey.

### Improved

- Moving tabs, folders and tab pinning in the sidebar is clearer.
- The assistant shows the same thinking mark in the side panel and on the
  summary card.

### Fixed

- Linen could quit unexpectedly when a website stopped responding.
- With the side panel open, the page ignored the pointer.

### Removed

- Intel Macs. Linen needs a Mac with Apple silicon.
- Dropping a tab on another tab no longer makes a folder. Use New Folder, or
  the tab’s menu.

## 0.6.0

### New

- Hold Shift over a link to see a summary before opening it.
- Shift-click a link to open it in a panel over the page. Keep it as a tab,
  or press Escape to close it.
- Rename a tab: click the name of the tab you are on, or choose Rename in its
  menu.
- Drag a tab into the pinned section to pin it, and out of it to unpin it.
- Choose what a website may auto-play, and what its pop-ups do, in Website
  Settings.
- Setup offers a few extensions to add.

### Improved

- Bookmarks are now called pins.
- Each provider keeps its own Thinking setting.
- Assistant settings are now grouped by model, behavior and permissions.
- The link address at the bottom of the page says what a ⌘-click or a ⇧-click
  does.
- Extensions activate when you open a supported website.

### Fixed

- A dark website flashed white as it opened.

## 0.5.0

### New

- Extensions install from Firefox Add-ons as well as the Chrome Web Store.
- Extensions can now exchange messages with a companion app on your Mac.
- Middle-click a link to open it in a new tab.
- Point at a link to see its address at the bottom of the page.
- Settings, History and Downloads open in a tab of their own.
- Turn Automatic Picture in Picture off for one website, in **Settings >
  Websites** or in Website Settings in the toolbar.
- Minimizing the window sends a playing video to Picture in Picture, as
  leaving its tab already did.

### Improved

- Address bar suggestions favor the pages you visit most and most recently.
- History gathers a day’s repeat visits to one page into a single entry.
- Open a history entry in a new tab with a middle-click or a ⌘-click.
- Picture in Picture now works on websites that used to refuse it.
- Tracker blocking says when a page refers to no known trackers, instead of
  showing an empty list.
- The Liquid Glass window style is now called Transparent.
- Website Controls in the toolbar is now Website Settings.

### Fixed

- The toolbar took the color of the page you were opening before that page
  appeared, so it changed color twice.
- A link to a tracker domain did not open. Only the requests a page makes in
  the background are blocked.
- Turning a Safari extension off in the toolbar menu took it off the list
  instead of disabling it.
- A tab stayed marked as muted after the page unmuted itself.
- Linen did not come forward when you sent the floating video back to its tab.
- A new tab opened from a bookmarked tab landed among the bookmarked ones,
  instead of below them.
- In the release notes, the line after a list ran into the last bullet above
  it.

## 0.4.2

### Improved

- Bookmarked tabs stay at the top of the sidebar. A new tab now opens below
  them instead of pushing them down, and a line separates the two groups.
- Linen asks before you close a bookmarked tab, because the bookmark closes
  with it.
- Back to Bookmarked Page is now ⇧⌘D. macOS keeps ⌥⌘D for the Dock.
- Control-click empty space in the sidebar for New Tab, New Folder and
  Organize Tabs.
- The sidebar and the toolbar take much more color from the website you are
  reading when **Settings > Appearance > Website tint** is enabled.
- Hover highlights now adapt to the website tint for visibility on dark and
  light websites.

### Fixed

- Dragging inside the address field moved the window, so you could not select
  the address.
- The update notice stayed hidden while Settings was open.
- The top of a chat faded out even with nothing scrolled above it.
- The dots on the split view handle took the accent color on the pane you were
  using, instead of staying white.

## 0.4.1

### Improved

- History, Settings and Downloads now open in the tab you are using, like a
  normal web page.
- The assistant chat now names the website it is reading, such as “Ask about the
  GitHub page”.
- The assistant can now show tables in its answers.
- The media player title now uses the full width. Its buttons fade in over the
  end of the title when you point at the player, so the title no longer moves.
- When more than one tab is playing, a new button in the media player opens a
  list of them.
- The loading bar now runs the full width of the page.
- The selected thinking level now appears beside the Thinking heading.
- Hide Browser has gone from the View menu. ⌘H hides Linen and ⌘W closes the
  window, as in any Mac app.
- “Report a bug” is now “Send feedback”.

### Fixed

- The window disappeared from your desktop when you swiped back from a
  full-screen app, and another app came to the front.
- The assistant reading a page turned JavaScript back on in every tab, even
  with JavaScript turned off in Settings.
- Back from History closed the tab when you had opened History from the start
  page.

## 0.4.0

### New

- The side panel is now a chat with the assistant, and each tab keeps its own
  thread. Choose the provider, model and reasoning level below the message field.
- The assistant can ask for clarification. Answer it, skip
  the question, or let the assistant choose.
- Type `@` in the panel to attach another tab to your question.
- Answers arrive formatted. Copy one, hear it read aloud, ask it again, or edit
  your message and send it back.
- Thinking offers only the levels your model supports, including Minimal.
- Apple Intelligence answers stream in as they are written.
- Settings, History, Downloads, Release Notes and new tabs have addresses, so
  Back and Forward work with them.
- Suggestions on the start page are a section you can move or turn off.
- Settings > Extensions lists the Safari extensions on your Mac, and each
  profile keeps its own.
- Settings > Advanced > Feature flags lists WebKit feature flags,
  with search and a reset.
- Extensions from the Chrome Web Store update themselves once a day. Check for
  Updates in an extension’s menu checks right away, and an update that asks for
  more access waits for you.
- Your downloads stay in the list after you quit. Settings > Downloads decides
  when the list empties.

### Improved

- Switching profiles is five to eight times faster.
- Restored background tabs load only when opened, reducing startup time for
  large sessions.
- The profile switcher opens beside its button in the sidebar, and every profile
  icon is a circle.
- The downloads button is always in the sidebar, and a file you download flies
  from where you clicked it into the button.
- Settings is built from one set of rows. Nothing lights up under the pointer,
  every card shares a surface, and anything that opens a page is a row with a
  chevron rather than a button.
- A setting that is off because another setting is off tells you which one, and
  takes you there.
- Block known trackers moved to Settings > Privacy.
- Keep loaded for a website is now Keep this website awake.
- Each settings page keeps its own action, such as Reset, Remove All or Delete
  Profile, next to the button that takes you back.
- The media player fits the sidebar. Its controls appear when you point at it,
  and the title takes the room they leave.
- A side panel conversation stays out of the address field.
- Tab previews cover folders, split panes and Linen’s own pages.
- Settings pages fit a narrow window.
- Folder colors are less saturated, and folder menus use the same colors.
- The split view’s drag pill matches the sidebar and side panel pills.
- Website Settings is off on Linen’s own pages.
- Linen checks for updates in place, and again after finding one.
- Extensions tell you when WebKit cannot run them.

### Fixed

- A website could open one of Linen’s own pages by asking for a `linen:`
  address.
- Signing in to a Mac app from a website did nothing.
- Read aloud stayed silent while spoken replies were muted.
- Release notes broke wrapped lines apart.
- The window moved while you dragged a button in the toolbar.
- Space did not reach the page.
- Sidebar rows sat at different distances from the edge.
- Placeholder text jumped when a search field took focus.
- The downloads button stayed selected after you opened downloads.
- Live streams showed an unusable playback slider and lyrics button.
- The media player kept a picture from a page you had left.
- A tab could display the color of another website’s icon.
- The address bar showed nothing while it checked a connection.

## 0.3.1

### New

- Window style in Settings > Appearance sets how the toolbar and the sidebar are
  displayed. Standard uses an opaque background; Liquid Glass uses a
  translucent one. Glass transparency offers Clear to show more of the desktop
  and Tinted for stronger text and control contrast.

### Improved

- Match website color is now Website tint, and Refract tab color is now Tint
  selected tab. Both are off by default.
- Appearance now comes before Search in Settings.

### Fixed

- The pages you had open in one profile were added to another profile’s history
  when you switched profiles.
- Files you downloaded in a private tab stayed in your downloads after private
  browsing ended. A download that is still going now stops when you leave
  private browsing.
- A website’s icon could be saved in the wrong profile.
- The assistant still remembered what you asked it in the profile you left.

## 0.3.0

### New

- Linen uses Liquid Glass, with translucent backgrounds for the page, sidebar,
  side panel and Settings.
- The window uses a tint from the current website. Turn off
  Match website color in Settings > Appearance to keep Linen’s usual Light or
  Dark theme instead.
- Turn on Refract tab color in Settings > Appearance, and the selected tab takes
  on the color of that website’s icon.
- The theme picker shows you what Light, Dark and Auto look like before you
  choose.
- Linen restores open tabs when you launch the app.
- Sleep inactive tabs in Settings > General frees memory when your Mac runs low.
  It is off by default.
- The address field is now on every page, including a new tab.
- Website Settings is now a compact panel. It holds page zoom, assistant access,
  tracker blocking, and the camera, microphone, location and notification
  choices for the website you are on, and its tracker details show which known
  tracker domains Linen found on the page.

### Improved

- Type `@` in the address field to point the assistant at one of your tabs. The
  list of tabs opens as soon as you type it, with your question at the top.
- You can make the window much narrower, and websites switch to their compact
  layouts when you do.
- Tabs slide behind the top of the sidebar instead of fading away.
- The side panel shows a music note only when lyrics are available.
- The edges you drag to resize the sidebar and the side panel are easier to see.
- Settings uses lighter shadows and less prominent highlights.
- Removing an extension is now a button in a menu beside it, along with that
  extension’s own settings.

### Fixed

- Scrolling the sidebar or the side panel could reload the page behind it.
- Pointing at the side panel could highlight things on the page underneath.
- Dragging an extension button moved the whole window.
- The address field applied autocorrection to web addresses. It now preserves
  what you type.
- Tabs selected with `@` could return blank content.
- A new tab said the assistant could read it.
- Text in the toolbar was hard to read on some websites.
- An answer from the assistant appeared behind the side panel.
- A tab’s title moved when it started playing sound.
- The color of the window changed a moment after you picked a tab.
- Some dark websites left the window light, and some did not color the window
  until you reloaded them.
- ⌘← and ⌘→ went back or forward while you were editing the address field
  instead of moving through its text.
- Website Settings could be difficult to read over a busy or dark page.

## 0.2.0

### New

- Linen shows synced lyrics for the current song. Open them from the media
  player, from View > Show Lyrics, or with ⌥⌘Y. Adjust text size and timing,
  or choose a different match. Only the song and artist names leave your Mac, and
  never from a private tab. Turn this off in Settings > General.
- Activity and Lyrics now share one panel on the right. One button in the
  toolbar opens it, and the arrows widen it to fill the window.
- A button in the address field sends the video you are watching to a floating
  window. Turn on Automatic Picture in Picture in Settings > General and the
  video opens in Picture in Picture when you leave the tab and returns when
  you reopen it.
- The media player follows whichever tab is playing, so you can pause or skip
  from anywhere.
- Settings > Experiments contains features in development. They may change or
  be removed.
- Import bookmarks from another browser. Export a bookmarks file from
  Safari, Chrome, Firefox or Edge, then choose it in Settings > General.
- Save Page As… and Print Page… are in the menu you get when you right-click a
  page.
- A link that opens in its own tab now lands below the tab it came from.

### Improved

- Read aloud and Push to talk moved to Settings > Assistant, beside everything
  else about the assistant.
- Closing a tab takes you to the one below it.
- Menus mark what you chose the way the rest of the Mac does.

### Fixed

- The media player kept showing a track that had stopped.
- Settings and History slid in when they had not moved.

## 0.1.1

### New

- Settings > About lets you follow Preview builds instead of waiting for the
  next release. You can go back to Release at any time.
- Install in the update banner downloads and installs the update without a
  second confirmation.
- The notes for a new version open in a tab after it arrives. To read them
  again, choose Linen > Release Notes.
- ⌃⇥ returns you to your last tab, the way ⌘⇥ returns you to your last app. Hold
  ⌃ and press ⇥ to select the next tab, or ⇧⇥ to select the previous tab.
- Click the orb and talk. Linen sends what you said once you stop. Click the orb
  again while the assistant is working to stop it.
- In the command palette, ⌘↩ asks the assistant about what you typed, and ⇧↩
  searches in a new tab.

### Improved

- The assistant can continue long conversations that exceed its context limit.

### Fixed

- A pasted link brought its styling into the address field.
- A tab kept spinning after going back.
- The scroll wheel moved the page behind the command palette.

## 0.1.0

First release. Linen is a browser for macOS 26 and later.

### The assistant

- The assistant works in the tabs you already have open. It searches, opens
  websites, reads them, clicks, types and scrolls.
- Ask in the address field, or hold ⌥Space and speak. Click the page to stop the
  assistant and use it yourself.
- It asks you first before it buys, sends or signs in, and never fills in a
  password or a card number.

### Models

- Apple Intelligence runs on your Mac without an API key.
- Or add your own key for OpenAI, Anthropic, Gemini, DeepSeek, Groq, Mistral,
  OpenRouter or xAI.
- Or connect Linen to a local server, such as Ollama or LM Studio.

### The browser

- Tabs, folders, pinned tabs and split view.
- Profiles and private browsing.
- A command palette, history and find in page.
- Downloads that resume, and zoom you set for each website.
- Extensions from the Chrome Web Store.

### Before you start

- This is an early release. What Linen saves to disk can still change between
  versions.
- Linen opens one window at a time, and does not yet fill in passwords or show
  web notifications. See the README for limitations.
