<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/mark-white.svg">
  <img src=".github/assets/mark-black.svg" alt="WSurf" width="104" height="104">
</picture>

# WSurf

**A browser with a built-in assistant for macOS.**

Ask the assistant to search, read websites, and use the tabs you have open.
It can click, type, and scroll. Click the page at any time to stop the assistant
and use it yourself.

WSurf is an independent fork of
[kavoye/linen-browser](https://github.com/kavoye/linen-browser). It preserves
the upstream Apache 2.0 license, copyright notices, and third-party
attributions; see [LICENSE](LICENSE) and [NOTICE](NOTICE) for terms,
provenance, and the WSurf modification record.

<a href="#install">Install</a> ·
<a href="#what-it-does">Features</a> ·
<a href="#building">Build</a> ·
<a href="CONTRIBUTING.md">Contribute</a>

<a href="https://github.com/wsagency/wsurf/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/wsagency/wsurf/ci.yml?branch=main&style=flat-square&label=CI" alt="CI status"></a>
<img src="https://img.shields.io/badge/macOS-26%2B-1c1c1e?style=flat-square" alt="macOS 26 or later">
<img src="https://img.shields.io/badge/Apple%20silicon-1c1c1e?style=flat-square" alt="Apple silicon">
<img src="https://img.shields.io/badge/license-Apache%202.0-1c1c1e?style=flat-square" alt="Apache 2.0 license">

</div>

## Install

Requires **macOS 26 or later** and **Apple silicon**.

WSurf does not yet have a verified public signed release. Do not treat an
unsigned local build as a release artifact. When a WSurf release is published,
download the disk image from the
[latest release](https://github.com/wsagency/wsurf/releases/latest), open it,
and drag WSurf to Applications.

This README describes the current source. See the [release notes](CHANGELOG.md)
for upstream historical release facts and WSurf changes; historical entries are
labelled as inherited provenance and are not claims that WSurf published those
versions.

## What it does

- **Browse:** tabs, folders, pins, split view, history, resumable downloads, and
  bookmark import. Play media in Picture in Picture and view synced lyrics.
- **Choose a website engine:** Website Settings › Browser Engine selects
  WebKit (default) or embedded Chromium. Changing engines reloads the website
  and resets its Back/Forward history; cookies, storage, and sign-ins are separate.
- **Choose a theme:** Settings › Appearance offers Auto, Light, Dark, pastel
  Light Calm, and Dark Calm. Theme customization previews brightness, hue, and
  a primary-derived palette live. Control icons and URL text have independent
  colors and opacity, saved per theme; Reset restores that theme's defaults.
- **Tune the sidebar:** Settings › Appearance › Sidebar controls the installed
  font family, text size and weight, row spacing, and folder tint (including none).
  Loaded and unloaded text/icon colors and opacity are saved separately for each
  theme. Original favicons remain recognizable in monochrome. Click a tab title
  to activate it; use Right-click › Rename to edit its name.
- **Close or unload:** X removes an unpinned tab and its link; ⌘-click its
  control to unload instead. Pinned tabs unload with the curved-down arrow or
  reload with Play; ⌘-click their control to remove the pin and tab.
  Right-click › Unload Tab retains the link, pin, and folder membership.
  Middle-click and ⌘W also unload. A folder's curved-down arrow unloads all
  descendant tabs; X is reserved for removal. Existing unload protections remain.
- **Keep favorites:** Right-click a tab › Add to Favorites promotes its existing
  link into the icon-only strip above the sidebar without a duplicate row.
  Favorites belong to the current profile and never sleep automatically.
  Their context menu can unload them manually or return them to ordinary pins.
- **Create and restore folders:** New Folder and Move to Folder › New Folder
  reveal the new folder and focus its inline name editor, including in icons-only
  mode. Undo, ⌘Z, or Ctrl-Z restores deleted folders and removed links with their
  names, hierarchy, pins, and positions. Text editors retain their own Undo.
- **Pin folders independently:** Right-click a folder › Pin moves it into the
  top pinned section; Unpin moves it below the remaining pins. Folder pinning
  does not change its tabs' bookmarked URLs. Empty folders can be pinned, and
  folder pin state and order survive a restart.
  Reordering tabs inside the same folder preserves their bookmarks.
  Deleting a folder or moving its children out keeps root pins above ordinary
  rows without changing child bookmarks.
- **Ask the assistant:** type in the address field or hold ⌥Space to speak.
  Use `@` to include a tab, attach files, and review actions in Agent Activity.
- **Preview links:** hold Shift over a link for a summary, or Shift-click to
  open a preview.
- **Fill forms:** use macOS Passwords-compatible password autofill, save
  payment cards, and contact details in Settings › Autofill. Passwords and
  cards require system authentication. Passkeys use macOS.
- **Add WebKit extensions:** install from the Chrome Web Store or Firefox Add-ons.
- **Separate browsing:** profiles keep cookies, history, tabs, permissions, and
  extensions separate. Press ⇧⌘N for private browsing.
- **Choose a theme:** Settings › Appearance offers Auto, Light, Dark, pastel
  Light Calm, and Dark Calm.
- **Tune the sidebar:** Settings › Appearance › Sidebar controls the installed
  font family, text size and weight, row spacing, and folder tint.
  Loaded and unloaded text/icon colors and opacity are saved separately for each
  theme. Original favicons remain recognizable in monochrome. Click a tab title
  to activate it; use Right-click › Rename to edit its name.
- **Unload without losing links:** sidebar X/minus, middle-click, and ⌘W unload
  page content while retaining the link, pin, and folder membership. Unloaded
  tabs show Play to load them again; selecting the link also reloads it.
  Settings › Appearance lets you show a removal X beside Play or reveal it
  while holding ⌘. Remove Tab permanently removes the tab and its link.
  Hover a folder while holding ⌘ to show its X immediately left of the far-right
  count. It unloads descendant tabs; existing unload protections still apply.
- **Pin a folder:** Right-click › Pin keeps the folder above unpinned rows without
  changing its child bookmarks. Pin/Unpin and folder order survive a restart,
  including empty folders.

The Apple Passwords compatibility work preserves Apple's official Chrome
extension identity, public key, authentication, PIN, and native protocol
contracts. That identity is an external Apple client contract, not WSurf
branding. Source fixtures and extension parsing are covered, but real Apple
Passwords PIN, fill, save, OTP, 15-minute idle, lock, and sleep behavior has
not been verified in an own signed WSurf build.

### Choose a model

Use Apple Intelligence on your Mac, add a provider API key, or connect to a local
server such as Ollama or LM Studio. Supported providers include OpenAI,
Anthropic, Gemini, DeepSeek, Groq, Mistral, OpenRouter, and xAI.

External assistants can use explicitly shared tabs through WSurf's
[MCP server](MCP.md).

## Privacy and control

- Choose assistant access per website and enable tools in Settings › Assistant.
  The assistant asks before purchases, sending, or signing in. It cannot fill
  passwords or card numbers; browser autofill is separate.
- API keys stay in Keychain and are sent only to their provider. Submitted
  messages, shared page content, and attachments go to the selected model.
- On-device voice transcribes audio on your Mac. OpenAI dictation and voice
  conversations send microphone audio to OpenAI.
- Private browsing does not save history, tabs, or assistant transcripts.
- Known third-party trackers are blocked by default. This is basic protection;
  extensions can provide more comprehensive blocking.

The assistant uses AI and can make mistakes. Check important information.
Report vulnerabilities privately through [Security](SECURITY.md).

## Known limitations

- One window. Links requesting another window open in tabs.
- Pins and folders replace a separate bookmarks manager. Import bookmarks from
  an HTML export in Settings › General; history is not imported.
- Website notifications require WSurf to be running. There is no background web
  push.
- Chromium is loaded only when needed, but its runtime remains initialized
  until quit. Adding it does not guarantee lower RAM, CPU, or faster websites.
  Unloaded Chromium tabs restore their URL, not a WebKit history stack.
- Extension integration and native WebKit Picture in Picture remain WebKit-only.
- The managed browser public-key-credential entitlement requires Apple's
  organization Account Holder review. A local build may need that entitlement
  removed, which disables passkeys; see [Releasing](RELEASING.md).

WSurf keeps its own data in `~/Library/Application Support/WSurf` and uses
separate WSurf defaults, stage, native-host, MCP, logger, and `WSURF_*`
configuration namespaces. It does not alias or automatically copy personal data
from another browser.

Chromium errors remain visible on standard error; WSurf does not keep a CEF
debug log file. Inspect captured native diagnostics before sharing them: they
can contain local paths and website details.

## Building

Requires **Xcode 26.5 or later**.

```bash
git clone https://github.com/wsagency/wsurf.git
cd wsurf
open WSurf.xcodeproj
```

Select the `WSurf` target, set your team in **Signing & Capabilities**, then
build and run the `WSurf` scheme. Dependencies resolve automatically.

The pinned CefSwift package supplies Chromium. `Tools/embed-chromium.sh` embeds
the CEF framework, helper apps, and licenses and signs them with the build's
identity. A production distribution requires proper signing; an ad-hoc debug
build is not a verified release.

For a local team without the passkey entitlement, remove this entry from
`WSurf/WSurf.entitlements`. Passkeys will be unavailable in that build:

```xml
<key>com.apple.developer.web-browser.public-key-credential</key>
<true/>
```

Use a normally signed build for Keychain access and manual Apple Passwords
compatibility checks. The current source/test checks do not establish real
vault authentication or fill/save behavior. See [Contributing](CONTRIBUTING.md)
for test commands and development guidelines, [Architecture](ARCHITECTURE.md)
for the code structure, and [Releasing](RELEASING.md) for distribution.

## Website and domain association

[`wsurf.app/`](wsurf.app/) is the static website: HTML, CSS, and the existing
wave artwork. No build step, JavaScript, third-party assets, or credentials are
needed. Configure autodeploy from this repository with `wsurf.app/` as the
webserver's document root, preserving the hidden `.well-known/` directory.

Preview locally:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory wsurf.app
```

The public association file must be served at
`https://wsurf.app/.well-known/apple-app-site-association` with HTTP 200,
`Content-Type: application/json`, valid HTTPS, and no redirect or authentication.
The Python preview server serves the extensionless file as
`application/octet-stream`; configure the production server's MIME type explicitly.
For Nginx, inside the server block whose root is the deployed website:

```nginx
location = /.well-known/apple-app-site-association {
    default_type application/json;
    try_files $uri =404;
}
```

The file authorizes `5X68L55TNU.io.wsagency.wsurf`, using the repository's
configured release team and bundle ID. Before enabling passkey vault unlock,
confirm it matches the signed app's `application-identifier`; the App ID prefix
is not necessarily the Team ID. The app will also need a provisioned
`webcredentials:wsurf.app` Associated Domains entitlement. This website does not
implement credential migration or vault unlock, and contains no certificates,
private keys, vault data, or PRF results. Keep Apple signing material out of
the website deployment.

### Cloudflare Workers

[`wrangler.jsonc`](wrangler.jsonc) defines the assets-only Worker `wsurf-site`
with `./wsurf.app` as its document root and `workers_dev` disabled. The existing
`wsurf.app` Custom Domain is managed separately: the configuration deliberately
omits `routes`, so recurring deployments do not need DNS or domain permissions.
[`wsurf.app/_headers`](wsurf.app/_headers) sets the association file's
`Content-Type: application/json`. The existing hidden `.well-known` file and
its app identity are preserved. No JavaScript Worker, website build, or
application dependencies are required.

The sole production deploy path is GitHub Actions: a PR merged into `main` in
`wsagency/wsurf` triggers the existing `CI` workflow. After that exact commit's
push-triggered CI succeeds,
[`deploy-site.yml`](.github/workflows/deploy-site.yml) checks out the tested
SHA and runs `npx --yes wrangler@4.136.2 deploy` to publish to
`https://wsurf.app`. Superseded main commits are skipped. Failed CI, PR/fork/tag
and other-branch runs cannot deploy. There is no native Workers Builds
connection, GitHub App grant, or competing manual path. Native app signing and
release workflows remain independent.

The repository secret `CLOUDFLARE_API_TOKEN` is restricted to **Individual Workers
Editor** on the existing `wsurf-site` only. It has no account-wide, DNS, route,
KV, or R2 grant. Never use operator master credentials as the build secret or
add `routes` to this scoped configuration. Custom Domain changes require
separately authorized operator access.

The production association file must be served anonymously at
`https://wsurf.app/.well-known/apple-app-site-association` with HTTP 200,
`Content-Type: application/json`, valid HTTPS, and no redirect or
authentication.

Local Wrangler/browser checks and approved operational bootstrap passed.
An actual deployment using only the restricted Worker token passed on
2026-10-05, preserving the existing Custom Domain and managed DNS record.
Public anonymous HTTPS GET/HEAD checks confirm the association's HTTP 200,
JSON MIME, unchanged identity, and no redirect; the rendered site loads its
CSS and artwork. These operational checks do not replace the PR review and
successful main CI gate for recurring deployments.

## License and acknowledgements

[Apache 2.0](LICENSE). WSurf is a fork with attribution to the upstream
Kavoye Linen project; provider logos and Apple client identifiers belong to
their owners.

WSurf uses [Sparkle](https://github.com/sparkle-project/Sparkle),
[AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel), and other
open source packages. Full credits and license texts are in **Settings › About**
and [Acknowledgements.json](WSurf/Support/Acknowledgements.json).
