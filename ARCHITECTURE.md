<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Architecture

WSurf is a macOS SwiftUI app with default WebKit and on-demand embedded Chromium
through CEF. Swift 6 strict concurrency and Main Actor default isolation are enabled.

## Runtime structure

```mermaid
flowchart LR
    App["AppDelegate"] --> Application["BrowserApplication"]
    Application --> Coordinator["AppCoordinator per window"]
    Application --> MCP["App-wide MCP listener"]
    Coordinator --> Context["BrowserProfileContext"]
    Coordinator --> Browser["BrowserModel"]
    Coordinator --> Turns["AgentTurnModel"]
    Turns --> Agent["AgentRunner"]
    Coordinator --> Input["Voice and keyboard input"]
    Browser --> Tabs["BrowserTab"]
    Tabs --> Process["TabProcessState"]
    Tabs --> Page["BrowserPage"]
    Page --> WebKit["WKWebView"]
    Page --> Chromium["ChromiumPage / CEF"]
    Agent --> Toolkit["AgentToolkit"]
    Tabs --> Access["TabAssistantAccessCenter"]
    Access --> Permissions["SitePermissions"]
    Toolkit --> Access
    Access --> Driver["PageDriver"]
    Driver --> Page
    Context --> Stores["Profile stores"]
    Turns --> Log["ConversationLog"]
    Stores --> Database["AppDatabase / GRDB"]
    Log --> Database
    Coordinator --> Views["SwiftUI views"]
```

`BrowserApplication` owns the window registry, startup/restoration, external-link
routing and MCP listener. Each `AppCoordinator` owns one window's browser,
selection, assistant task, voice input and presentation. Views use their owning
coordinator, never the application's currently focused window as a service locator.

`VoiceInputModel` owns microphone and transcription state. `AgentTurnModel`
owns one turn’s task, reply, tab activity and durable completion state. Both
models expose small observable values while their service dependencies stay
outside observation.

## Browser state

`BrowserModel` owns tab and folder order, activation, session restoration and
history integration. `BrowserTab` owns a `BrowserPage` backed by exactly one
WebKit or Chromium view. `TabProcessState` owns process-protection signals,
unload status and unexpected-termination throttling. `WebViewPool` prepares
WebKit views without owning tab state.

A restored tab holds no browser view until opened. `BrowserTab.page` builds the
selected engine on first use; callers iterating tabs must check `isMaterialised`
before accessing it. Unloading retains the link and metadata, not live page
content. WebKit can restore native interaction state; Chromium restores only
the URL. An engine switch reloads without replaying submitted requests and
awaits the old browser's actual close acknowledgment before installing its replacement.

`BrowserProfileContext` owns the profile's database, permissions, WebKit data store,
pool, extensions, downloads, history, favicons, model settings and assistant grants.
Regular windows of a profile share one context. Each private window gets a distinct
context ID, non-persistent WebKit store, CEF request context and in-memory database,
even though private Profile UUIDs are equal. Never add profile identity as a column
to a shared persistent store. Private teardown waits for only that context's CEF
pages to acknowledge closure.

Profile selection belongs to the window. Switching it revokes that window's MCP
connections and extension registration before replacing its browser context; other
windows continue using their existing context. Context-owned engine-preference
notifications reach every registered browser in the same context. Appearance and
provider definitions remain application-wide; website settings, selected models
and assistant approvals are profile-local.

Window sessions use window IDs, composite item keys, revisions and retirement
guards. Legacy profile sessions migrate transactionally, preserving Favorites,
pins, folders, splits and native WebKit state. A live transfer requires the same
context and session writer and open registered owners. It moves the same tab/page/
native view without navigation, cancels source assistant/voice/media/Peek activity,
rebinds callbacks, invalidates both sidebar Undo histories and saves both windows
atomically. Closed or superseded owners cannot resurrect tabs with queued saves.

`ChromiumRuntime` initializes CEF only for the first Chromium page and stays
initialized until quit because CEF cannot be restarted in-process. Its AppKit
application subclass is installed at startup without loading Chromium.
The native child host view must be released to receive `on_before_close`; a
tab closes that child, never the containing WSurf window.

External-app approvals require a proven requesting origin and app identity.
Ambiguous, inherited or opaque sources may request one-time consent but cannot
reuse or persist an origin grant. WebKit binds suspended offers to its document
and main-frame navigation generation. CEF binds them to native frame/document
epochs plus cached DevTools document/origin identity: renderer RPCs cannot
validate a handoff while an unrelated top-level navigation suspends those RPCs.
Native detach, replacement, non-aborted load failure, termination and close invalidate the offer;
CEF frame IDs are not DevTools frame IDs. Ordinary JavaScript and permission
operations retain their asynchronous live-document checks.

## Agent trust boundaries

The model is not a security boundary. Page text is untrusted, even when the
model describes it as an instruction.

- `AgentToolkit` exposes the supported browser actions.
- `TabAssistantAccessCenter` authorizes visible-page reads and controls by
  origin before `AgentToolkit` reaches the page driver.
- `PageDriver` resolves actual page elements and enforces sensitive-field and
  consequential-action rules.
