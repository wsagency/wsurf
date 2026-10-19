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
classified with their password group, so contact filling cannot claim them.
Hidden/disabled controls cannot be filled. An explicit hidden username belonging
to a native form can supply account metadata for saving a multipage login.

## Suggestion presentation

Focus and click share a field token, so native code reuses pending lookups and
visible panels. Empty or failed lookups remain silent. DOM mutations can dismiss
a disconnected target but never open suggestions or trigger metadata lookups.
Only a visible, populated panel runs the geometry watcher; ownership, policy and
origin are still revalidated before presentation and around authenticated filling.
Typing or dismissal requires another focus/click interaction to reopen the panel.

A password list holds only accounts saved for the page's exact origin. When it
would be empty but an unlocked vault holds accounts for another HTTPS website of
the same registrable domain (public-suffix aware, so `a.github.io` and
`b.github.io` are not related), the panel shows one row, "Check other logins
for *.example.com". Choosing it lists those accounts, each with the website it
is saved for. Only titles and websites are shown; the chosen account's secret
is read again at delivery and filled exactly like a normal choice.

After such a fill, and when a submitted login repeats one saved for a sibling
website exactly (username and password) while nothing for the page has that
username, the address-bar popover offers "Add login.example.com to “ada”?"
instead of saving a copy. The offer holds no secret. Only Add Website writes,
under the unlock it was offered under, through the vault's ordinary commit, so
History keeps the earlier list of websites. A credential that already has 64
websites is never widened, and Not Now is remembered for the page.

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
explicit dismissal. Only explicit Save/Update writes a candidate to its store: a
password goes to Credential Manager, a card or an address to its own vault. A
profile with no vault gets one offer per run of the app to set one up, and
nothing is saved by it.

Native code binds messages to the WebKit or CEF frame identity and origin.
Filling additionally checks the document/form/field identity, selection token,
focus, geometry, and policy before and after authentication. A new document at
the same URL is still a different document.

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
  import in Settings › Autofill › Credential Manager. The Keychain list is
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
- Not performed: Settings keyboard and VoiceOver, real passkey unlock (PRF),
  user presence and verification, Apple Passwords transfers, and Stage UI runs.
