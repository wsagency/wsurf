# WSurf design instructions for AI tools

Use this guide when changing WSurf, making an interface prototype or writing a product page. The public kit lives at `/design-system/`. Its source is `wsurf.app/design-system/`. The [manifest](manifest.json) lists relative paths that resolve from that directory.

## Start from the surface you are changing

| Surface | Start here | Use in the change |
| --- | --- | --- |
| macOS Settings | [Settings primitives](https://github.com/wsagency/wsurf/blob/main/WSurf/Settings/SettingsPrimitives.swift) and [Settings elements](https://github.com/wsagency/wsurf/blob/main/WSurf/Settings/SettingsElements.swift) | Match an existing page. Use its section, row, native toggle, picker or button. Keep visible labels, keyboard behavior and VoiceOver descriptions. |
| Browser chrome | [Native theme](https://github.com/wsagency/wsurf/blob/main/WSurf/UI/Chrome/Theme.swift) and the surrounding SwiftUI view | Follow the selected theme, window style, system accent and contrast. Preview Standard, Minimal and Micro when the change affects all three. |
| Web and prototypes | [CSS tokens](tokens.css), [token data](tokens.json), [component styles](components/bundle.css) | Load the token sheet first. Reuse markup from a working example such as [Button](components/Button/preview.html). |
| Brand or Dock icon | [Asset inventory](manifest.json), [Dock guide](assets/Dock/README.md), [mark](assets/Mark/README.md) | Copy the supplied artwork. Use Anodized for the bundle icon, a flat lockup for navigation and the small cut for favicons. |

Use violet for the person’s actions on the website. Use mint to identify the assistant’s activity, paired with text such as “Reading 2 tabs”. The native app follows the user’s theme. The canonical mark and outlined wordmark have fixed geometry. Preserve the waterline, gap and clear space.

## Describe what a person can do

- Use the current US English menu and Settings labels. Show one observable action and result per example.
- “Fully private. Fully yours.” is the homepage line. Explain the choices alongside it. A local model can process a request on the Mac. A selected external provider receives the request and the content included with it. iCloud sync is an explicit choice for each supported category.
- A joined shared Space can reflect opening and closing tabs on another Mac. Cookies belong to the local browsing session. A Space can use a chosen credential vault with separate sign-ins. Use synthetic names and addresses in examples.
- A connected MCP client requests access to webpages. Keep each client’s grants, the selected tab and the person taking over visible in walkthroughs. Use Connected apps for per-client policy and the tab context menu for the originating client and Close agent tabs. Verify the operation against the [MCP reference](https://github.com/wsagency/wsurf/blob/main/MCP.md).
- For performance, describe the implemented action, such as unloading an eligible inactive tab while retaining its link. A numerical or competitive claim needs an attributable measurement with a reproducible scenario, versions and hardware.
- Use stage data or label a reenactment as an illustrated walkthrough. Supply a still, a text description and playback controls for product films. Preserve the system’s reduced-motion preference.

## Send the matching design update

Edit the relevant token, example, asset or guide in this directory in the same pull request as the interface change. When a shipping icon changes, update the app asset first. **From the repository root** run `python3 Tools/update-design-system.py`, then `python3 Tools/update-design-system.py --check`. Serve `wsurf.app/` locally and inspect the affected page in Day, Night, a narrow viewport and with reduced motion enabled. The [maintainer guide](Adoption.md) maps design decisions to their owners.
