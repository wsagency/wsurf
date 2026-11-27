<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: BUSL-1.1 -->

# WSurf MCP v2 Design Specification

**Date:** 2026-11-24  
**Status:** Phases 1–4 implemented. Background Chromium pre-warming remains planned.

**Scope:** Native WSurf MCP Server (`WSurf --mcp`), Page Automation Runtime, Autofill/Vault Integration, Developer Tools, and Settings

---

## 1. Motivation & Problem Statement

WSurf MCP v1 established a strong privacy-first foundation (local Unix socket, Keychain-backed client pairing, per-tab consent, secret scrubbing, and Developer-tier diagnostics), but real-world agent workflows exposed four major friction points:

1. **Tab ergonomics:** Agents could not open a clean background tab with `newTab` unless they first called `requestAccess` on whichever tab the user happened to be viewing. Once shared, calling `navigate` or Playwright `browser_navigate` overwrote the user's own tab by default.
2. **Engine friction:** Agent-opened tabs inherited the site's default engine (typically WebKit) and required `development` access just to pick an engine, blocking reliable background Chromium automation and making Safari/WebKit testing awkward to toggle.
3. **Credential & form usability vs. Vault safety:**
   - Autofill marked username/email fields with `data-wsurf-password` and contact fields with `data-wsurf-contact`, causing write tools (`typeOnPage`, `fillFields`, `browser_type`, `browser_fill_form`) to refuse even non-secret username/email inputs.
   - Typing test or user-supplied passwords was restricted exclusively to `localhost` / Developer profile with explicit `secret: true`, making routine login flows fail under ordinary `Control` access.
   - There was no safe, blind-fill path for using credentials already stored in WSurf Vault without exposing passwords to the agent.
4. **DevTools password read-back gap:** On Developer-tier sites, `evaluateScript` and network/console detail capture relied on best-effort output redaction rather than hard blocking script execution and body/preview capture while a protected password is live in the DOM.

MCP v2 resolves these issues while **strengthening** the core security guarantee: no agent may ever read back a user-typed or Vault-filled password—neither through ordinary MCP tools nor through Developer Tools.

---

## 2. Locked Owner Decisions

The following architectural decisions are finalized for MCP v2:

1. **Password write under `Control` with automatic protection:**
   - Agents with `Control` access may write agent- or user-supplied passwords/OTPs into password/OTP fields directly (no `localhost`-only lock, no mandatory `secret: true`), governed by a Keychain-backed setting `allowsPasswordEntry` (off by default, with an additional opt-in for each paired app in Connected apps).
   - Every write into a sensitive secret field automatically suppresses autofill suggestions and save-password offers, registers the typed (and reformatted stored) value in `MCPSecretScrubber`, hides the value from tool replies, and masks filled sensitive fields in black in `screenshotPage`.
2. **WSurf Vault Blind Fill with 4-option native consent sheet:**
   - Agents can discover anonymized Vault availability via `vaultHint: { hasSavedLogin, requiresUserApproval: true }` on login pages (zero usernames, account counts, or passwords disclosed).
   - `requestUserLogin` presents a native WSurf sheet offering all four actions:
     1. **Fill** — WSurf writes username + password directly into the DOM without submitting.
     2. **Fill & Sign In** — WSurf writes username + password directly into the DOM and submits the form.
     3. **Sign In Myself (Take Over)** — Hands the tab to the user (`status: "waitingForUser"`).
     4. **Cancel / Decline** — Refuses without touching the form (`status: "declined"`).
3. **Chromium default for agent-opened tabs, switchable to WebKit:**
   - `newTab` defaults to `.chromium` when `engine` is omitted (except origins in `SitePermissions.webKitOnlyOrigins` such as `https://accounts.google.com` and `https://auth.openai.com`, which always use `.webKit`).
   - Any `Control`-tier caller can pass `engine: "webkit"` or `"chromium"` on `newTab` or switch an existing shared tab via `setTabEngine` to test Safari/WebKit behavior (while still enforcing `webKitOnlyOrigins`).
