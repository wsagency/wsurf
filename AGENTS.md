# Development rules

`AGENTS.md` is the canonical instruction file for every agent harness used in this repository: Antigravity, Claude Code, Codex, OMP and T3 Code. `CLAUDE.md` only includes this file. Change the rules here, never in a harness-specific copy.

These rules apply to all code, documentation, and configuration changes in this repository.

- Use one dedicated Git worktree and a unique `feature/<short-name>` branch per task, based on the latest `origin/main`. Do not develop in the `main` checkout or switch branches in a shared checkout.
- Store manually created worktrees inside the project's `/.wt/` directory, which must remain gitignored.
- Harnesses often create an isolated worktree for a task (for example OMP under `/.wt/`, T3 Code under `~/.t3/worktrees/wsurf/`). Detect and reuse that worktree, with its branch on `feature/<short-name>` from the latest `origin/main`; do not create a second worktree or switch the shared checkout.
- Leave other tasks' uncommitted changes alone. Never stash, discard, move, or commit them as part of your task.
- Keep build output and DerivedData local to your worktree; do not reuse another worktree's build directory.
- Integrate changes only through a PR targeting `main`, after review and required CI checks pass. Never commit or push changes directly to `main`.
- Remotes: `origin` is `wsagency/wsurf`; `upstream` is `kavoye/linen-browser`, the project WSurf is based on. Always push to `origin` and open PRs against `wsagency/wsurf` `main` (with `gh`, pass `--repo wsagency/wsurf`).
- Local development builds, tests, and PR validation builds are allowed on feature branches. Release builds and deployments, including signed previews, use only PR-merged commits on `main` after CI passes. Release tags must point to commits on `main`; never deploy a feature branch or dirty working tree.

