<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Connect an external assistant

WSurf provides a native MCP server for controlling shared browser tabs from an
external MCP client. WSurf must be running. Its built-in assistant does not need
an API key, a model, or an open conversation.

1. In Settings, open **Advanced → External Connections** and enable **MCP server**.
2. Click **Add** beside your MCP client. This also pairs the client (see
   Pair a client below). Restart the client or reload its MCP connections.
   Other clients can use **Copy Configuration**.
3. Open the webpages you want to share in WSurf. A split view can share several
   pages together.
4. Have the client call `requestAccess`. WSurf comes to the foreground and opens
   an approval prompt for the displayed pages. Choose **Read Only** or
   **Allow Control**. A client that asked for development access also sees
   **Allow Development** (see Development access below), and a paired client that
   asked for Developer access on a developer site also sees **Allow Developer**
   (see Developer work below).
   If no shareable webpage is open, the prompt explains how to proceed; open a
   webpage and have the client request access again.
5. The client calls `listTabs`, then `readPage` with a returned `tabID`. Page
   actions use that tab ID, the returned `observationID`, and a numbered `ref`.

The copied configuration uses the path of the running app. For an installation
in Applications, a client accepting the common JSON configuration format uses:

```json
{
  "mcpServers": {
    "wsurf": {
      "command": "/Applications/WSurf.app/Contents/MacOS/WSurf",
      "args": ["--mcp"]
    }
  }
}
```

## Pair a client

**Add** creates a random 256-bit token for the client and writes it into the
client's `wsurf` entry as the environment variable `WSURF_MCP_TOKEN` (for
Codex, the `[mcp_servers.wsurf.env]` table). WSurf keeps only the SHA-256 hash of
the token, with the client's name and when it was paired and last used, in a
data-protection keychain item. The token never goes into a command-line
argument, UserDefaults, a log or the MCP messages themselves. **Copy
Configuration…** asks for a name, pairs an app under that name and copies a
configuration that holds its token. The copy carries the concealed-item marker
that clipboard managers honor; keep it private anyway.

The `WSurf --mcp` relay reads the variable and writes one hello line on the
socket before any MCP traffic: `{"wsurf":"hello","v":1,"token":"…"}`. The line
is at most 512 bytes and must arrive within 2 seconds. WSurf compares hashes in
constant time and binds the connection to the paired client. A first line that
is not a hello reaches MCP unchanged, so an old relay or a direct socket client
connects as an unpaired app. A wrong, malformed or revoked token does the same.

Settings › Assistant › **Connected apps** lists each paired app with when it was
last used. **Revoke…** ends the app's live connections and invalidates its
token at once. The entry stays in the client's configuration and connects as an
unpaired app until you choose **Pair** again. **… → Re-pair** replaces the token;
the old one stops working immediately.

Pairing does not skip any prompt. Every connection still starts with no grants,
and a paired app asks for access like any other. Pairing lets WSurf recognize an
app you configured, so later features can give a known, revocable app access that
an unknown process cannot get.

Apps you added before pairing keep working with no change. They have no token,
show **Not paired** with a **Pair** button, and ask for approval each time they
connect. **Pair** changes only `env.WSURF_MCP_TOKEN` of the existing entry
(Codex: the `WSURF_MCP_TOKEN` line of its `env` table), under the same backup,
unchanged-file and conflict rules as setup; other settings of the entry stay.
Codex setup writes the token into the staged copy of its configuration and
checks the result with the Codex CLI, so the token is never on a command line.

A token identifies an app you configured. It does not protect against malware
that runs as your user: that can read the client's configuration file, as it can
read your browser's data on disk. Tokens do not expire. WSurf does not use OAuth
(MCP's authorization flow is defined for HTTP transports, and a stdio server takes
its credentials from its environment) and opens no network listener.

Pairing needs the data-protection keychain of a signed WSurf build. If WSurf
cannot read that item, for example in an unsigned development build, or if it is
damaged or from a newer version, pairing is unavailable and says so. Setup then
works as before, nothing authenticates, and WSurf never overwrites an item it
could not read. Every app asks for approval each time it connects.

## Automatic client setup

WSurf detects the standard macOS app, command-line tool, and configuration
locations for these clients:

| Client | User configuration |
| --- | --- |
| Codex | `~/.codex/config.toml`, or `$CODEX_HOME/config.toml` when WSurf inherits that environment variable |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Claude Code | `~/.claude.json`, with the server added at user scope |
| Cursor | `~/.cursor/mcp.json` |
| omp.sh | `~/.omp/agent/mcp.json` |

The **Copy Configuration** button sits above the client list. Use the
**… → Choose Configuration…** action beside a client for an existing
custom profile or another configuration location. WSurf does not scan your
shell aliases or project directories. **… → Show Configuration** reveals the
selected file in Finder; file paths are kept out of the client rows.

omp.sh uses the same JSON configuration shown above. For a named profile,
choose `~/.omp/profiles/<name>/agent/mcp.json`. After adding WSurf, run
`/mcp reload` and `/mcp test wsurf` in omp to load and check the connection.

The **Added** state is read from the saved configuration when this page opens
and when WSurf becomes active again, including entries configured elsewhere.
These status checks do not modify the client configuration.

Setup merges only a `wsurf` server entry into the chosen configuration. Other
servers, client settings, and project-specific entries are preserved. An exact
existing command and argument are left alone, including any disabled state or
custom client permissions. A different entry named `wsurf` is a conflict and is
never silently overwritten. Review it in the client if you move WSurf to a new
location. Setup does not enable MCP tools that the client has disabled.

Before changing an existing file, WSurf saves its exact bytes beside it as
`<filename>.wsurf-backup-<unique ID>`. **… → Show Backup** reveals that copy.
Backups and replacements are readable only by your OS user (`0600`); backups
may include credentials for your other servers, so keep them private. Setup
rejects linked, malformed, unsupported, or oversized files and checks for
concurrent edits before replacing a file atomically. JSON-with-comments files
can use the manual configuration route instead.

Codex setup uses the installed Codex CLI, including the executable bundled in
its desktop app, to parse and edit a private temporary copy of its TOML. This
preserves TOML syntax and comments without maintaining a second parser in
WSurf. Setup does not launch a model, connect a server, import client history,
or grant access to browser tabs.
Both the nested `codex-cli/CodexCLI.app/Contents/MacOS/codex` bundle layout and
the older `Contents/Resources/codex` layout are supported. An executable found
through the existing CLI search still takes precedence.