4. **`credentialTainted` DevTools & scripting secret guard:**
   - Whenever a document has been filled by WSurf Vault (`requestUserLogin`) OR currently holds any non-empty sensitive secret field not explicitly approved for inspection, `evaluateScript` is denied (`status: "denied"`, `code: "protectedSecretPresent"`), `readNetwork` omits `requestBody`/`responseBody` with `"omitted: protected credential form"`, and `readConsole` suppresses object `preview` payloads.
   - Protection clears automatically once navigation commits to a new `documentID` (and no filled protected sensitive field remains).
5. **Four-phase roadmap:** Phase 1 delivers tab defaults, credentials/Vault flow, `credentialTainted` guard, and Chromium default; Phase 2 focuses on speed optimizations; Phase 3 introduces the T3 Agent Micro Window; Phase 4 adds extended multi-tab and developer ergonomics.

---

## 3. Phase 1 — Core (Tab Defaults, Credentials/Vault Flow, Secret Guard, Chromium Default)

### 3.1 New Tab as First-Class Entry Point & User Tab Protection

- **`newTab(url, engine?)` without prior tab grants:**
  - An MCP client may call `newTab` immediately on a fresh connection with zero granted tabs.
  - Observed-link protection still applies once the connection has read untrusted page content (`hasReadContent == true`), unless covered by a standing grant or Developer-tier rule.
  - Authorization precedence:
    1. Site's explicit Assistant Access policy is `.deny` → refuse.
    2. Standing grant covers `url` → open in background immediately with that standing access.
    3. Paired app follows Website access default (`followsWebsiteDefault(at: url)`) → open in background immediately at `.control` (`.appDefault`).
    4. Otherwise → show one native `MCPAccessConsent.open` ("Open and Share This Website?") sheet for `url`. The user's active tab is neither touched nor shared. If approved, open in background at `.control` (`.sheet`).
  - Returns structured output `{ tabID, url, engine, background: true, message }` alongside readable text.
