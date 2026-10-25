<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Browser autofill

`AutofillPage` installs one model and focus bridge in the `WSurfAutofill`
isolated content world, once per content controller, in every frame. Password,
card, contact, and save clients share that model. No autofill UI is inserted into
the document and this form bridge exposes no credential API to the page. The
separate page-world WebAuthn API is described under Credential Manager.

## Form model

`AutofillFormScript` owns document, form, and field identities, semantic field
classification, section ownership, and bounded DOM/open-shadow-root discovery.
Native form ownership and `form` attributes take precedence. Unowned controls
get synthetic groups from their structure; nested component groups normalize
to consistent ownership. Standalone fields do not require a submit button.
Mutation and focus notifications invalidate cached structure. Field values are
not part of the structural cache.

The category and field kind used to offer/fill a record are also used to capture
it. `autocomplete` takes precedence over label heuristics. Login usernames are
classified with their password group, so contact filling cannot claim them. An
identifier-first step is a username too: the one fillable field of a group with
no password, an email or user-ID field without a declared `autocomplete`
purpose and without newsletter or search wording. A lone newsletter field
without such wording is then offered logins instead of contact details.
Hidden/disabled controls cannot be filled. An explicit hidden username belonging
to a native form can supply account metadata for saving a multipage login.

## Suggestion presentation

Focus and click share a field token, so native code reuses pending lookups and
visible panels. Empty or failed lookups remain silent. DOM mutations can dismiss
a disconnected target but never open suggestions or trigger metadata lookups.
Only a visible, populated panel runs the geometry watcher; ownership, policy and
origin are still revalidated before presentation and around authenticated filling.
Typing or dismissal requires another focus/click interaction to reopen the panel.
Any dismissal ends the interaction, also one WSurf makes itself (Escape, a click
elsewhere, another window, a lookup that found nothing): the next focus or click
on the same field, which the page script reports with the same field token,
starts a new lookup instead of being taken for the old one.

A password or verification-code list holds only accounts saved for the page's
exact origin. When it would be empty but an unlocked vault holds accounts (for
a code field: codes) for another HTTPS website of the same registrable domain
(public-suffix aware, so `a.github.io` and `b.github.io` are not related, and a
look-alike domain never is), the panel shows one row, "Check other logins for
*.example.com". Choosing it lists those accounts, each with the website it is
saved for. Only titles and websites are shown; the chosen account's secret or
fresh code is read again at delivery and filled exactly like a normal choice.

After such a fill (a code too), and when a submitted login repeats one saved for a sibling
website exactly (username and password) while nothing for the page has that
username, the address-bar popover offers "Add login.example.com to “ada”?"
instead of saving a copy. When several sibling credentials repeat the login, only
the one just filled is offered. The offer holds no secret. Only Add Website writes,
under the unlock it was offered under, through the vault's ordinary commit, so
History keeps the earlier list of websites. A credential that already has 64
websites is never widened, and Not Now is remembered for the page.

When the profile has vaults and every one is locked, a login field gets one
row, "Unlock Credentials…". Nothing is read before the unlock. Choosing the row
closes the panel and unlocks through the ordinary passkey unlock (asking which
vault when there are several), then looks up the same field again. A lock,
profile switch or a new field while the vault choice is open unlocks nothing.
The unlock starts the vault's own lease and never extends one.

A card or address field lists the cards and addresses of the profile's unlocked credential vaults (and, until the person confirms
their move into the vault, the ones still in the old Keychain lists). A row shows only a card's network and last four digits, or a
contact's title; the credential's item is read again on the pick under the same unlock, revision and write generation, and a card
fills only after Touch ID or the Mac password. Contacts and addresses need only the unlocked vault. While every vault of the profile
is locked, the field gets one "Unlock Credentials…" row, as a login field does; nothing is read before the unlock. A credential's
first address, first name and its custom fields with the ids `email` and `organization` fill as one contact; a card whose number
fails the card check, or that has expired, is not offered. No card or address at all is offered in a tab the assistant or a
connected app controls (`BrowserTab.isUnderAssistantControl`), so none is filled into a page an agent reads.