Configuration formats follow the official documentation for
[Codex](https://learn.chatgpt.com/docs/extend/mcp?surface=cli),
[Claude Desktop](https://modelcontextprotocol.io/docs/develop/connect-local-servers),
[Claude Code](https://code.claude.com/docs/en/mcp),
[Cursor](https://cursor.com/docs/mcp), and
[omp.sh](https://omp.sh/docs/mcp).

Clients with a different settings format need the same command and argument.
Restart the client's connection after moving the app or enabling the server.
The server is off until you enable it, then remembers your choice across launches
and profile changes. Each connection binds to the regular window that owns it when
it connects; focus changes never retarget it. Closing or switching that window
disconnects its clients and clears their grants, without disrupting other windows.
Private focus refuses new connections; it does not pause existing connections to
regular windows. Consent sheets belong to the connection's originating window.

After a browser restart, the relay reconnects on the next tool call and the client
must request fresh sharing approval. Calls made while WSurf is unavailable return
a tool error; interrupted calls are never replayed because an action may already
have happened. Use **Disconnect** beside a connection in Advanced settings to
revoke it immediately.

## Tools in this version

| Tool | Behavior |
| --- | --- |
| `requestAccess` | Ask to share the webpages currently on screen. One sheet per connection; later calls only add tabs that a paired app's standing grant covers. `development: true` also asks for development access and `developer: true` for Developer access; the user may grant less. |
| `listTabs` | List only tabs shared with this connection. |
| `readPage` | Search rendered text, scope or paginate controls, and return an observation ID. |
| `clickOnPage` | Click a numbered control from that observation. |
| `typeOnPage` | Fill a nonsensitive field, optionally submitting it. In the Developer tier, `secret: true` types a test credential into a sensitive field; see Test credentials. |
| `selectOption` | Choose an option in a select control. |
| `fillFields` | Fill up to 32 distinct nonsensitive form controls without submitting; report exactly which refs retained their values. In the Developer tier an item may add `secret: true` for a test credential. |
| `inspectControl` | Read control state and paginate dropdown options. |
| `setChecked` | Set a checkbox, switch, or radio to the requested state. |
| `waitForPage` | Wait up to 15 seconds for text, absent text, a URL substring, document readiness, or a CSS selector that matches exactly one element to be visible, hidden/absent, or enabled. An element wait ends as stale if the page navigates. Selectors are limited to a safe subset; see below. |
| `screenshotPage` | Return an image of the viewport, one referenced element, or a viewport region (`region`: `x`, `y`, `width`, `height` in CSS pixels, which must lie fully inside the viewport and cannot be combined with a reference). An element is cropped to its visible part, also when it sits in a same-origin iframe (the frame's border, padding, scale, clipping, CSS zoom and any 2D rotation, reflection or skew are applied; a selected frame, a frame or clipping container under a 3D transform or perspective, or a frame or clipping container inside SVG content, is refused). A control ref from `readPage` needs only read access; any other element ref from `findElements` needs development access, checked before the work, after every wait and again just before the image is returned. The image is shrunk to fit the message limit, and the result states the covered rectangle and the scale of the image actually returned. Never scrolls or stitches. Refused when a sensitive field is filled anywhere on the page, even for a crop; in the Developer tier those fields are covered in black instead. |
| `pressKey` | Send a supported keyboard key to a control in a visible tab. |
| `hoverOnPage` | Move the real pointer to a referenced element, so CSS `:hover` and pointer/mouse handlers run. Needs WSurf to be the active app with a key window and the tab on screen; it never activates or raises WSurf. Refused with a specific message when the element is offscreen, covered, or clipped by the window (a development viewport larger than the window), or when the pointer could not be delivered; not available inside frames. |
| `getDevelopmentInfo` | Engine, measured viewport (`innerWidth`, `innerHeight`, device pixel ratio, touch), zoom, who holds the tab's development lease (`none`, `self`, `other`) and per-engine capabilities. Works with any grant. |
| `findElements` | Development. Elements matching a safe CSS selector in the document, same-origin frames and open shadow roots, with `offset` (0–10,000) and `limit` (1–100, default 50); skipped cross-origin frames and closed shadow roots are reported. A page is also bounded by delivered bytes (about 24 KiB of the escaped result); it ends early with `hasMore: true` and a following `offset` continues it. Returns an `observationID` whose refs work with `inspectElement` and, for a screenshot, `screenshotPage`; they are never targets for click, type, hover or any other action. |
| `inspectElement` | Development. Bounded attributes, geometry, box model, allowlisted computed styles and ancestors of one found element. No field values and no raw HTML. The result is kept under the same delivered-bytes budget by dropping ancestors, then attributes, then styles, and says which (`ancestorsTruncated`, `attributesTruncated`, `truncated`). |
| `setViewport` | Development. Lay the page out at an exact CSS-pixel viewport (64–4,096 per axis). The result is the size measured inside the page. Needs the tab on screen. |
| `emulateDevice` | Development. Apply a profile and orientation (table below). Needs the tab on screen. |
| `reloadPage` | Development. Reload the tab; the lease stays only while the new page is still inside the connection's access. |
| `resetDevelopment` | Remove this connection's viewport, emulation and diagnostics and release its lease. Safe to repeat. |
| `startDiagnostics` | Development. Start console and network capture for the tab's current document. Earlier activity is not available. |
| `readConsole`, `readNetwork` | Development. Page through captured records with `cursor` and `limit` (1–100, default 50). Responses state `engine`, `sources`, `gaps`, `epoch`, `documentID`, `nextCursor`, `dropped`, `evicted`, `truncated` and `lostInFlight`. |
| `scrollPage` | Scroll vertically or horizontally, optionally inside a referenced container. |
| `goBack` | Go back within the shared website. |
| `navigate` | Navigate a shared tab; another website requires approval. |
| `newTab` | Ask to open and share a new webpage. Requires existing control access, except for a paired app's standing grant on a developer site, which needs neither a grant nor a sheet. |
| `switchTab` | Activate an already shared tab before controlling it. |
| `closeTab` | Close an already shared, unpinned tab. |

These tools cover browser page and tab actions. Assistant conversations, background
research, the media player, arbitrary JavaScript, cookies, credential stores and
filesystem access are not exposed.

Successful page actions return fresh controls and an `observationID`; reuse that
result for the next action. `fillFields` accepts positive, distinct refs from the
latest observation: text, supported value controls, dropdowns and checked states
(`true`/`false`). Password/payment controls remain blocked (except an item marked
`secret` in the Developer tier), disabled/read-only controls are skipped, and file pickers cannot be opened by a batch. No batch submits
a form. Navigation, cancellation or access revocation stops remaining writes.

A partial batch can return fresh controls without marking the whole call as an
error. Check the verified ref list, not just `isError` or the completed count; do
not replay verified refs or retry blocked controls through another tool.
Reads and actions use document-bound references in the same isolated runtime.
Replaced or unobserved targets are refused.

Use `lookingFor` to search beyond the first excerpt, `scope` for the controls under every element a CSS selector
matches, `viewportOnly` for visible controls, and `textOffset` / `controlOffset` to continue.
Keep the query and scope unchanged when paging. Text offsets use UTF-16 units.
The standard text response budget is about 6 KB before MCP framing; a screenshot is capped at 150 KB of JPEG, and its pixels shrink when needed.
A ref the observation did not list gets a message saying so, not the stale-page message.
Use screenshots only when text and control state do not answer the task.


### Development access

`requestAccess` with `development: true` adds an **Allow Development** choice to the prompt. Development includes control, and is also refused wherever **Assistant Access** is Off or Read Only for the site. A prompt that was not asked for development cannot grant it. Development tools reply with a structured `status`: `ok`, `unsupported`, `invalidInput`, `stale`, `denied`, `ownershipConflict` or `pageGone`; every status except `ok` is a tool error and carries a `message`.

**One owner per tab.** The first connection to change a tab (viewport, emulation or diagnostics) holds its development lease; another connection gets `ownershipConflict` and nothing is changed. The lease is bound to the exact page view and document generation it was granted on. It ends with `resetDevelopment`, disconnect, the grant or site access dropping below development (checked at the start of every call and again when a site policy changes), the tab's page view being replaced (for example an engine change), a navigation that commits outside the grant, a reloaded page outside the grant, or the tab closing. A call already running on a page that is replaced or left does not return its result. Ending the lease removes the viewport, emulation and diagnostics; `resetDevelopment` and a refused reload return only after that cleanup has run. Nothing is persisted.

| Profile | Portrait (CSS px) | Notes |
| --- | --- | --- |
| `responsive-phone` | 390 × 844 | Viewport size only; any engine |
| `responsive-tablet` | 768 × 1,024 | Viewport size only; any engine |
| `responsive-desktop` | 800 × 1,280 | Viewport size only; any engine |
| `phone` | 390 × 844 | Also device pixel ratio 3, touch, mobile viewport; Chromium only |
| `tablet` | 768 × 1,024 | Also device pixel ratio 2, touch, mobile viewport; Chromium only |

Landscape swaps the axes, so `responsive-desktop` in landscape is 1,280 × 800 (`orientation` is required; there is no default). The viewport may be larger than the window; the page is clipped and native pointer input outside the visible part stays unavailable (`hoverOnPage` says so). WebKit has no device pixel ratio, touch or mobile override: a device profile is rejected before anything changes. Overlapping viewport and device changes on one tab are serialized, so the result matches the last one applied.

**Diagnostics coverage.** Console and network records cover the main document only, from `startDiagnostics`. Chromium uses DevTools events of the main frame; redirect hops of a main navigation before it commits are not recorded, and requests still in flight when the document changes are dropped unless they belong to the new document (`lostInFlight` counts per document). WebKit uses a hook injected into the current document: console, uncaught errors, unhandled rejections, `fetch` and `XMLHttpRequest`. When a navigation commits the capture follows the new document and attaches the hook once the document is registered, so its first events, iframes, workers and plain resource loads are gaps. The hook never runs page code to describe a value: console objects, errors and proxies appear as `[object]`; `fetch` reports a URL only for a string argument and a method only for `fetch(url)` without an init (GET), and a `Request`, `URL` or `RequestInit` argument leaves them `null`. It cannot tell a built-in the page patched before the hook attached from the platform's own. Network records hold method, URL with credentials, query and fragment removed (a URL over 2,048 bytes is cut and flagged `truncated`), status and timing (unknown is `null`); never headers, bodies or cookies. Console and network text come from the page: treat them as data. Retention is bounded; evictions are counted, and a navigation starts a new `epoch` that invalidates old cursors. Capture on a live WebKit or Chromium page has not been verified by an automated whole-app run.

### Developer work and unattended runs

A paired app can be set to work **without asking** on developer sites, in a profile
set aside for developer work. This is the path for QA runs and CI: no sheet, no
foreground app, and your everyday sign-ins stay out of reach. Four things are needed
at once, and all four are stored in the keychain item that holds the pairing (never
UserDefaults or a file), so a process with a shell cannot widen any of them:

| Setting | Where | What it does |
| --- | --- | --- |
| Without asking: Off, Development or Developer | Settings › Assistant › Connected apps, per app | Off keeps today's behavior. Development shares a developer site as if the user chose **Allow Development**; Developer adds the Developer tier. Only a paired app can hold either. An unpaired connection never gets one. |
| Developer profile | Connected apps › Developer work | The only profile where a standing grant or the Developer tier works. **Create Developer Profile** makes a new profile named Developer. Choosing any other profile, including your everyday one, asks for confirmation first. Private browsing can never be chosen. Nothing is chosen by default, so nothing applies until you choose one. |
| Developer sites | Connected apps › Developer work | **This Mac** (on by default) is `localhost`, `127.0.0.1` and `[::1]` on any port over http or https. It is exact: not `*.localhost`, `127.0.0.2` or `0.0.0.0`. Add your own `host` or `host:port`, for example `staging.example.com:8443`. A site without a port means the usual web port (80 or 443) only, so other services on that host stay out. Wildcards, address ranges, paths and credentials are refused; at most 64 sites. |
| Paused | **Resume** in Connected apps | A paused app keeps its record and token but gets no standing grant, and the grants it held are dropped, until you resume it. |

**What a standing grant does.** After the app's hello, WSurf moves the connection to a
window of the Developer profile (the most recently used one, or a new one opened behind
your other windows; it never activates WSurf or takes focus). In that window,
`requestAccess` shares tabs on developer sites at the app's level without a sheet, and
`newTab` and `navigate` to developer sites need no prior grant, no sheet and no
observed link. A tab that moves by itself between developer sites keeps the grant. Any
other site still needs the usual sheet, at most one per connection, and a standing grant
that takes an approved move to such a site comes along as Allow Control only. A site's
own Assistant Access setting still caps the grant: Read Only blocks control, development
and Developer, and No Access hides the tab.

**Re-checked on every use.** The grant holds only while the app is still paired, not
paused and not lowered, the page is on a developer site and the window is in the
Developer profile. Pausing, lowering, revoking, removing a site or changing the profile
takes effect on live connections at once: standing grants are dropped and the
development leases they carried are released. Leaving the developer sites drops a
standing grant; the app asks again and gets it back only where it applies.

**The Developer tier** (**Allow Developer** in the sheet, or a standing level of
Developer) requires a paired app, a developer site and a window of the Developer
profile. The sheet offers it only for tabs that qualify, only to a request with
`developer: true`, and never to an unpaired connection. If the profile or the developer
sites change so that it no longer applies, a Developer grant from the sheet falls back
to Development (a standing grant is dropped); a page that leaves the developer sites
ends the grant. Today the tier lets consequential actions on developer sites (purchases,
transfers, deletions, posting and sending) go through without the confirmation sheet;
each one is logged and kept in the connection's recent list. Everywhere else, and for
the in-app assistant, those confirmations stay. Later features that need an explicit
tier build on it.

**Unattended runs.** Use a signed WSurf build (the keychain item needs its access
group), enable MCP, pair the client, choose or create a Developer profile, set the app to
Development or Developer, and keep a logged-in Mac session with WSurf running and at
least one regular window open. The client then calls `newTab("http://localhost:5173/")`
and works in the Developer window. A connection is refused while the focused window is a
private one, as before. Adding a staging host to the developer sites extends standing
grants to it; Settings says so.

### Test credentials

In the Developer tier an app can type **test** credentials that it supplies itself into
password, one-time code, card and other sensitive fields: `typeOnPage` with
`secret: true`, or `secret: true` on `fillFields` items. Without `secret`, a sensitive
field is refused exactly as before. With it, anywhere the Developer tier does not
hold (an unpaired app, a site that is not a developer site, a window outside the
Developer profile, a Read Only site) the call is refused before anything is typed. Use
test accounts and test values only. The app's own transcript holds what it sent, which
WSurf cannot reach, and the page under test receives the value like any other input.

- **Saved passwords are never involved.** The vault and autofill are not read, offered
  or written: the field is not focused (so no suggestion list opens), open suggestions
  are dismissed, and any save offer the form could raise is dropped.
- **Every result hides the secret.** WSurf remembers each secret for that connection
  only, in memory, and removes it from everything it returns: page text and control
  values, tab titles and URLs, console and network records, and the structured copy of
  each result. It matches the exact value as typed, with whitespace collapsed,
  percent-encoded, JSON-escaped and HTML-escaped (also layered, and ignoring ASCII case),
  so a page that echoes the value into its text, a console line or a URL still shows
  `‹secret›`. The registry is wiped when the connection ends: disconnect, **Stop**, revoking
  the app or turning MCP off, and a result still being computed at that moment is dropped.
  Nothing is written to disk or to a log, and the registry prints as a count.
- **Your records stay complete.** The app decides what it registers as a secret, so that
  registry only shapes what the app is told, never what you read about what it did. A
  record of an action (a confirmation the Developer tier skipped, an activity entry) hides
  only a value of at least 8 characters that a password, code or card field kept as typed
  (or the grouped form the page stored for it), and only as a whole word. It shows
  `‹hidden secret›` where it did. The action's kind, the site and the amount stay fields
  of their own, and a long label keeps its start and end, so padding cannot push the action
  out. A phrase typed into an ordinary field is never hidden there.
- **Screenshots cover the fields.** In the Developer tier, filled sensitive fields and
  fields a secret was typed into are painted black in the returned image instead of
  refusing the capture (a field inside a frame is covered by the whole frame, and one
  that cannot be measured still refuses it). Page text that merely repeats a secret is not
  covered in pixels; use `readPage`, which hides it.
- **Limits.** A secret is at least 4 characters, because a shorter value cannot be hidden
  without damaging ordinary results, and one connection holds at most 32 different ones.
  Secrets go into text fields of the page itself, not into frames, dropdowns or
  checkboxes. Only the value and the encodings above are recognised, plus the form a
  field ends up holding when the page reformats it (digits grouped in a card number, say);
  a page that hashes or otherwise transforms the value shows the result as it is. A page
  can also keep what it receives (its own logs, a form sent with GET in the address bar
  and history); choose test values that mean nothing.

### Safe selectors

A CSS selector is evaluated against the page, so an attribute test such as `input[type=hidden][value^=a]`, also under `:has()`, would read a value one character at a time. Selectors passed to `waitForPage`, `findElements` and `readPage` scope are therefore parsed by the browser first (escapes, case and namespace forms such as `v\61lue` or `[*|value]` are normalised) and may test only attributes WSurf already exposes: `id`, `class`, `role`, `type`, `name`, `for`, `alt`, `title`, `placeholder`, `lang`, `dir`, `target`, `rel`, `aria-*`, the test attributes `data-testid`, `data-test`, `data-test-id`, `data-cy`, `data-qa` and `data-automation-id`, and a few boolean or numeric ones (`disabled`, `checked`, `hidden`, `width`, `min`…). `href` and `src` may be tested for presence only. Any other attribute test, including `value`, other `data-*` and `on*`, is refused with an explicit error rather than answered with an empty result. A selector is at most 2,048 UTF-8 bytes, enforced natively (a `readPage` scope longer than that is refused before anything is read). Structural attributes such as `id`, `class` and `name` can still be probed, including on hidden inputs: they are page structure, not values, and value-bearing attributes cannot be tested. Structural selectors, classes, ids and `:has()` without such tests work as usual.

## Privacy boundaries

- Connecting and discovering tools disclose no tabs or page content. Every
  connection starts with no grants. The displayed client name is supplied by
  the client; it is not a verified app identity. A pairing token identifies an app
  you configured, not its code signature.
- Standing grants and the Developer tier bind to paired apps only. They apply only on
  developer sites, in the Developer profile, and are stored in the keychain with the
  pairing. Your everyday profile is never reachable that way unless you choose it.
  Private windows are never shared, whatever the setting.
- Access is restricted to the captured tab IDs and their website origins. Other
  tabs, private browsing, internal pages, and denied sites cannot be listed or
  addressed by guessing an ID. Redirecting to another website does not grant
  access to its contents. Reconnect and request sharing again when needed.
- External sharing grants are separate from the assistant's site grants.
  **Assistant Access: Off** blocks external access; **Read Only** blocks external
  control even when the connection has a control grant. External sharing does
  not change those settings.
- The existing page driver detects and masks sensitive fields and refuses to
  fill them; the one exception is a test secret typed in the Developer tier, which
  is hidden from every result (see Test credentials). Consequential actions use WSurf's native confirmation UI. External
  confirmations do not inherit the assistant's saved action approvals; any
  remembered approval lasts only for that connection.
- External page scripts run in WebKit's isolated client world. Observation IDs
  belong to one connection and one document. Another read invalidates the
  underlying control snapshot. Revocation and navigation are checked again
  after suspension and before returning page data.
- After reading untrusted content, outbound navigation must use an observed
  link, including its query string. The client cannot construct an arbitrary
  address from page content and navigate to it through these tools.
- External calls are serialized. Starting an in-browser assistant task cancels
  an active external call. External calls do not enter the assistant's
  conversation history. Settings shows connected clients, grant counts, and
  tool-call counts; page bodies and arguments are not persisted as MCP logs.

The MCP transport stays on this Mac. Shared page data goes to the connected
application, which may send it to its own model provider. A local transport does
not imply that the external application's processing is local.

## Implementation

`WSurf --mcp` starts a relay before initializing AppDelegate, profiles, databases,
or WebKit. It keeps a standard MCP stdio session alive independently of the
browser and forwards tool calls over a Unix socket. Browser connections are
initialized on demand, including after a restart; sharing grants and observations
are never replayed. The official Swift MCP SDK handles protocol initialization,
tool discovery, calls, and cancellation. No TCP listener or HTTP endpoint is opened.
The relay exits when its client's stdin closes. Its tool catalog belongs to the
launched relay version: reload the client connection after an update that changes
the tools, or once when upgrading from the old relay that exited on browser shutdown.

The socket lives in a directory owned by the current OS user with mode `0700`;
the socket has mode `0600`. Directory and lock-file symlinks are rejected, and a
file lock prevents another WSurf process from replacing the live endpoint.
Message sizes, buffered messages, and concurrent connections are bounded. The
first line of a connection may be a pairing hello (see Pair a client); `MCPPairing`
and `MCPTrustStore` own the token format and the keychain record.
Stdio reads are event-driven rather than polled. The transport owns duplicated
descriptors and fails on bounded-buffer overflow instead of dropping requests.
At inbound SDK boundaries, an object-valued `initialize` experimental-capability
field is removed for compatibility; standard capabilities and access policy are
unchanged. Malformed messages still reach the normal protocol validation.


`MCPBrowserSession` owns external grants, observations, and transient activity.
It calls the existing `PageDriver` and honors `TabAssistantAccessCenter` policy.
`AgentToolkit` and assistant conversation scoping retain their existing behavior.
`PageAutomationGuard` supplies additional revocation and document checks only
while an external page call is executing.

WebKit and Chromium use the same page driver and privacy checks. Chromium
Back/Forward-cache restores retain isolated-world contexts and rebind them to
the restored document, while completing navigation and updating history controls.
Credential contexts minted before a restore are still invalidated. Actions on
restored pages still require a fresh MCP observation.

The SDK dependency is pinned in the Xcode project and package lockfile. Focused
tests live in `MCPPrivacyTests` and `MCPTransportTests` and use local fixtures.
`ChromiumPageTests` runs embedded CEF against local HTTP fixtures, covering
cached Back/Forward navigation, isolated-world state, live frame identities,
script messages, and loading/history state.
