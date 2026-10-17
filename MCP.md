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
   **Allow Development** (see Development access below).
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
| `requestAccess` | Ask once to share the webpages currently on screen. `development: true` also asks for development access; the user may grant less. |
| `listTabs` | List only tabs shared with this connection. |
| `readPage` | Search rendered text, scope or paginate controls, and return an observation ID. |
| `clickOnPage` | Click a numbered control. Returns what the click changed (see Action results). |
| `typeOnPage` | Fill a nonsensitive field, optionally submitting it. |
| `selectOption` | Choose an option in a select control. |
| `fillFields` | Fill up to 32 distinct nonsensitive form controls without submitting; report exactly which refs retained their values. |
| `inspectControl` | Read control state and paginate dropdown options. |
| `setChecked` | Set a checkbox, switch, or radio to the requested state. |
| `waitForPage` | Wait up to 15 seconds for text, absent text, a URL substring, document readiness, or a CSS selector that matches exactly one element to be visible, hidden/absent, or enabled. An element wait ends as stale if the page navigates. The page watches for the condition itself, so a wait is one call, not a poll. Selectors are limited to a safe subset; see below. |
| `screenshotPage` | Return an image of the viewport, one referenced element, or a viewport region (`region`: `x`, `y`, `width`, `height` in CSS pixels, which must lie fully inside the viewport and cannot be combined with a reference). An element is cropped to its visible part, also when it sits in a same-origin iframe (the frame's border, padding, scale, clipping, CSS zoom and any 2D rotation, reflection or skew are applied; a selected frame, a frame or clipping container under a 3D transform or perspective, or a frame or clipping container inside SVG content, is refused). A control ref from `readPage` needs only read access; any other element ref from `findElements` needs development access, checked before the work, after every wait and again just before the image is returned. The image has one pixel per CSS pixel unless `maxWidth` (320–2,048) asks for another width, and is shrunk further to fit the message limit; the result states the covered rectangle and the scale of the image actually returned. `fullPage: true` (development access, asked again before the image is returned; Chromium only, WebKit reports that it cannot) captures the document from its top-left corner, at most 4,096 by 4,096 CSS pixels and 2,048 image pixels wide, whatever size the page reports. At most two captures a second per connection. Otherwise never scrolls or stitches. Refused when a sensitive field is filled anywhere on the page, even for a crop. |
| `pressKey` | Send a key or a key chord to a control in a visible tab: a named key (`Enter`, `Tab`, `Escape`, `Space`, the arrows, `Home`, `End`, `PageUp`, `PageDown`, `Backspace`, `Delete`) or one printable ASCII character, with optional `modifiers` (`shift`, `option`, `command`). The key goes to the page only; see Key chords below for what is refused. Name the control with `ref` or `selector`. |
| `hoverOnPage` | Move the real pointer to a referenced element, so CSS `:hover` and pointer/mouse handlers run. Needs WSurf to be the active app with a key window and the tab on screen; it never activates or raises WSurf. Refused with a specific message when the element is offscreen, covered, or clipped by the window (a development viewport larger than the window), or when the pointer could not be delivered; not available inside frames. |
| `dragOnPage` | Drag from a source (`ref`, or `selector` with development access) to a destination (`toRef`, `toSelector`, or `dx` and `dy` CSS pixels from the source's centre). By default it dispatches the DOM events of a drag (`dragstart`/`dragover`/`drop`, or pointer and mouse events); they are untrusted and work with the tab in the background. `pointer: true` sends trusted pointer input instead (see Drag below). Both ends must be visible in the top document; frames, file inputs, sensitive and disabled elements are refused. |
| `getDevelopmentInfo` | Engine, measured viewport (`innerWidth`, `innerHeight`, device pixel ratio, touch), zoom, who holds the tab's development lease (`none`, `self`, `other`) and per-engine capabilities. Works with any grant. |
| `findElements` | Development. Elements matching a safe CSS selector in the document, same-origin frames and open shadow roots, with `offset` (0–10,000) and `limit` (1–100, default 50); skipped cross-origin frames and closed shadow roots are reported. A page is also bounded by delivered bytes (about 24 KiB of the escaped result); it ends early with `hasMore: true` and a following `offset` continues it. Returns an `observationID` whose refs work with `inspectElement` and, for a screenshot, `screenshotPage`; they are never targets for click, type, hover or any other action. |
| `inspectElement` | Development. Bounded attributes, geometry, box model, allowlisted computed styles and ancestors of one found element. No field values and no raw HTML. The result is kept under the same delivered-bytes budget by dropping ancestors, then attributes, then styles, and says which (`ancestorsTruncated`, `attributesTruncated`, `truncated`). |
| `setViewport` | Development. Lay the page out at an exact CSS-pixel viewport (64–4,096 per axis). The result is the size measured inside the page. Needs the tab on screen. |
| `emulateDevice` | Development. Apply a profile and orientation (table below). Needs the tab on screen. |
| `reloadPage` | Development. Reload the tab; the lease stays only while the new page is still inside the connection's access. |
| `resetDevelopment` | Remove this connection's viewport, emulation and diagnostics and release its lease. Safe to repeat. |
| `startDiagnostics` | Development. Start console and network capture for the tab's current document and the ones after it. Earlier activity is not available. |
| `readConsole`, `readNetwork` | Development. Page through captured records with `cursor` and `limit` (1–100, default 50), narrow them with filters, or read one record with `seq`. Responses state `engine`, `sources`, `gaps`, `epoch`, `documentID`, `nextCursor`, `dropped`, `evicted`, `truncated`, `lostInFlight`, `lostEarly` (WebKit) and, with a filter, `skipped`. Filters: `level` and `urlContains` for `readConsole`; `minStatus`, `outcome`, `type` and `urlContains` for `readNetwork`. |
| `scrollPage` | Scroll vertically or horizontally, optionally inside a referenced container. |
| `goBack` | Go back within the shared website. |
| `navigate` | Navigate a shared tab; another website requires approval. |
| `newTab` | Ask to open and share a new webpage. Requires existing control access. |
| `switchTab` | Activate an already shared tab before controlling it. |
| `closeTab` | Close an already shared, unpinned tab. |
| `handleDialog` | Read or answer a JavaScript dialog (alert, confirm, prompt, or Chromium's beforeunload "Leave site?") that a page opened in a shared tab. Needs control access. See Page dialogs below. |

These tools cover browser page and tab actions. Assistant conversations, background
research, the media player, arbitrary JavaScript, cookies, credential stores and
filesystem access are not exposed.

A page action reports what it changed (see Action results) and an `observationID`.
A ref stays valid for as long as its document does and its control is unchanged, so
the next action needs no new read. `fillFields` accepts positive, distinct refs
the client was given: text, supported value controls, dropdowns and checked states
(`true`/`false`). Password/payment controls remain blocked, disabled/read-only
controls are skipped, and file pickers cannot be opened by a batch. No batch submits
a form. Navigation, cancellation or access revocation stops remaining writes.

A partial batch can return fresh controls without marking the whole call as an
error. Check the verified ref list, not just `isError` or the completed count; do
not replay verified refs or retry blocked controls through another tool.
Reads and actions use document-bound references in the same isolated runtime.
Replaced or unobserved targets are refused.

Use `lookingFor` to search beyond the first excerpt, `scope` for the controls under every element a CSS selector
matches, `viewportOnly` for visible controls, and `textOffset` / `controlOffset` to continue.
Keep the query and scope unchanged when paging. Text offsets use UTF-16 units.
The text of a full read is about 6 KB before MCP framing; an action's report defaults to at most 4 KB and is about 1 KB for a typical click. A screenshot is capped at 150 KB of JPEG, and its pixels shrink when needed.
A ref the observation did not list gets a message saying so, not the stale-page message.
Use screenshots only when text and control state do not answer the task.


### Action results

`clickOnPage`, `typeOnPage`, `selectOption`, `setChecked`, `fillFields`, `scrollPage`, `pressKey` and
`hoverOnPage` return what the action changed instead of the whole page. The page is digested before and after
(controls, text, focus, scroll position); only the difference is sent: 0.3 to 1 KB for a click, a
field change or a selection on a typical page, where the same action returned 3.3 KB of text before. The reply keeps the earlier keys (`tabID`, `content`,
`observationID`, `url` after a navigation) and adds `status` (`ok` or `failed`), `action`, `navigation` and `cost`.
`content` is the report inside the untrusted-content wrapper; every string in it comes from the page.

```
Clicked “Add to cart”.
added (1):
[34] button "Checkout"
changed:
[3] text "Cart (0)" → "Cart (1)"
text added: "Added to cart"
```

| Line | Meaning |
| --- | --- |
| `navigation: load → URL` | The action loaded a new document. There is nothing to diff: the new page's title, text and up to 15 controls follow, and their refs work. `sameDocument` is a URL change inside the document (`pushState`, a hash). |
| `added (n):` | Controls that did not exist for the client before, viewport first, up to 10, each as `readPage` prints it (so a listed link is an observed link). |
| `removed:` | Refs that left the page. Not reported for a scroll, where leaving the viewport is not a removal. |
| `changed:` | A control's `text`, `value`, `filled`, `checked`, `expanded`, `pressed`, `selected` or `disabled`, up to 20. A sensitive field reports `filled` and never its value. |
| `text added:` / `text removed:` | Up to 3 text blocks (160 characters each) that appeared or went away and are not a control's own label. The first 600 text blocks of the page are compared; for a scroll, the text in the viewport. |
| `focus: A → B` | The focused element moved. |
| `scroll: y of max px` | The scroll position, for `scrollPage` only (acting on a control scrolls it into view, which is not reported). |
| `console:` / `failed requests:` | New console errors (first 3) and requests that failed or returned 400 or more, only while this connection's `startDiagnostics` capture runs on the tab. Otherwise the reply says `"diagnostics": "off"`. |
| `opened:` | A tab the action's own page opened (a popup, or a link that opens a new tab). It is not shared; its URL counts as an observed link. A tab a person or another window opened meanwhile is neither reported nor an observed link. |
| `No visible change.` | Nothing above changed. |

`cost` states `bytes` (the size of the text block), `settleMs` (time spent waiting for the page) and `totalMs`, and
`truncated` when a limit cut the report. Optional arguments on these tools:

- `result`: `delta` (default) or `full`, the whole page and observation as before.
- `budget`: `maxBytes` (1,000–60,000, default 4,000) caps the reply text for `delta`; the report gives up detail in
  steps (page text, text blocks, changes, additions) until it fits. `settleMs` (200–5,000, default 1,500) is the longest
  wait for the page to go quiet.
- `screenshotOnFailure`: `element` or `viewport` attaches a small JPEG (at most 60 KB and 640 px wide) when the action
  fails: the element first, then the viewport. Refused wherever a screenshot is.

**Waiting.** After an action the page is asked once and answers when its DOM and finished resources have been quiet
for 120 ms (the highlight ring does not count), or at the ceiling. A navigation the action started is followed to its
end. A request still running when the page goes quiet is not waited for; use `waitForPage`. A page that never stops
changing costs the `settleMs` ceiling.

**Refs.** `observationID` is optional for a ref. A ref is accepted while the client was given it for the current
document and its control is unchanged (kind, label, id, name, type, link target and form target). A ref from another
document, or of a control that changed under the client, is refused: a ref keeps the state its control had when the client
last saw it listed (in a read or in a report), so a control that changed and was not listed again stays refused until the
page is read. An `observationID` that is sent must still be the
latest. A failed action leaves the client's observation as it is.

### Development access

`requestAccess` with `development: true` adds an **Allow Development** choice to the prompt. Development includes control, and is also refused wherever **Assistant Access** is No Access or Read Only for the site. A prompt that was not asked for development cannot grant it. Development tools reply with a structured `status`: `ok`, `unsupported`, `invalidInput`, `stale`, `denied`, `ownershipConflict` or `pageGone`; every status except `ok` is a tool error and carries a `message`.

**One owner per tab.** The first connection to change a tab (viewport, emulation or diagnostics) holds its development lease; another connection gets `ownershipConflict` and nothing is changed. The lease is bound to the exact page view and document generation it was granted on. It ends with `resetDevelopment`, disconnect, the grant or site access dropping below development (checked at the start of every call and again when a site policy changes), the tab's page view being replaced (for example an engine change), a navigation that commits outside the grant, a reloaded page outside the grant, or the tab closing. A call already running on a page that is replaced or left does not return its result. Ending the lease removes the viewport, emulation and diagnostics; `resetDevelopment` and a refused reload return only after that cleanup has run. Nothing is persisted.

| Profile | Portrait (CSS px) | Notes |
| --- | --- | --- |
| `responsive-phone` | 390 × 844 | Viewport size only; any engine |
| `responsive-tablet` | 768 × 1,024 | Viewport size only; any engine |
| `responsive-desktop` | 800 × 1,280 | Viewport size only; any engine |
| `phone` | 390 × 844 | Also device pixel ratio 3, touch, mobile viewport; Chromium only |
| `tablet` | 768 × 1,024 | Also device pixel ratio 2, touch, mobile viewport; Chromium only |

`phone` and `tablet` are mobile emulation: a page without a `<meta name="viewport" content="width=device-width">` tag is laid out at 980 CSS pixels (measured on Chromium), so the call reports `unsupported` that the page did not reach the requested viewport and changes nothing. On Chromium a viewport or device change reaches the page only while the tab is on screen in a window that is brought forward; a window behind other apps keeps the page at its old size, which the call reports the same way.

Landscape swaps the axes, so `responsive-desktop` in landscape is 1,280 × 800 (`orientation` is required; there is no default). The viewport may be larger than the window; the page is clipped and native pointer input outside the visible part stays unavailable (`hoverOnPage` says so). WebKit has no device pixel ratio, touch or mobile override: a device profile is rejected before anything changes. Overlapping viewport and device changes on one tab are serialized, so the result matches the last one applied.

**Diagnostics coverage.** Console and network records cover the main document only, from `startDiagnostics`. Chromium uses DevTools events of the main frame; redirect hops of a main navigation before it commits are not recorded, and requests still in flight when the document changes are dropped unless they belong to the new document (`lostInFlight` counts per document). WebKit uses a hook injected into the current document and, from `startDiagnostics` until `resetDevelopment`, a copy of it as a document-start script of that tab, so every later document is hooked before its first script runs: console, uncaught errors, unhandled rejections, `fetch` and `XMLHttpRequest`, plus resource loads (images, scripts, stylesheets, fonts, frames) from the page's resource timing. The hook holds the first 128 events of a document until the capture attaches, then delivers them in order with the time they were delivered; older events beyond that are counted in `lostEarly`. A window the page opens shares the tab's content controller, so the hook runs there too, but nothing it records reaches the capture. The hook never runs page code to describe a value: console objects and proxies appear as `[object]`; a genuine `Error` appears as its name and message and contributes its stack when `name`, `message` and `stack` are plain data properties of it; `fetch` reports a URL only for a string argument and a method only for `fetch(url)` without an init (GET), and a `Request`, `URL` or `RequestInit` argument leaves them `null`. It cannot tell a built-in the page patched before the hook attached from the platform's own, which the document-start install reduces to nothing for documents loaded after the capture began.

**Record fields.** Records never hold headers, bodies or cookies. Every network record has `method`, `url`, `status`, `durationMs`, `outcome`, `type`, `mimeType` and `transferBytes`; unknown is `null`, never `0` or a guess. The URL keeps scheme, host, port and path; userinfo and fragment are removed. The query is concealed so that a client cannot confirm a guess of a secret by making the page request it: a parameter name stays only if it is plain (an identifier of up to 32 characters, such as `utm_source` or `filter[category]`, with no hex run and nothing token-shaped); any other name is concealed like a value. A value that looks like a generated token (at least 16 characters of letters, digits and `_-+/=.~:`, mixed, with enough variety and entropy; a session id, key, UUID, JWT or base64 blob) becomes `~` and 16 hex digits of an HMAC-SHA256; every other value is guessable and shows only a length class, `*short` (up to 8 characters), `*medium` (up to 32) or `*long`. A parameter without a value (`?<code>` or `?<code>=`) is concealed whole, because its name may be the secret. The tag key is random, never shown, and replaced when the document changes and when an agent navigates (`navigate`, `goBack`, `reloadPage`), so a tag matches another only inside one document, never across documents or captures, and cannot be turned back into a value. The rule is a heuristic with a ceiling: inside one document, an agent that can make the page request a value can still confirm a guess of a value that looks generated. At most 32 parameters are kept (then `&…`); a URL over 2,048 bytes is cut; each flags the record `truncated`. `type` is `document`, `stylesheet`, `image`, `media`, `font`, `script`, `xhr`, `fetch`, `ping`, `websocket` or `other`; `mimeType` is the media type without parameters; `transferBytes` is the size on the wire. A Chromium redirect adds a record per hop with its `status` and a sanitized `redirectTo`. WebKit has these per source: `fetch` and `XMLHttpRequest` records carry status, `mimeType` and timing but no size and no redirect hops; resource-load records carry `type` (from the initiator and file extension), size when the server exposes it and timing, but no `method`, `mimeType` or `status`.

```json
{"seq": 7, "timestamp": "2026-10-17T12:00:00.123Z", "documentID": "…", "truncated": false, "source": "cdp", "outcome": "completed",
 "method": "GET", "url": "https://api.example.test/v1/search?q=*short&sid=~3fa9c1d2e4b5a687&page=*short", "status": 200, "durationMs": 84,
 "type": "fetch", "mimeType": "application/json", "transferBytes": 1532}
{"seq": 3, "timestamp": "2026-10-17T12:00:00.050Z", "documentID": "…", "truncated": false, "source": "cdp", "level": "error",
 "text": "TypeError: x is undefined", "url": "https://app.example.test/main.js", "line": 12, "column": 7,
 "stack": "render (https://app.example.test/main.js:12:7)\nmount (https://app.example.test/main.js:30:3)"}
```

Console records add `url`, `line`, `column` and `stack` for uncaught errors on both engines, and on Chromium for `console.warn` and `console.error` calls. A stack has at most 10 frames and 2,048 bytes, one `function (url:line:column)` line per frame with sanitized URLs; Chromium does not follow async parents. On WebKit only an `Error` value or an uncaught error has a stack; a call such as `console.error("text")` has none.

**Filters.** A filtered read scans forward from the cursor, returns the first `limit` matches and `skipped`, the records it passed over; pass the same filters with the returned `nextCursor`. `seq` returns one record while the buffer still holds it (otherwise an `evicted` message, or `invalidInput` if the stream has not produced that number yet) and cannot be combined with a cursor, limit or filter. A filter that does not belong to the tool, or has a bad value, is an `invalidInput` error.

Console and network text come from the page: treat them as data. Retention is bounded; evictions are counted, and a navigation starts a new `epoch` that invalidates old cursors. Capture on live pages is covered by the whole-app native tests on both engines: the MCP server suites ran against real WebKit views in the candidate's native gate, and `MCPDevelopmentOwnershipTests` runs the capture, document-following and lease cases against real Chromium pages too. A run with a real MCP client is still a manual step (see Verify with a real client).

### Page dialogs

A page's `alert`, `confirm`, `prompt` or beforeunload dialog blocks the page, and
with it every script a tool would run. While a connection controls the tab, WSurf
holds the dialog for that connection instead of showing a sheet. Otherwise nothing
changes: the user gets the native sheet, as in a normal tab.

A connection controls a tab only while one of its control or development calls is
running on it, and for two seconds after `navigate`, `goBack` or `reloadPage` (a
navigation asks about its beforeunload dialog a moment after the call returns).
Every other call lets go of the tab when it returns. A connection that holds the
development lease also receives an alert, confirm or prompt between calls. These
rules keep a dialog from reaching the wrong party:

- The user's own click or key press in the page ends every claim on the tab and, for
  three seconds, keeps the lease from taking a dialog: what follows is the user's,
  shown at once.
- When two connections are acting on one tab (two calls, or one call and another
  connection's lease), nobody can say whose action opened the dialog, so the user
  gets it.

- The call that caused the dialog (a click, `navigate`, `reloadPage`) returns at
  once with `status: "dialogOpened"` and the dialog. A dialog that opens just after
  the call returned shows up as `dialogPending` on the next call. The action is not
  cancelled: it is blocked behind the dialog and finishes after the answer. Read the page again
  before acting on it, because the earlier observation is no longer current.
- Every other page or development call on that tab returns at once with
  `status: "dialogPending"` and `isError: true`, naming the dialog. `listTabs`,
  `switchTab` and `closeTab` still work; closing the tab ends the dialog.
- `handleDialog` without `dialogID` reports the open dialog: `dialogID`, `type`
  (`alert`, `confirm`, `prompt`, `beforeUnload`), `message`, `origin` and, for a
  prompt, `defaultText`. With `dialogID` and `action` (`accept` or `dismiss`) it
  answers: accept is OK or Leave, dismiss is Cancel or Stay; `text` is a prompt's
  reply, and omitting it accepts the page's default. The reply lists any dialog that
  the freed page opened next. A dialog answered once cannot be answered again.
- The message, default text and origin come from the page. They are bounded
  (1,000 characters, `truncated` says so), control characters become spaces, link
  queries, fragments and credentials are removed, and the text is wrapped as
  untrusted. `origin` is scheme, host and port only.
- WSurf reads dialog wording after normalizing it (compatibility forms, case,
  accents, zero-width and other invisible characters, look-alike letters, and digits
  used as letters), so hiding a word that way does not change what it matches.
- The user keeps what a connection must not decide. The connection can see these
  dialogs (`userMustAnswer: true`) but gets `denied` if it tries to answer:
  a prompt whose message asks for a password, PIN, code, card or secret; a
  beforeunload after the connection has answered Stay twice on the same document;
  and any dialog the connection leaves unanswered for 60 seconds, whose native
  sheet is then shown. A beforeunload is held only for a call that is acting on
  the tab, never for a lease alone, so a connection cannot hold the user on a
  page. Disconnecting hands every dialog it held to the user. WSurf never
  answers a dialog for the user and never accepts or dismisses one on a timeout.
- Accepting a dialog can carry a decision, so the user approves in WSurf first. A
  `confirm`, beforeunload or `prompt` whose message (or a prompt's reply) names a
  purchase, payment, transfer, deletion or posting asks, naming what it does. A
  `prompt` is also the user's own words in the page, so every accepted reply asks
  (the question shows the reply), except from a connection with development access
  on a page on this Mac (`localhost`, `127.0.0.1`, `[::1]`), which is asked only for
  the decisions above. Dismissing never asks. This development gate is a stand-in
  for the Developer tier and has one place to change when that arrives.
- Dialogs on tabs no connection controls, in the in-browser assistant's tabs and in
  private windows are never routed.
- WebKit has no beforeunload prompt in WSurf, so navigation away never produces
  one. Chromium shows it only to a page that has had user activation.
- A connection cannot type a secret into a prompt; the user does.

### Safe selectors

A CSS selector is evaluated against the page, so an attribute test such as `input[type=hidden][value^=a]`, also under `:has()`, would read a value one character at a time. Selectors passed to `waitForPage`, `findElements` and `readPage` scope are therefore parsed by the browser first (escapes, case and namespace forms such as `v\61lue` or `[*|value]` are normalised) and may test only attributes WSurf already exposes: `id`, `class`, `role`, `type`, `name`, `for`, `alt`, `title`, `placeholder`, `lang`, `dir`, `target`, `rel`, `aria-*`, the test attributes `data-testid`, `data-test`, `data-test-id`, `data-cy`, `data-qa` and `data-automation-id`, and a few boolean or numeric ones (`disabled`, `checked`, `hidden`, `width`, `min`…). `href` and `src` may be tested for presence only. Any other attribute test, including `value`, other `data-*` and `on*`, is refused with an explicit error rather than answered with an empty result. A selector is at most 2,048 UTF-8 bytes, enforced natively (a `readPage` scope longer than that is refused before anything is read). Structural attributes such as `id`, `class` and `name` can still be probed, including on hidden inputs: they are page structure, not values, and value-bearing attributes cannot be tested. Structural selectors, classes, ids and `:has()` without such tests work as usual.

### Selector targets

`clickOnPage`, `typeOnPage`, `selectOption`, `setChecked`, `hoverOnPage` and `pressKey` take `selector` instead of `ref` and `observationID`. The selector must match exactly one visible control that `readPage` would list (a button, link, field, select, checkbox, radio, combobox or scroll area, as the tool allows); the control is then treated exactly like a ref it listed, so every guard of that tool applies: sensitive fields are refused, disabled and covered controls are reported, consequential labels ask for approval. Test attributes work (`[data-testid=save]`, `data-test`, `data-cy`, `data-qa`, `data-automation-id`). A selector with several visible matches is refused with their count; a selector for hidden elements or for something that is not a control says so.

A selector reads the page's structure, so it needs **development access**, as `findElements` does; a control grant has to use refs. It is evaluated only in the document of the tab that was shared (the document, same-origin frames and open shadow roots; a cross-origin frame finds nothing), and only the safe subset in the next-but-one section is accepted. The result carries the page's observation as usual, and a selector call needs no earlier `readPage`.

### Key chords

`pressKey` accepts `modifiers`, for example `shift+option`. The boundary is default-deny and is checked before any event is created: a refused chord reaches neither the page nor the app. It exists because both engines hand a key the page leaves unhandled back to WSurf's menu: a Command+W that a page ignores would run the menu's Command+W.

| Allowed | Notes |
| --- | --- |
| Shift and/or Option with any named key or one printable character | `Shift+Option+ArrowLeft`, `Option+B`; a shifted symbol such as `?` implies Shift |
| Command with `A` | Select All, completed natively when the page does not handle it |
| Command with `Z`, `Shift+Z` | Delivered to the page's key handlers; their menu items are Undo and Redo |
| Command or Command+Shift with an arrow key; Command with `Backspace` or `Delete` | Text fields only: elsewhere an unhandled one would reach the menu (Command+Left is Back) |
| Command with `Enter` | Any control; `Enter` and `Space` on a consequential control ask for approval, like a click |

Never sent: Control in any combination; Command with Option; Command with anything else, including clipboard shortcuts (`C`, `X`, `V`) and app shortcuts (`W`, `Q`, `T`, `N`, `L`, `R`, `P`, `S`, `O`, `F`, `H`, `M`, `,`, `Tab`, `Space`). A key that is sent goes to the page's own view only, as a trusted key event, never through the application, a window or a menu directly. A test walks WSurf's real main menu with every chord the parser accepts and fails if one could reach an app command; the only commands an accepted chord can reach are Select All, Undo and Redo, plus Back and Forward for Command+Left and Command+Right, which only a text field receives and handles itself. Browser editing defaults depend on the engine: Select All is completed by WSurf; undo and redo are not forced when the page leaves `Command+Z` unhandled.

### Drag

`dragOnPage` has two modes. The default dispatches the DOM events of a drag at the pointer positions along a straight path (five points): `dragstart`, `drag`, `dragenter`, `dragover`, `drop`, `dragend` for a `draggable` source, pointer and mouse events otherwise. They are untrusted (`isTrusted` is false), work with the window in the background on both engines, and are refused when the path crosses a frame, a file input, a disabled control or a sensitive field. `pointer: true` sends trusted pointer input (`isTrusted` is true): on Chromium through DevTools mouse events, with the button held while it moves; on WebKit as native mouse events through the window, which reach it with WSurf in the background (unlike `hoverOnPage`) but do not mark the button as held during the moves. Both need the tab on screen. A source that starts a browser drag session (a `draggable` element, an image, a link, selected text) is refused in pointer mode, because synthetic input cannot complete that session; use the default mode for it. Refs need the observation of the latest read; selector and offset ends need none, but selectors need development access. A consequential label on either end (for example a drop target named Delete) asks for approval, as a click would.

## Verify with a real client

The automated suites call the MCP server inside the test host. This procedure checks the whole path with a real client:
the relay, the socket, the access sheet, the page tools, the development tools and shutdown. A person must be at the Mac
to answer the access sheet. Use a Stage app, which has its own profile, tabs and MCP socket and so never touches your
normal WSurf. Nothing here bypasses consent.

1. Build and launch an owned Stage Debug app as CONTRIBUTING.md describes in "Stage the app for screenshots and video"
   (`WSURF_STAGE=1`, `WSURF_STAGE_HOME="$stage_home"`). Keep the app running.
2. In that app, open **Settings → Advanced → External Connections** and switch on **MCP server**. Do not use **Add**: the
   Stage app's install action writes your real client configuration.
3. Run the scripted client, which behaves like any stdio MCP client and serves its own fixture page on `127.0.0.1`:

   ```bash
   python3 -I Tools/mcp-smoke/mcp_smoke.py --app /path/to/owned/WSurf.app --stage-home "$stage_home"
   ```

   It prints the fixture address. Open it in the Stage window, press Return, and choose **Allow Development** on the
   access sheet. It then calls `initialize`, `tools/list` (29 tools), `requestAccess`, `listTabs`, `readPage`,
   `screenshotPage`, `getDevelopmentInfo`, `setViewport`, `emulateDevice` (`phone`), `startDiagnostics`, `readConsole` and
   `resetDevelopment`, closes stdin, and expects the relay to exit 0. Every step prints `PASS` or `FAIL`; the exit code is 1 if any failed.
4. Repeat step 3 with the fixture page on Chromium: in the Stage app open **Settings → Websites**, choose `127.0.0.1`,
   set **Browser engine** to Chromium (this reloads the tab), and run the script again with `--engine chromium`; the phone
   profile must then apply instead of being rejected. Each run is a new connection, which is what access needs: it is
   requested once per connection.
5. Run the same path with Claude Code itself. Register the Stage app for this project only, so nothing else changes:

   ```bash
   claude mcp add wsurf-stage --scope local -e WSURF_STAGE=1 -e WSURF_STAGE_HOME="$stage_home" \
     -- /path/to/owned/WSurf.app/Contents/MacOS/WSurf --mcp
   ```

   Start `claude` in that project, run `/mcp` and check that `wsurf-stage` is connected with 29 tools. With the fixture
   page open in the Stage window, send:

   > Use the wsurf-stage MCP server. Call requestAccess with development true, then listTabs. For the tab on 127.0.0.1
   > call readPage, screenshotPage, getDevelopmentInfo, startDiagnostics and readConsole, then resetDevelopment.
   > Report each tool's status and any error text.

   Choose **Allow Development** when the sheet appears. Afterwards run `claude mcp remove wsurf-stage --scope local`, quit
   the Stage app and delete the stage home you created.

Record the WSurf commit, the output of `claude --version`, the engine, and one line per tool call (status or error). The
run passes when every call succeeds, `readConsole` returns the fixture's `smoke tick` records, and the relay exits cleanly.
It does not cover signed-build features (Keychain, passkeys, Apple Passwords), which need a signed app.

## Privacy boundaries

- Connecting and discovering tools disclose no tabs or page content. Every
  connection starts with no grants. The displayed client name is supplied by
  the client; it is not a verified app identity. A pairing token identifies an app
  you configured, not its code signature.
- Access is restricted to the captured tab IDs and their website origins. Other
  tabs, private browsing, internal pages, and denied sites cannot be listed or
  addressed by guessing an ID. Redirecting to another website does not grant
  access to its contents. Reconnect and request sharing again when needed.
- External sharing grants are separate from the assistant's site grants.
  **Assistant Access: No Access** blocks external access; **Read Only** blocks external
  control even when the connection has a control grant. External sharing does
  not change those settings.
- The existing page driver detects and masks sensitive fields and refuses to
  fill them. Consequential actions use WSurf's native confirmation UI. External
  confirmations do not inherit the assistant's saved action approvals; any
  remembered approval lasts only for that connection.
- External page scripts run in WebKit's isolated client world. Observation IDs
  belong to one connection and one document. A read or an action takes a new
  snapshot, but a ref the connection was given stays usable for its document
  while the control is unchanged; an observation ID that is sent must be the
  latest. Revocation and navigation are checked again after suspension and
  before returning page data.
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

## Seeing a connection and stopping it

While an external app holds a grant for a tab in a window, that window's toolbar shows a badge with the app's name and
its widest access, such as "Claude Code · Development". The badge stays for as long as the connection holds a grant or a
development lease. It shows a spinner while a call works on one of the connection's tabs. Click it to see the tabs the
app can use and a **Stop** button. VoiceOver announces the badge when it appears; its popover and **Stop** work from the
keyboard.

**Stop** is always reachable: the **Stop** button in the badge, **View › Stop External Connections** (⌥⌘.), and the
command palette. It ends every connection bound to that window at once:

- the running call is cancelled and returns nothing;
- development leases are released, so viewport, emulation and diagnostics are removed;
- the connection's grants and remembered action approvals are revoked and its socket is closed;
- other windows' connections are not touched.

The client can reconnect on its next call, but it starts with no access and the user has to approve it again.

Agent Activity shows an "External: *client*" group under the tab's own tasks. It lists, per call, the time, the tool,
the element number, the outcome (succeeded, failed, stopped) and, for `navigate` and `newTab`, the host. It never holds
tool arguments, typed text, page content or tool output. The log lives in memory for the app session, keeps the latest
1,000 entries per connection and the logs of the last 8 connections that ended, and is gone when WSurf quits.

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