Saving a typed card or address goes through the save offer, like a password: only Save writes, as a new entry (or, for a card an
unlocked vault holds with other details, an update of its card item) in the vault the offer read, else the default vault, chosen and
unlocked on Save when needed. A tab under assistant control is offered nothing. The old Keychain card and contact lists and the card
and contact rows of the save index are never written again: the Vault tab's "Cards and addresses saved on this Mac" card moves them
(`AutofillVaultMigration`). Review reads them, Move to Vault writes what the vault lacks in one commit (cause `autofill-migration`)
and compares every entry with its old copy, Undo moves those entries to Trash, and only Erase Old Copies…, after a confirmation that
names the counts, erases both Keychain items and the rows, and checks that nothing is left.

Import & Export on the Settings tab imports payment cards from a Safari export (its ZIP or PaymentCards.json) and contacts chosen in
Contacts (every contact clicked while the picker is open, each once), into the open vault only: a review lists titles only, Import
writes what the vault lacks in one commit, and the notice offers Undo. A vault that changed since the review writes nothing. With no vault yet, the rows offer Create Vault…; with a locked
one they stay off. Imported cards follow the vault's Touch ID rules.

A field whose autocomplete includes `webauthn` also gets "Use a Passkey…" while
its document has a pending conditional passkey request, whatever the vault
holds, whether it is locked, or whether there is one. Only choosing that row
starts the passkey sheets. A click, Enter or an arrow key in the field never
does, and Enter reaches the page.

Any other unlock (Settings, a save offer, a passkey sheet) asks the page script
of a login field that is still selected, on a page that can show a panel, to
select it again, and that field's logins are offered without another click.
A field whose panel is open or being filled is left alone.

## Submission lifecycle

`AutofillSaveScript` tracks trusted edits and separates an attempt from evidence
of completion. Submit events, Enter, and structural action controls stage an
attempt without inspecting their wording. So does any other trusted click inside
the one form being filled in (a styled `div`, or a link that stays on the page:
`#`, a fragment, `javascript:`), except a click into a field. A link to another
document abandons the capture. Values an extension or the page filled count when
a trusted click or Enter follows within 1.5 seconds; for a plain click that is
true of passwords only. Only the fields a snapshot was read from can veto a
submit as invalid, so an empty captcha or terms box does not. A form with
an empty or `javascript:` action is safe. Any other action, `#x` included, is
resolved against the document's base and must stay on the page's origin, and a
page whose `<base>` is on another origin is never safe. So is a form with any submit
button (also one joined by `form="id"`) whose `formaction` leaves the origin. Of
several account fields the one before the first password is used, and two
unlabelled passwords that differ are an old and a new one unless the second asks
to confirm. Form disappearance covers SPA and automatic submission. A
replacement password field, a disabled form, or a recognized verification-code
step delays completion. Snapshots and attempts are bounded and expire after two
minutes, or five once a verification step has been shown.

The script's test hooks (`__test`, and plain HTTP so a loopback fixture can load
it) exist only when `AppDatabase.isRunningTests` is true; `client(testHooks: false)`
is what ships.

`AutofillSubmissionTracker` retains pending candidates in the tab's memory across
navigation. It checks registered frame reports for a settled new document or a
removed login frame before requesting the native save UI. Ordinary browser
navigation, HTTP errors, genuine navigation failures, profile changes, locking,
and policy changes discard pending state. Canceled redirects can continue the
flow. Username steps are restricted to their HTTPS origin and expire after five
minutes. A native address-bar popover presents the pending offer without changing
page layout. Closing it keeps the offer available from its icon until expiry or
explicit dismissal. A login that repeats the account just filled in the tab is
compared with that account in its own vault, also when other unlocked vaults
hold the same username, so it is not offered again. Only explicit Save/Update
writes a candidate to its store: a password, a card or an address goes to
Credential Manager. A profile with no vault gets one offer per run
of the app to set one up, and nothing is saved by it.

Native code binds messages to the WebKit or CEF frame identity and origin.
Filling additionally checks the document/form/field identity, selection token,
focus, geometry, and policy before and after authentication. A new document at
the same URL is still a different document. The page spends the selection token
on the fill it takes, so a delivered fill is never checked against that token
again or reported as failed; the pick is recorded while the request still holds
its native authority.

Each frame is sent its autofill policy when its script reports ready. A refused
call is tried once more after 300 ms, with the policy read again, so a document
that was still starting does not keep autofill off.