- **Protecting user-owned tabs on `navigate`:**
  - Tabs in `openedTabs` (created by this connection via `newTab` or `openComparison`) navigate in-place as before.
  - Tabs NOT in `openedTabs` (user's existing tabs shared via `requestAccess`):
    - By default (`inPlace` omitted or `false`), `navigate` opens the destination in a **new background tab** (added to `openedTabs`), leaving the user's tab completely untouched, and returns `{ tabID: newTabID, openedNewTab: true, url, engine, message }`.
    - Passing `inPlace: true` navigates the shared user tab in-place (subject to the same origin/consent rules).
- **Playwright `browser_navigate` auto-open:**
  - When the connection has no shared tab yet, or has no agent-opened tab yet and `playwrightTab` has not explicitly selected a tab, `browser_navigate(url)` routes to `newTab(url)` and binds `playwrightTab` to the newly created background tab.
  - Likewise, if `browser_navigate` triggers a user-tab-protected `navigate` that opens a new background tab, `playwrightTab` updates to that new tab automatically.

### 3.2 Chromium Default & `setTabEngine`

- **Engine resolution on `newTab`:**
  - Origin in `SitePermissions.webKitOnlyOrigins`:
    - `engine == nil` or `engine == .webKit` → `.webKit`.
    - `engine == .chromium` → refused with clear error explaining this website requires WebKit.
  - Any other origin:
    - `engine == nil` → `.chromium` (default for full background automation capabilities).
    - `engine == .webKit` or `engine == .chromium` → honored under `Control` (no `development` scope required).
- **`setTabEngine(tabID, engine)` (scope: `.control`):**
  - Switches a shared tab between `"chromium"` and `"webkit"` in-place (using `BrowserTab.switchEngine(to:)` cleanly without destructive user alerts).
  - Enforces `SitePermissions.webKitOnlyOrigins` (refuses switching those origins to `.chromium`).
  - Re-parks background tabs via `keepInWindow(tab)` so automation remains reachable without stealing focus.
  - Clears stale `observations`, `secretFields`, and `credentialTainted` entries for the retired page; preserves the tab's sharing grant.

### 3.3 Credential & Sensitive-Field Architecture (`Read != Write != Vault`)

#### 3.3.1 Separating Read Redaction from Secret Write Gating

- **`PasswordAutofillScript.swift`:**
  - Only actual password and OTP/code fields receive `data-wsurf-password`.
  - Non-secret autofilled username/email fields receive `data-wsurf-autofilled` instead.
- **`PageRuntime.swift` & `PageAccessibility.swift`:**
  - **`isSensitiveSecret(el)`**: true for `data-wsurf-password`, `data-wsurf-payment-card`, `type === 'password'`, secret `autocomplete` tokens (`current-password`, `new-password`, `one-time-code`, `cc-*`), and secret hint patterns (password, passcode, PIN, CVV/CVC, card number, IBAN, SSN, OTP, 2FA, recovery phrase, private key). **Does not** match `data-wsurf-contact` or `data-wsurf-autofilled`.
  - **`isSensitiveForRead(el)`** (and `isSensitiveField(el)` for reads): true for `isSensitiveSecret(el)` OR `data-wsurf-contact` OR `data-wsurf-autofilled`.
- **Consequences:**
  - Prior user-autofilled usernames and contact addresses stay hidden on `readPage`, `readAccessibility`, `inspectControl`, and `PageScripting` reads.
  - Writing to a username, email, or contact field via `typeOnPage`, `fillFields`, `browser_type`, or `browser_fill_form` is **never** blocked; overwriting removes the prior read-only autofill marker (`data-wsurf-contact` / `data-wsurf-autofilled`) without ever exposing the old value.

#### 3.3.2 Password & OTP Write Under `Control`

- **Keychain-backed setting (`MCPTrustStore`):**
  - `allowsPasswordEntry: Bool` (default `false`), stored in the data-protection keychain document alongside paired apps and developer settings, exposed as a toggle in **Settings › Assistant › Connected apps** (and referenced from External connections).
- **Eligibility:**
  - When a connection holds `.control` on a tab AND (`trust.allowsPasswordEntry` is `true` OR connection holds `.developer`), `typeOnPage`, `fillFields`, `browser_type`, and `browser_fill_form` may write into `isSensitiveSecret` fields without requiring `secret: true` and without requiring `localhost` / Developer profile.
  - Explicit `secret: true` remains supported as an opt-in hint for non-password fields (e.g., API keys in plain text inputs) under the same eligibility rule.
  - When `allowsPasswordEntry` is `false` (and not `.developer`), password/OTP writes are refused before touching the DOM.
- **Automatic protections on any write into a sensitive secret field:**
  1. Target sensitivity is checked before typing so values are registered in `MCPSecretScrubber` **before** DOM `input` listeners can echo them into titles, console, or network requests.
  2. The field is not focused (preventing autofill popups), must reside in the main document (not cross-origin/embedded frames), and triggers `finishSecretEntry` (dismissing `AutofillSuggestions` and clearing `tab.autofillSave`).
  3. Any reformatted stored value is also registered in `MCPSecretScrubber`.
  4. Tool output never echoes the value: `Typed into "<label>" (sensitive field, value hidden).`
  5. `screenshotPage` enables `ScreenshotMasking` (black-box masking of filled sensitive fields) under `Control` when `allowsPasswordEntry` is enabled as well as in `.developer`, still refusing if any filled sensitive field cannot be reliably measured.
- **Submit button policy:**
  - Plain login buttons (`Log in`, `Sign in`, `Submit`) remain clickable without a confirmation sheet.
  - OAuth / third-party account linking actions (`Continue with Google`, `Authorize`, `Grant access`, etc.) retain `SensitiveAction.Category.accountAccess` confirmation.

#### 3.3.3 Anonymized Vault Awareness (`vaultHint`)

- `readPage`, `readAccessibility`, and `inspectControl` always describe sensitive fields with their type and state (`(password, sensitive) = (empty)` / `(filled, hidden)`), never their value.
- When `readPage` or `inspectControl` detects a login/password form on a tab with a verified HTTPS origin (or test provider), WSurf checks the tab's unlocked Vault scope (`BrowserVaultScope` / `autofillCandidates()`, never reading secret payloads) and includes:
  ```json
  "vaultHint": {
    "hasSavedLogin": true,
    "requiresUserApproval": true
  }
  ```
- Usernames, account labels, account counts, and passwords are **never** exposed in `vaultHint`.

#### 3.3.4 `requestUserLogin` — Blind Vault Fill & Manual Take Over

- **Tool schema (scope: `.control`):**
  - `tabID` (required string)
  - `mode` (optional enum: `"vaultOrManual"` [default], `"vaultFill"`, `"manualLogin"`)
  - `reason` (optional string, max 200 UTF-8 bytes, untrusted)
  - `accountHint` (optional string, max 100 UTF-8 bytes, used only to prioritize matching accounts for the human sheet)
- **Behavior:**
  - `mode == "manualLogin"`: calls `handBack(tab)` so the user regains exclusive control, and returns `{ status: "waitingForUser", tabID, message }`.
  - `mode == "vaultOrManual"` / `"vaultFill"`:
    - Queries the injectable `MCPVaultProvider` (backed in production by the tab's `BrowserVaultScope` / unlocked `CredentialManager`s).
    - If `mode == "vaultFill"` and no saved login exists, returns `{ status: "noSavedLogin", tabID, message }`.
    - Presents native `MCPAccessConsent.LoginSheet` (testable data-only builder) showing the requesting client, target origin, optional sanitized reason, and saved account label(s) to the human only, with 4 choices:
      - **Fill**: retrieves `(username, password)` from Vault (only after approval), verifies tab URL/origin/connection still match, fills username + password directly into DOM via `PageDriver.fillVaultLogin(..., submit: false)`, registers password in `MCPSecretScrubber` (memory-only, wiped on disconnect), marks tab's current document `credentialTainted`, and returns `{ status: "filledByVault", submitted: false, fieldsFilled: [...], valuesHidden: true, documentProtected: true }`.
      - **Fill & Sign In**: same as Fill with `submit: true` (triggers form submit / Enter), returning `submitted: true`.
      - **Sign In Myself (Take Over)**: calls `handBack(tab)` and returns `{ status: "waitingForUser", tabID, message }`.
      - **Cancel / Decline**: returns `{ status: "declined", tabID, message }`.

### 3.4 `credentialTainted` DevTools & Scripting Secret Guard

To guarantee that neither Vault-filled passwords nor user-typed passwords can be exfiltrated by an agent—even in the Developer tier—WSurf enforces a document-scoped protection boundary:

- **When a document is protected:**
  1. WSurf Vault filled credentials into that `documentID` via `requestUserLogin` (`credentialTainted`), **OR**
  2. The live DOM (including open shadow roots and same-origin frames) currently contains any non-empty sensitive secret field (`R.isSensitiveSecret(el)` with non-empty value) that the user has not explicitly approved for inspection.
- **Enforcement across all tools:**
  1. **`evaluateScript`:** Before executing any script in either `page` or `isolated` world, checks document protection (both `credentialTainted` state and live DOM probe). If protected, **refuses without running the script**:
     `{ status: "denied", code: "protectedSecretPresent", tabID, message: "..." }`.
     Defense-in-depth post-run redaction (`PageScripting.helpers`) remains active for cookies and non-blocked cases.
  2. **`readNetwork` (`bodies: true` / `headers: true`):** Whenever `credentialTainted` holds for a record's `documentID`, `requestBody` and `responseBody` are omitted and replaced with `requestBodyNote` / `responseBodyNote`: `"omitted: protected credential form"`, both at capture time and read time. Sanitized metadata, header/cookie redaction, and `MCPSecretScrubber` continue to operate.
  3. **`readConsole` (`fullConsole: true`):** Object `preview` payloads are suppressed for `credentialTainted` documents, and all text passes through `MCPSecretScrubber`.
  4. **`editDOM`, `findElements`, `inspectElement`, `screenshotPage`:** Retain the `[value]` CSS attribute selector ban, `editDOM` ban on sensitive fields/forms, full `MCPSecretScrubber` scrubbing, and black-box masking of filled sensitive fields in screenshots.
- **Automatic clearing on navigation:**
  - `credentialTainted` is bound to `(runtimeDocumentID, mainDocumentID)`. Once navigation commits to a new document (and no filled protected sensitive field exists on the new document), taint clears automatically so `evaluateScript`, `readNetwork`, and `readConsole` resume seamlessly on post-login pages.

---

## 4. Phase 2 — Speed & Latency Optimizations

- **Fast-path delta observation:** Consolidate pre/post DOM digest and ref acknowledgement into fewer IPC round-trips, cutting typical `clickOnPage` / `typeOnPage` latency on Chromium and WebKit.
- **Adaptive settle windows:** Shorten `PageSettle` quiet ceilings when no network requests, animations, or mutations are observed after an action, while honoring explicit `budget.settleMs`.
- **Compound batching:** Optional action-sequence tool (`runSteps`) for deterministic local UI flows (fill + click + wait) with single-round-trip failure diagnostics.
- **Background Chromium pre-warming:** Keep one standby Chromium renderer warm when the MCP server is enabled so `newTab` achieves sub-second first paint.

**Implemented (Phase 2):** Chromium background `isTrusted` pointer and keyboard input through DevTools (`clickOnPage` with
`x`/`y`, `button`, `clickCount`, `modifiers` or `pointer`; `hoverOnPage`; `scrollPage` wheel at a point; `dragOnPage` with
`pointer`; `pressKey`), hit-tested with the ref click's protections (file inputs, password reveal toggles on protected
forms, `SensitiveAction`), and a 6-second refusal of unplanned file choosers and context menus after agent input;
`getDevelopmentInfo` `backgroundPointer`/`backgroundKeyboard`; no announce pause for MCP actions; `waitAndRead` on `newTab`
and `navigate`; cached digests keyed by page generation, document, observation, change count and taint, and a single-round
readiness check; batch `fillFields` (one inspect round, one write round per field, one verify round, one settle) with
`submitRef`/`submit`; `runSteps` (≤ 10 steps, fail-fast); `settle: none|fast|auto` and animation/off-screen noise filtering;
per-tab call lanes with a 4-call FIFO and a global lane for sheets and focus; `--tools=core|playwright|all`;
`screenshotPage` `includeSnapshot`. See MCP.md. Pre-warming remains planned.

---

## 5. Phase 3 — T3 Agent Micro Window

An authenticated paired host can open an isolated Agent Micro Window through
`host-bridge.sock`. A token binds `browser.sock` to that window. The Micro Bar
shows ownership and provides Take Over, Hand Back and Stop. Login approval uses
a native sheet anchored to the window. These windows use regular profiles and
preserve the user's current profile selection.

## 6. Phase 4 — Developer Ergonomics & Multi-Tab Workflows

- **Session attribution and cleanup.** The tab menu names the connection that
  opened a window-local tab. **Close agent tabs** closes only that connection's
  window-local tabs in the current window. Tabs taken over by the person, pinned
  tabs and shared Space tabs are excluded.
- **Cross-engine comparison.** `setTabEngine`, `openComparison` and `compareTabs`
  let clients compare Chromium with WebKit using structured layout, console and
  network diffs and an optional image overlay. WebKit-only sites cannot be
  opened as a Chromium comparison.
- **Structured outcomes.** Tool results carry machine-readable `code` fields
  for refusals and actionable states, including `protectedSecretPresent`,
  `webKitRequired`, `vaultLocked`, `waitingForUser`, `tabNotFound`,
  `accessDenied`, `humanControl`, `invalidInput`, `timeout` and `unsupported`.
  Existing messages, status values and JSON-RPC protocol errors are retained.
- **Connected app policy.** The data-protection Keychain stores opt-in password
  entry, the availability of Vault login requests and the default tab engine
  for each paired client. Older pairings load with password entry off, Vault
  requests subject to human approval and Chromium as the default where WebKit
  is not required. The live connection uses current settings.
- **Host bridge parity.** `openAgentWindow` shows the window when `open` is
  omitted and reports actual visibility, as does preview `status`. A verified
  host can take a guarded read-only `snapshot` during human control. Changed
  ownership generation, a filled sensitive field, a Vault-tainted document or
  an explicit site refusal prevents the corresponding read. All mutations
  remain blocked until Hand Back.

---

## 7. Security & Threat Model Summary

| Threat | Mitigation in MCP v2 |
| --- | --- |
| Malicious/prompt-injected agent hijacks user's active tab | `newTab` works without touching user tabs; `navigate` on user-shared tabs opens a new background tab unless `inPlace: true`. |
| Shell process enables password entry or grants silently | `allowsPasswordEntry`, pairings, standing grants, and Website default live in the data-protection Keychain (`MCPTrustStore`), never in UserDefaults or editable files. |
| Agent extracts Vault password via `requestUserLogin` | Blind fill writes directly inside WSurf; Vault credentials never enter MCP messages; human approves one of 4 explicit sheet choices; password registered in memory-only `MCPSecretScrubber` (zeroed on disconnect). |
| Agent extracts Vault or user-typed password via `evaluateScript` / DevTools | `credentialTainted` + live filled-secret check blocks `evaluateScript` (`protectedSecretPresent`), strips `readNetwork` bodies (`omitted: protected credential form`), suppresses `readConsole` previews, bans `[value]` selectors and `editDOM` on sensitive forms, and masks screenshots in black. |
| Agent probes whether user has accounts in Vault | `vaultHint` exposes only `{ hasSavedLogin: Bool, requiresUserApproval: true }` on pages with login forms; never usernames, counts, or credentials; returns `false` when Vault is locked. |
| Echoed password leaks through page title, console, or URL | `MCPSecretScrubber` registers typed & stored/reformatted values before DOM events fire and scrubs all encodings (raw, whitespace-collapsed, percent, JSON, HTML) across every reply. |
| Forced Chromium on WebKit-only auth origins | `SitePermissions.webKitOnlyOrigins` enforced in both `newTab` and `setTabEngine`. |

---

## 8. Verification Plan

Phase 1 is verified by automated Swift Testing suites running on both WebKit and Chromium engines:
- `MCPv2CoreTests`: `newTab` without prior grants (sheet / standing / default), Chromium default & WebKit switching (`newTab` + `setTabEngine` + `webKitOnlyOrigins`), user-tab `navigate` protection & `inPlace: true`, Playwright `browser_navigate` auto-open, username/contact autofill read-redaction + write-allowance, Control-tier password write with `allowsPasswordEntry` on/off + auto-scrubbing + screenshot masking, `vaultHint`, all 4 `requestUserLogin` outcomes + `manualLogin`, and `credentialTainted` blocking `evaluateScript` / `readNetwork` bodies / `readConsole` previews on both WebKit and Chromium with automatic post-navigation recovery.
- Full regression pass across all existing `MCP*Tests`, `PasswordAutofillScriptTests`, `ContactAutofillScriptTests`, `AutofillListingTests`, `AutofillSaveScriptTests`, `PageSecretEntryTests`, `Tools/check-string-catalog.py --strict`, and `Tools/ci-local.sh --base origin/main`.
