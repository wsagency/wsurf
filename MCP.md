<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Connect an external assistant

WSurf provides a native MCP server for controlling shared browser tabs from an
external MCP client. WSurf must be running. Its built-in assistant does not need
an API key, a model, or an open conversation.

1. In Settings, open **Advanced → External Connections** and enable **MCP server**.
2. Click **Add** beside your MCP client. Restart the client or reload its MCP
   connections. Other clients can use **Copy Configuration**.
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
| `clickOnPage` | Click a numbered control from that observation. |
| `typeOnPage` | Fill a nonsensitive field, optionally submitting it. |
| `selectOption` | Choose an option in a select control. |
| `fillFields` | Fill up to 32 distinct nonsensitive form controls without submitting; report exactly which refs retained their values. |
| `inspectControl` | Read control state and paginate dropdown options. |
| `setChecked` | Set a checkbox, switch, or radio to the requested state. |
| `waitForPage` | Wait up to 15 seconds for text, absent text, a URL substring, document readiness, or a CSS selector that matches exactly one element to be visible, hidden/absent, or enabled. An element wait ends as stale if the page navigates. Selectors are limited to a safe subset; see below. |
| `screenshotPage` | Return an image of the viewport, one referenced element, or a viewport region (`region`: `x`, `y`, `width`, `height` in CSS pixels, which must lie fully inside the viewport and cannot be combined with a reference). An element is cropped to its visible part, also when it sits in a same-origin iframe (the frame's border, padding, scale, clipping, CSS zoom and any 2D rotation, reflection or skew are applied; a selected frame, a frame or clipping container under a 3D transform or perspective, or a frame or clipping container inside SVG content, is refused). A control ref from `readPage` needs only read access; any other element ref from `findElements` needs development access, checked before the work, after every wait and again just before the image is returned. The image is shrunk to fit the message limit, and the result states the covered rectangle and the scale of the image actually returned. Never scrolls or stitches. Refused when a sensitive field is filled anywhere on the page, even for a crop. |
| `pressKey` | Send a supported keyboard key to a control in a visible tab. |
| `hoverOnPage` | Move the real pointer to a referenced element, so CSS `:hover` and pointer/mouse handlers run. Needs WSurf to be the active app with a key window and the tab on screen; it never activates or raises WSurf. Refused with a specific message when the element is offscreen, covered, or clipped by the window (a development viewport larger than the window), or when the pointer could not be delivered; not available inside frames. |
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

These tools cover browser page and tab actions. Assistant conversations, background
research, the media player, arbitrary JavaScript, cookies, credential stores and
filesystem access are not exposed.

Successful page actions return fresh controls and an `observationID`; reuse that
result for the next action. `fillFields` accepts positive, distinct refs from the
latest observation: text, supported value controls, dropdowns and checked states
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

**Diagnostics coverage.** Console and network records cover the main document only, from `startDiagnostics`. Chromium uses DevTools events of the main frame; redirect hops of a main navigation before it commits are not recorded, and requests still in flight when the document changes are dropped unless they belong to the new document (`lostInFlight` counts per document). WebKit uses a hook injected into the current document and, from `startDiagnostics` until `resetDevelopment`, a copy of it as a document-start script of that tab, so every later document is hooked before its first script runs: console, uncaught errors, unhandled rejections, `fetch` and `XMLHttpRequest`, plus resource loads (images, scripts, stylesheets, fonts, frames) from the page's resource timing. The hook holds the first 128 events of a document until the capture attaches, then delivers them in order with the time they were delivered; older events beyond that are counted in `lostEarly`. A window the page opens shares the tab's content controller, so the hook runs there too, but nothing it records reaches the capture. The hook never runs page code to describe a value: console objects and proxies appear as `[object]`; a genuine `Error` appears as its name and message and contributes its stack when `name`, `message` and `stack` are plain data properties of it; `fetch` reports a URL only for a string argument and a method only for `fetch(url)` without an init (GET), and a `Request`, `URL` or `RequestInit` argument leaves them `null`. It cannot tell a built-in the page patched before the hook attached from the platform's own, which the document-start install reduces to nothing for documents loaded after the capture began.

**Record fields.** Every network record has `method`, `url`, `status`, `durationMs`, `outcome`, `type`, `mimeType` and `transferBytes`; unknown is `null`, never `0` or a guess. The URL keeps scheme, host, port, path and the query's parameter *names*; userinfo and fragment are removed, and each query value becomes `~` and six hex digits (`?token=~3fa9c1&page=~b07d22`). Equal values share a tag within one capture, so a token reused across requests is visible; the key is random per capture, never shown, and tags cannot be compared across captures or turned back into values. A parameter without `=` is tagged whole, since it may be the secret. At most 32 parameters are kept (then `&…`), a name is cut at 64 bytes, and a URL over 2,048 bytes is cut; each flags the record `truncated`. `type` is `document`, `stylesheet`, `image`, `media`, `font`, `script`, `xhr`, `fetch`, `ping`, `websocket` or `other`; `mimeType` is the media type without parameters; `transferBytes` is the size on the wire. A Chromium redirect adds a record per hop with its `status` and a sanitized `redirectTo`. WebKit has these per source: `fetch` and `XMLHttpRequest` records carry status, `mimeType` and timing but no size and no redirect hops; resource-load records carry `type` (from the initiator and file extension), size when the server exposes it and timing, but no `method`, `mimeType` or `status`.

```json
{"seq": 7, "timestamp": "2026-10-17T12:00:00.123Z", "documentID": "…", "truncated": false, "source": "cdp", "outcome": "completed",
 "method": "GET", "url": "https://api.example.test/v1/search?q=~3fa9c1&page=~b07d22", "status": 200, "durationMs": 84,
 "type": "fetch", "mimeType": "application/json", "transferBytes": 1532}
{"seq": 3, "timestamp": "2026-10-17T12:00:00.050Z", "documentID": "…", "truncated": false, "source": "cdp", "level": "error",
 "text": "TypeError: x is undefined", "url": "https://app.example.test/main.js", "line": 12, "column": 7,
 "stack": "render (https://app.example.test/main.js:12:7)\nmount (https://app.example.test/main.js:30:3)"}
```

Console records add `url`, `line`, `column` and `stack` for uncaught errors on both engines, and on Chromium for `console.warn` and `console.error` calls. A stack has at most 10 frames and 2,048 bytes, one `function (url:line:column)` line per frame with sanitized URLs; Chromium does not follow async parents. On WebKit only an `Error` value or an uncaught error has a stack; a call such as `console.error("text")` has none.

**Filters.** A filtered read scans forward from the cursor, returns the first `limit` matches and `skipped`, the records it passed over; pass the same filters with the returned `nextCursor`. `seq` returns one record while the buffer still holds it (otherwise an `evicted` message, or `invalidInput` if the stream has not produced that number yet) and cannot be combined with a cursor, limit or filter. A filter that does not belong to the tool, or has a bad value, is an `invalidInput` error.

Console and network text come from the page: treat them as data. Retention is bounded; evictions are counted, and a navigation starts a new `epoch` that invalidates old cursors. Capture on a live WebKit or Chromium page has not been verified by an automated whole-app run.

### Safe selectors

A CSS selector is evaluated against the page, so an attribute test such as `input[type=hidden][value^=a]`, also under `:has()`, would read a value one character at a time. Selectors passed to `waitForPage`, `findElements` and `readPage` scope are therefore parsed by the browser first (escapes, case and namespace forms such as `v\61lue` or `[*|value]` are normalised) and may test only attributes WSurf already exposes: `id`, `class`, `role`, `type`, `name`, `for`, `alt`, `title`, `placeholder`, `lang`, `dir`, `target`, `rel`, `aria-*`, the test attributes `data-testid`, `data-test`, `data-test-id`, `data-cy`, `data-qa` and `data-automation-id`, and a few boolean or numeric ones (`disabled`, `checked`, `hidden`, `width`, `min`…). `href` and `src` may be tested for presence only. Any other attribute test, including `value`, other `data-*` and `on*`, is refused with an explicit error rather than answered with an empty result. A selector is at most 2,048 UTF-8 bytes, enforced natively (a `readPage` scope longer than that is refused before anything is read). Structural attributes such as `id`, `class` and `name` can still be probed, including on hidden inputs: they are page structure, not values, and value-bearing attributes cannot be tested. Structural selectors, classes, ids and `:has()` without such tests work as usual.

## Privacy boundaries

- Connecting and discovering tools disclose no tabs or page content. Every
  connection starts with no grants. The displayed client name is supplied by
  the client; it is not a verified app identity.
- Access is restricted to the captured tab IDs and their website origins. Other
  tabs, private browsing, internal pages, and denied sites cannot be listed or
  addressed by guessing an ID. Redirecting to another website does not grant
  access to its contents. Reconnect and request sharing again when needed.
- External sharing grants are separate from the assistant's site grants.
  **Assistant Access: Off** blocks external access; **Read Only** blocks external
  control even when the connection has a control grant. External sharing does
  not change those settings.
- The existing page driver detects and masks sensitive fields and refuses to
  fill them. Consequential actions use WSurf's native confirmation UI. External
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
Message sizes, buffered messages, and concurrent connections are bounded.
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