Diagnostics contain static event names/counts only.

## Credential Manager

Credential Manager is the only built-in password store. Source behavior, not
exercised end to end:

- Every request is scoped by the originating page's native context: its
  profile, document, origin and the vault authorization epoch, on WebKit and
  CEF. A stale epoch or document is refused.
- The vault lock is shared per profile. Any window leaving the profile locks all
  of its windows. Private browsing has no Credential Manager.
- The user picks the account; nothing is chosen automatically. A chosen
  account's password or one-time code is read again at delivery.
- An installed password extension can still act until the user turns it off;
  Settings warns about it.
- Passwords saved by earlier builds are imported once through the reviewed
  import on the Settings tab of Settings › Autofill. The Keychain list is
  read only after the user chooses Review, and erased only after a successful
  import and an explicit confirmation that names every password the vault does
  not hold. Detection at launch asks the Keychain whether the list exists and
  reads nothing. Nothing writes that list any more; private windows never touch
  it. Sites excluded with "Never for This Site" in the old list were stored as
  one-way digests and cannot be moved, so those sites are offered again.
- WebAuthn is a separate page-world adapter. It returns standard WebAuthn
  results to the page and never exposes a private key or seed. In a normal tab
  every passkey request is shown to the user first, in the same words whether
  the profile has a vault, a passkey for the site, or neither, so the page
  cannot tell. The sheet offers Credential Manager and "Use Another Device or
  Key…", which hands the same request to the system's authenticator (passkeys
  in Apple Passwords, a phone, a security key). Nothing is handed over unless
  the user chooses that. Private tabs use the system's authenticator directly.
  The vault's own unlock passkey (relying party wsurf.app) is a separate
  native ceremony and is not part of this.

### Pick Credential…

When the automatic offer does not open, a right-click on an editable field
offers "Pick Credential…" (`CredentialPicker`, both engines). It is never
offered in a private window, while password autofill is off, on a page that is
not a secure HTTPS page, on an internal page, or in a tab the assistant or a
connected app controls; every step asks again.

- The field is the one the frame's own script saw a trusted contextmenu event
  on (`__wsurfPasswords`, action `context`), in the frame the engine reported.
  A later right-click replaces it; a right-click on anything else forgets it.