- `AgentActionConsent` asks from trusted app UI. The model cannot suppress it.
- `AgentActionPolicy` stores narrow, revocable category-and-host grants.
- `ConversationLog` persists the activity trail inside the active profile.

Background research uses a non-persistent WebKit data store for each task. It
does not inherit cookies, logins or website storage from the active profile.
Loading the chosen result into a tab does not grant the assistant access to it.

Add enforcement below the model prompt. Prompts can improve behavior but cannot
authorize access, protect credentials or confirm an irreversible action.

External MCP clients use a separate `MCPBrowserSession`, with explicit tab-and-
origin grants and connection-local consequential-action approvals. The session
uses `PageDriver` through a revocable `PageAutomationGuard`; it does not enter
`AgentTurnModel` or write assistant conversation history. Each connection binds to
one regular window when it connects. Focus changes do not retarget it; closing or
switching that owner revokes its connections without disrupting another window.
Consent sheets attach to the originating registered native window.

MCP enablement and the listener are application-wide. New connections are refused
while the focused window is private; existing regular-window connections remain
bound. Shutdown clears connections and grants without changing the preference.
The bundled `--mcp` process relays event-driven stdio to a user-only Unix socket
without opening another browser session. See [MCP.md](MCP.md) for its boundaries.

`MCPClientInstaller` handles optional client setup on its own actor. It merges
standard JSON configs and uses the installed Codex CLI on a staged TOML copy.
`MCPConfigurationFile` owns private backups and checked atomic replacement.
These services have no browser, profile, assistant, or sharing-grant dependency.

## Assistant execution and context

Providers propose actions. WSurf checks permissions, runs each action once, and
saves its result in a checkpoint. Resuming an interrupted task preserves user
answers and requires verification before retrying an action with an unknown outcome.
Repeated failures or unchanged results eventually pause the task.
Rate-limit recovery retries only safe model generation within the request budget,
not completed or uncertain browser actions. Exhaustion saves a resumable checkpoint
without requesting another summary. Visual no-progress detection ignores pointer
coordinates and screenshot variation on an unchanged page.

Conversation messages, attachments and checkpoints belong to the originating
profile, which stays task-local across awaits and focus changes. They are private
conversation data, not diagnostic exports. Deleting a turn also
invalidates checkpoints that may contain it. `AgentRunDiagnostics` exports only
approved event names, counts, timings, and status values. It excludes prompts,
answers, page content, URLs, tool arguments, credentials, and raw provider errors.

Automatic and manual compaction use the selected provider. The portable compactor
summarizes chronological evidence in bounded slices. It preserves the latest user
request, exact answers to questions, and complete recent tool exchanges where they
fit. Page content and tool results remain untrusted input. A failed or cancelled
compaction leaves the original checkpoint intact. On-device compaction stays on
device. The OpenAI adapter also preserves native Responses state.

The context indicator estimates occupancy, including tool definitions. It does
not report measured provider token usage. Progress updates remain in private chat
history; diagnostics record only their event type and status.

See [OpenAI integration](OPENAI.md) for provider configuration and validation,
and [Browser autofill](WSurf/Web/Autofill/README.md) for form and credential handling.

## State and SwiftUI

Shared mutable models use Observation. View-local state is private. A distinct
screen or independently changing section should be a real `View` type with
narrow inputs; a computed `some View` property does not create an observation
boundary.

Use the components and metrics in `WSurf/UI/Chrome` and
`WSurf/Settings/SettingsPrimitives.swift`. `Theme` owns shared visual tokens.
User-facing strings remain localizable; protocol values, URLs, model IDs and
third-party error text remain verbatim.

## Persistence

GRDB stores structured browser and agent data. Small preferences use
`UserDefaults`; provider secrets use Keychain. File-backed models — profiles,
website permissions, page zoom and the download list — use atomic writes through
the support layer. A write needed for quit or profile teardown
must be awaited or flushed synchronously before its owner is released.

## Tests

Tests use Swift Testing, with XCTest for the two things it cannot express:
performance baselines (`XCTMetric`) and a test that drives the main run loop.
Prefer pure parsing and policy functions, injected stores, temporary databases
and local WebKit fixtures. `HTTPFixtureServer` serves deterministic loopback
pages for navigation and origin-boundary tests. A test should assert a
user-observable result or an enforced invariant. Live services and fixed sleeps
do not belong in the default suite.

Tests use a per-process temporary directory from `AppDatabase.supportDirectory`.
Profiles, permissions, zoom state and the download list do not access an
installed copy’s support directory.

`WebViewGate` bounds how many cases hold a live `WKWebView` at once, at half the
machine’s cores. The `.boundedWebViews` trait takes a slot; apply it to the
tests that build a view rather than to a whole suite, so the rest do not queue
for a resource they never use.

`WSurf.xctestplan` turns on per-test timeouts: 120 seconds by default, 300 at
most. A stalled test times out and reports its name without blocking the full run.

CI runs the full suite with code coverage and rejects app-target coverage below
the repository floor. See [CONTRIBUTING.md](CONTRIBUTING.md) for the change
checklist.
