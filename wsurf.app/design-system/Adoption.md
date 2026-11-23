# Maintaining the WSurf design system

The browsable kit is versioned with the website in `wsurf.app/design-system/` and served at `/design-system/`. It incorporates the WSurf Design System export, current Tandem artwork and the Dock finishes shipped with WSurf. The checked-in site is directly deployable as static files.

| Change | Edit here first | Update alongside it |
| --- | --- | --- |
| Dock finish or its name | `WSurf/Assets.xcassets/`, `WSurf/Settings/DockIcon.swift` | `assets/Dock/`, the finish picker in `index.html` and its accessible labels |
| Tandem geometry, wordmark or favicon | `branding/tandem/` | Published renditions, header wordmarks, root favicon files and component previews that use that art |
| Web color, type, spacing or radii | `tokens.json` and its CSS representation in `tokens.css` | `api/tokens.md`, affected pages and examples in both appearances |
| Web component | `components/bundle.css` and the relevant component subdirectory | Its standalone preview, usage notes and matching API reference |
| Native control or behavior | Existing SwiftUI component, Settings row or theme | Relevant screenshots, terminology, native guidance and any affected walkthrough |
| Motion | The editable source in `branding/tandem/` or the illustrated product walkthrough source | Exported film, poster, description and usage notes |

## Publish a design change

1. Work on the same feature branch as the change. Keep the editable originals and their attribution.
2. Run the following from the repository root. The first command copies current artwork into the web root and refreshes the visible asset list and JSON inventory. The second detects stale files without writing.

   ```sh
   python3 Tools/update-design-system.py
   python3 Tools/update-design-system.py --check
   python3 -m http.server 8765 --bind 127.0.0.1 --directory wsurf.app
   ```

3. Open `http://127.0.0.1:8765/` and `http://127.0.0.1:8765/design-system/`. Try the finish picker with the arrow keys, open an asset category, follow a component example and play a film. Check narrow and wide layouts, Day, Night and reduced motion. Verify any affected links and attributions.
4. Commit the source and the refreshed web files together. Website deployment follows the repository’s reviewed main and CI workflow. Designers and agents can use the [manifest](manifest.json) to locate files directly.

The system preserves Flux and Legacy as historical studies. Their palettes and marks are available for reference. The Dock finish choices follow the app catalog. The [repository notice](https://github.com/wsagency/wsurf/blob/main/NOTICE) covers WSurf’s licensing and third-party notices. The [Inter license](assets/Lockup/Inter-OFL.txt) accompanies the outlined wordmark.