- A locked profile is unlocked through the ordinary unlock first. The sheet
  lists logins and verification codes of the unlocked vaults, this website's
  (and its siblings') first; titles, usernames and websites only.
- The chosen entry is read again under the unlock and revision it was listed
  under. The fill goes to the right-clicked field and its partner in that
  frame only, once, and only if its form sends to the same site: a login fills
  the username and, only into a password field, the password; a code goes into
  the field, or into exactly the boxes of a split code, from the first. The
  sheet closes when the vault locks or the autofill policy changes.
- Used on a website it is not saved for, the entry is offered that website
  (the website popover, "Use … on …?"). Accepting is one vault commit with the
  `add-website` cause, one History version; declining stores nothing. A page
  that imitates one of the entry's websites (`WebsiteLookalike`) is named in the
  popover and "Not Now" is the default.

## Input History

Input History (`WSurf/Web/InputHistory`, the Input History section of Settings › Autofill › Vault)
keeps what the person typed so a password that was never saved can be found
again. It is off by default. Source behavior:

- The recorder script runs in the `WSurfAutofill` world, counts only trusted
  input, and sends a field's last typed value on blur, Enter, submit, page hide
  or 1.5 s idle. Native code checks each message again: profile, switch,
  session owner, frame origin, exclusions, kind, sizes and card numbers.
- Never recorded: private profiles, excluded hosts and their subdomains, card,
  security code, expiry and one-time-code fields, Luhn-valid numbers,
  `contenteditable`, values set by script or autofill, and any tab while the
  assistant or a connected app controls it (`BrowserTab.isUnderAssistantControl`).
- Each entry is one file sealed with HPKE to a per-profile public key, so
  recording never prompts and cannot read back. The private key needs Touch ID
  or the Mac password. Files are excluded from backup and never synced; both
  keys are deleted when the store empties.
- Once the profile has a vault, Input History is kept with it, as a
  vault-keyed inbox outside the vault's records (no History, Trash or export).
  The first opening with the default vault unlocked binds it: an inbox key,
  sealed under `HKDF(DEK, "wsurf.input-history.v2|profile|vault")`
  (`ProfileVaultStore.inputHistoryKey`), and the private key resealed to that
  inbox, checked before and after the write (the raw key is put back on any
  failure). From then on, opening needs that vault unlocked plus Touch ID, and
  recording still never prompts, also while the vault is locked. Deleting the
  vault deletes the entries; Delete Vault names them first.
- "Keep Input History in this vault" (the Input History section, for the vault
  the page's picker shows) moves it to another vault: with both vaults
  unlocked, the inbox key is sealed again under the target's key
  (`InputHistoryStore.keep(with:from:)`). The private key, the entries and
  Touch ID are untouched; the new binding is read back and opened before it
  counts, and the old one is written back on any failure. Not bound yet, the
  chosen vault is bound at once and today's key moves at the next opening.
- The list decrypts only on Show Entries, masks passwords until one row is
  revealed, copies with the concealed pasteboard type for 60 s, and locks two
  minutes after the page closes or on any vault lock event.
- Save as Credential uses the save offer's backend (`CredentialRouting`,
  `CredentialAccountSelection.savePlan` and `commitSave`). The vault is chosen
  and unlocked on the click; nothing is written until the person confirms, and
  a vault that changed since writes nothing and shows the new plan once.
- While the switch is on, the toolbar shows a clipboard button beside the key
  (`InputHistoryBadge`). It opens Settings › Autofill › Vault › Input History through
  `AppCoordinator.openSettings(revealing:)` and `pendingSettingsAnchor`. It is
  hidden in private profiles and on internal pages. Opening the page never
  unlocks the list.
- No code under `WSurf/MCP`, `WSurf/Agent` or `WSurf/Web/Assistant` names it
  (`InputHistoryIsolationTests`).

## Limits and validation

Completion signals are heuristics, not proof that a server accepted a password
or payment. Detection uses native frame identity and form-based heuristics; it
does not implement Chromium's network/renderer hooks or server predictions.
Closed shadow roots and arbitrary
custom editing widgets remain unsupported. Fields belonging to different
frames are not combined. Embedded dropdown geometry currently requires a
resolvable focused frame chain; multiple unrelated nested origins can be refused.

Regression fixtures cover structural ownership, standalone fields, non-English
actions, protected fields, and fill boundaries. Use a normally signed build for
manual checks. Removing entitlements prevents validation of real Keychain access.
System authentication, the Contacts picker, and live sign-in need manual testing.

## Manual checks

Use synthetic credentials and card details on a test page.

- Save and fill a normal login, a username-first login, and a form without a
  native HTML form. Check that embedded logins match the frame's HTTPS origin.
- Submit with a button and with Enter. Failed sign-in, a replacement password
  field, or a verification-code step must not trigger a premature save offer.
- Change the page or field while authentication is open. Filling must stop when
  the original document or field no longer exists.
- Check password changes, open shadow roots, non-English labels, and separate
  shipping and billing sections. Hidden fields must not receive saved details.
- Submit prefilled test values with a real user gesture. Script-generated clicks
  alone must not authorize saving.
- Delete a saved entry and submit it again. The browser should offer to save it.
- Switch profiles and enter private browsing. Saved data must not cross profiles,
  and private browsing must not use saved autofill.
- Leave Credential Manager, lock the screen, or switch macOS users. Returning to
  it must require unlocking again.
- With synthetic data in a test build, import an old list, cancel once, import
  again, then remove it. The list must stay until the final confirmation.
- Request a passkey on a test page in a profile with no vault, with a vault that
  has no passkey for the site, and with one that does. The first sheet must look
  alike to the page (it sees nothing until you answer), and "Use Another Device
  or Key…" must be the only way to the system's authenticator.
- Pick Credential…: right-click a code field the dropdown ignores, a login in an
  iframe, and a split six-box code; check that only that field (and its
  partner) is filled, and that "Use … on …?" appears only for an entry saved
  for another website.
- Not performed: Settings keyboard and VoiceOver, real passkey unlock (PRF),
  user presence and verification, Apple Passwords transfers, and Stage UI runs.
