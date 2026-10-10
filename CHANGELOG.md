<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Changelog
This file preserves release notes inherited from the upstream
[kavoye/linen-browser](https://github.com/kavoye/linen-browser) project. They
describe upstream Linen releases, not releases published by WSurf. New WSurf
release notes will be added above this provenance record.

## WSurf

### 2026-10-10 — Retired window keys no longer return a dead adapter

An extension window registry key can outlive its weak browser, for example when a
browser deallocates without being unregistered. Registering a browser over such a
key now retires the stale entry (controller window, window order, focus, anchors and
popup) and creates a fresh adapter; it no longer returns the retired adapter, and it
never rebinds it, so consent scopes captured for the old window stay invalid. A live
browser registering again still keeps its adapter. `unregister` shares the same
retirement in the same order. In the app this state can arise only when a window
skips unregistering during termination; the test suite produced it by registering
windows it never unregistered, which `MCPTransportTests` now cleans up. Tab adapters
left by a deallocated browser are not pruned, and this change is not shown to be the
cause of the earlier `MCPWindowScopeTests` CI failure, whose failing click error was
never recorded; the test now reports it if it recurs.

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