Follow [CONTRIBUTING.md](CONTRIBUTING.md#development-workflow) for the worktree setup and PR checklist, and [RELEASING.md](RELEASING.md#source-and-deployment-policy) for release and deployment gates.

For interface, brand, motion or website changes, read the [design system and AI instructions](wsurf.app/design-system/AI.md). Update the affected guidance, examples and assets under `wsurf.app/design-system/` in the same PR. The [maintainer guide](wsurf.app/design-system/Adoption.md) identifies the source for each asset.

## Agent workflow

- Work plan → implement → verify → review. Make a short plan before changing anything, verify with the checks below, and get an independent review before merge.
- Use the active harness's native tools for reading files and skills, spawning isolated subagents or worktrees, tracking tasks, and running the independent pre-merge review. Do not assume another harness's tool names.
- When the harness provides Superpowers skills, start with `using-superpowers` and load and follow the relevant skills before responding or acting. Otherwise follow the same discipline with the harness's native tools.

## Native builds and verification

- Native builds and tests run on the MacBook Pro (`PRO.local`) with full Xcode at `/Applications/Xcode.app`. CI pins the Xcode version as `XCODE` in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (currently 27.2); `Tools/ci-local.sh` warns when the local Xcode differs. Recheck the toolchain when a build reports an incompatibility.
- **On the Pro directly:** run `Tools/ci-local.sh --base origin/main` from your worktree. It holds the shared Pro lock (`/tmp/wsurf-cvs/pro.lock`, through the `with-pro-lock.sh` wrapper); every other native build or test must also run under that lock.
- **From the Air (`m5air.local`):** the Air has Command Line Tools, not full Xcode. Local Swift/CEF probes can work while the SwiftUI app build fails because `SwiftUIMacros` is missing. This is a local toolchain limitation, not a project-wide blocker. Do not fake macros or alter application semantics to bypass it. Build and test over the SSH alias `pro`, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on every remote command; do not change global `xcode-select` settings. Before reporting missing Xcode or proposing an installation, check Pro:

  ```sh
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes pro \
    'hostname && xcode-select -p && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift --version'
  ```

- Pro's established checkout is `~/projects/wsurf-project/wsurf`. Preserve its working tree and existing builds. Work in an isolated worktree or owned build snapshot, then use the native `xcodebuild` workflow in `CONTRIBUTING.md`.
- For real UI verification use a separate stage app and `WSURF_STAGE=1` with an owned `WSURF_STAGE_HOME`; do not replace the user's installed app or use production browsing data. Copy the app to the Air when the check needs that machine.
- Report component probes separately from whole-app builds and UI checks. Never claim the app is verified from a CEF probe or Swift syntax check alone.
- Production app replacement is separate from stage verification and requires the user's deployment authorization.

## Pro Disk Hygiene Rules (MANDATORY — PRO runs out of disk otherwise)

`Tools/disk-hygiene.sh` enforces these rules in `Tools/ci-local.sh`, `Tools/run-chromium-oop-tests.sh` and `Tools/run-foreground-tests.sh`; `Tools/check-disk-hygiene.py` tests it. Any other build or test script you write must follow them too. `Tools/clean-pro-disk.sh` reports leftovers (dry run by default) and removes them with `--apply`; run `--apply` under the Pro lock.

1. **Always clean the `code_sign_clone` for your suffixed bundle ID.** This is the biggest leak: 455 GB was found. macOS keeps a full copy of each launched test identity at `$(dirname "$(getconf DARWIN_USER_TEMP_DIR)")/X/<bundle-id>.code_sign_clone`. An `EXIT` trap removes only that run's suffixed directory:

   ```sh
   trap 'rm -rf "$(dirname "$(getconf DARWIN_USER_TEMP_DIR)")/X/${BUNDLE_ID}.code_sign_clone"' EXIT
   ```

   **Never** delete `io.wsagency.wsurf.code_sign_clone` (the real app) or any `io.wsagency.wsurf.stage.*` clone. Remove stale suffixed clones (`X/io.wsagency.wsurf.*.code_sign_clone`, except the real app and `stage.*`) as soon as you find them: `Tools/clean-pro-disk.sh --apply`.
2. **Isolate and trap-clean `$TMPDIR` and `/private/tmp`.** Do not write `WSurf-private-*`, `wsurf-d4-*`, `WSurf-tests-*`, `wsurf-chromium-*` or `io.wsagency.wsurf.*` directly into the root of `$TMPDIR` or `/private/tmp`. Use one directory per run, `RUN_TMP=$(mktemp -d "${TMPDIR}wsurf-run-XXXXXX")`, with `trap 'rm -rf "$RUN_TMP"' EXIT`. Keep logs and `.xcresult` bundles only for a failure, and delete them after triage. **Never** delete `/tmp/wsurf-cvs/pro.lock`, the shared Pro lock.
3. **DerivedData and `.xcresult` budget.** Reuse a pinned `SourcePackages` cache (`WSURF_SOURCE_PACKAGES_CACHE`, passed as `-clonedSourcePackagesDirPath`). Delete isolated `DerivedData`, `.xcarchive` and `.xcresult` output immediately after a PASS. Keep an `.xcresult` only for a FAIL, and prune failed bundles older than 48 hours. Never accumulate `.xcresult` bundles or build outputs inside `$N` (`side-session-notes`).
4. **Worktrees (`wsurf/.wt` and `~/.t3/worktrees/wsurf`).** Once a PR merges, remove its worktree with `git worktree remove` and then `git worktree prune`. Never touch a worktree with uncommitted or unpushed work without owner review.
5. **Pre-flight disk guard.** Abort before building when `/` (`/System/Volumes/Data`) has less than 30 GB free, and print the top offenders: `X/*.code_sign_clone`, `DerivedData`, `/tmp/wsurf-*` and `$N`. Do not silently move hundreds of GB into `~/.Trash`: delete regenerable build and test intermediates directly after a PASS. Use the Trash only for owner-reviewed removals of old releases or checkouts, and remind the owner to empty it.

## Website deployment (`https://wsurf.app`)

The website deployment target is `https://wsurf.app`: assets-only Cloudflare Worker `wsurf-site`, with `wsurf.app/` as the document root. Develop in a dedicated feature worktree and merge through a reviewed PR. A merged `main` push in `wsagency/wsurf` runs the existing `CI` workflow. Only its successful push/main completion activates [`.github/workflows/deploy-site.yml`](.github/workflows/deploy-site.yml), which checks out the tested SHA, skips superseded main commits, and publishes with `npx --yes wrangler@4.136.2 deploy`. This is the sole production path; never deploy feature branches or dirty trees, bypass CI, create a native Workers Builds connection, or add a second Actions/manual deploy path.

There is no website build, JavaScript Worker, or application dependency. Preserve `.well-known/apple-app-site-association` and its existing identity. `_headers` is the exact JSON MIME override. Verify the live anonymous HTTPS response operationally: HTTP 200, `Content-Type: application/json`, valid TLS, and no redirect.

`CLOUDFLARE_API_TOKEN` is a GitHub secret with **Individual Workers Editor** for only the existing `wsurf-site`; no account-wide, DNS, route, KV, or R2 permissions. `wrangler.jsonc` omits `routes` and keeps `workers_dev` false. The existing Custom Domain is managed separately; modifying that binding requires explicit operator approval and separate credentials. Native app CI/releases, signing entitlements, and credential/vault behavior are separate. Provider, domain, token, and integration changes require explicit operator approval. Keep secrets, signing material, and private data out of the website and Git.
