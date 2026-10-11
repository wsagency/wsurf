<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Contributing to WSurf

Keep changes focused, explain the user benefit, and keep the code testable.

## Development workflow

All changes, including fixes and documentation, must use a dedicated Git
worktree and a unique `feature/<short-name>` branch based on the latest
`origin/main`. Keep one task per worktree and branch. Do not develop in the
`main` checkout, switch branches in a shared checkout, or stash, discard, move,
or commit another task's uncommitted changes.

Store task worktrees under `.worktrees/` in the project folder; this directory
is gitignored. OMP creates the isolated worktree automatically. Reuse its
`feature/<short-name>` branch and worktree rather than creating a second one.

Keep build output and DerivedData inside your worktree; do not reuse another
worktree's build directory. Local development builds, tests, and PR validation
builds are allowed before merge.

Submit changes through a pull request targeting `main`. Resolve review
feedback and pass the required CI checks before merging. Do not commit or push
changes directly to `main`.

Release builds and deployments, including signed previews, must use a commit
merged into `main` through a PR and wait for CI to pass on that commit. Never
deploy a feature branch or an uncommitted working tree. Release tags must point
to commits on `main`. See [Releasing](RELEASING.md) for the existing release and
preview gates.

## Set up the project

You need macOS 26 or later, Apple silicon, and Xcode 27.0 or later.

```bash
git clone https://github.com/wsagency/wsurf.git
cd wsurf
git fetch origin main
git worktree add -b feature/my-change .worktrees/my-change origin/main
cd .worktrees/my-change
xcodebuild -downloadComponent MetalToolchain
xcodebuild -resolvePackageDependencies \
  -project WSurf.xcodeproj -scheme WSurf \
  -derivedDataPath build/DD -onlyUsePackageVersionsFromResolvedFile
xcodebuild test \
  -project WSurf.xcodeproj \
  -scheme WSurf \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DD \
  -disableAutomaticPackageResolution \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=
```

The worktree creation commands above are for manual setup without OMP. When OMP
has already supplied a worktree, skip them. Replace `my-change` with a unique
name for your task and run development commands from that worktree, not from
the original `main` checkout.

The `WSurf` scheme runs the `WSurfTests` target from `WSurf.xctestplan`.

Hosted native workflows use GitHub's documented `xcode-27` ARM64 runner
([currently public preview](https://github.com/actions/runner-images/issues/14404))
and require `/Applications/Xcode_27.0.app`; preflight fails if that toolchain is
unavailable. The `macos-26` image contains only Xcode 26.x. Native Pro builds use
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` without changing the
machine's selected developer directory. Keep the resolved package graph frozen
for build/test runs; dependency updates must explicitly update the lockfile and
regenerate `WSurf/Support/Acknowledgements.json`.

The command removes the entitlements. The keychain access group, the passkey
entitlement, and the associated-domains and credential-provider entitlements
need provisioning profiles; the credential exchange extension needs its own.
CI runs the same command. To build the app in Xcode,
set **Team** in **Signing & Capabilities** to your own Apple developer team
first. See [Building](README.md#building).

The project uses Swift 6, Swift Testing, and Main Actor isolation by default.
Do not weaken concurrency checks to make a change compile.

## Make changes

- Separate UI, state, persistence, and external-service code.
- Give each type one main responsibility. Split a file when it contains
  independent features or changes for unrelated reasons.
- Make each distinct SwiftUI section a separate `View` with narrow inputs.
  Computed `some View` properties do not create invalidation boundaries.
- Prefer `@Observable` models. Keep view-local `@State` private.
- Use the existing design primitives in `WSurf/UI/Chrome` and
  `WSurf/Settings/SettingsPrimitives.swift` before adding another style.
- Keep user-facing strings localizable. Prefer `LocalizedStringResource` in
  models and string literals in SwiftUI controls.

## Write useful comments

ASD-STE100 is not a project requirement. It is intended for controlled
technical procedures, while this repository also contains product copy and
framework terminology. Use the parts that help: common words, active voice,
short sentences, and one idea per sentence.

Add a comment when it explains:

- an invariant or a non-obvious reason;
- a security, privacy, concurrency, or performance constraint;
- a framework limitation or private API fallback;
- an interoperability format that the code must match.

Do not narrate the code, preserve edit history, or justify a design by saying
that another product does the same thing. Product names belong only where they
identify a real format, service, import source, or compatibility contract.

## Test behavior

- Add tests for new behavior and for every fixed regression.
- Assert observable outcomes, not merely that code executed.
- Cover success, failure, boundary, cancellation, and persistence paths where
  they apply.
- Prefer deterministic fakes and injected dependencies to sleeps or live
  network calls. Wait for a condition with `waitUntil`, which returns as soon as
  it holds. Fixed sleeps delay every run and can still fail on a slow machine.
- Do not assert on a timer you cannot control. Inject the clock or the interval
  instead, as `DownloadFlights` and the extension update sweep do.
- Protect process-wide dependencies, such as static stubs and shared stores,
  with an exclusive-access trait such as `.exclusiveExternalApp`. Serializing
  one suite does not prevent other suites from accessing shared state.
- Do not hide a persistent failure with `withKnownIssue`. Either make the test
  deterministic or keep the unsupported check out of the automated suite.

Run the full suite before opening a pull request. CI also measures app-target
line coverage and rejects regressions below the repository floor. CI runs
`Tools/check-format.sh`, which fails on SwiftLint violations. CI pins SwiftLint
**0.65.1**; use the same version locally. The configuration is `.swiftlint.yml`. Put a
switch case’s body on the line after the label. Do not write a declaration or
control-flow body inside single-line braces; short closures, `guard … else
{ return }` and accessor lists (`{ get set }`) stay inline. Coverage thresholds
do not replace meaningful assertions. CI also checks the
blank-tab, tab-switching, command-palette, Start Page and Ask surface budgets in
`Tools/check-performance.sh`. Each budget is about twice the measured
baseline to allow for roughly 50% variation on shared runners. These checks
detect large regressions rather than small percentage changes. Change a budget
only with measurements that justify it.

A case that builds a live WebKit view takes `.boundedWebViews`, which holds one
of a small number of slots — half the machine’s cores. Starting every case
together exhausts WebContent processes and turns resource pressure into
unrelated navigation failures. Put the trait on the tests that build a view, not
on the suite around them, so pure cases do not queue for a resource they never
use. Add `.serialized` as well when the cases in a suite share state.

Apply the bounded trait exactly once. Pair it with `.requiresBackForwardCache`
only for cases that genuinely need strict back/forward cache behavior, so those
cases reserve all bounded WebView slots; ordinary tests stay parallel and this is not
whole-suite serialization. `makeConfiguration` already installs the bridge and
registry, so do not install those handlers again. For registration timing,
delay the genuine nonce reply rather than depending on cross-world script
ordering, and keep the strict persisted and nonce checks. If a test replaces
installed scripts, reuse the `BrowserPage.replaceScript` retained-array
mutation pattern, not a dangling remove and re-add.

Lint runs with the pinned SwiftLint on the Pro machine with full Xcode. Do not
relax rules to work around failures on a Command Line Tools-only machine.

`WSurf.xctestplan` runs with per-test timeouts: 120 seconds by default, 300 at
most. A stalled test times out and reports its name without blocking the full run.
Both frameworks run from this plan, and a new test needs no entry in it — the
plan lists the target, not its tests.

Tests get their own support directory, so a test can create profiles, write
permissions or fill the download list without reaching the files of an installed
copy.

## Keep copy and design consistent

- Use the shortest familiar label that is unambiguous.
- Never use forced metaphors, poetic phrasing, or marketing filler in product
  copy. State the action or result directly: “Import your bookmarks,” “Choose
  a Tab for Lyrics,” and “Change the model or reasoning level.” Keep necessary
  instructions, accessibility information, and permission consequences.
- Use Title Case for menu items, window titles, settings page names, and
  buttons that name a command. Use sentence case for options, captions, and
  row titles. One command keeps one capitalization on every surface of the
  same kind.
- Use US English in user-facing strings, a typographic apostrophe, and an em
  dash. Code comments stay ASCII.
- Name the feature “assistant” in copy the user reads. Use “agent” only for
  the machinery it runs on: tools, activity, the trace. Use “AI” only in
  disclosure contexts.
- Do not explain standard controls unless the consequence is unusual.
- Put consequences before implementation details in alerts and permission
  prompts.
- Support keyboard use, VoiceOver labels, reduced motion, and increased
  contrast when the surrounding component does.

## Stage the app for screenshots and video

Stage mode loads sample browsing data for screenshots and recordings.

Set the session in `WSurf/Stage/StageSet.swift`: pinned tabs, folders, loose
tabs, history and downloads.

Build an owned Debug app with `PRODUCT_BUNDLE_IDENTIFIER` set to
`io.wsagency.wsurf.stage.<12-hex-home-suffix>`, copy the complete bundle away
from the installed app, and launch only the required environment:

```bash
stage_home="$PWD/build/stage-home"
mkdir -p "$stage_home"
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$stage_home" \
  WSURF_STAGE=1 WSURF_STAGE_HOME="$stage_home" \
  /path/to/owned/WSurf.app/Contents/MacOS/WSurf
```

The 12-hex bundle suffix is the start of `StageMode.identity(for:)`, which
hashes the standardized stage-home path. `env -i` matters because stage mode
alone does not clear provider-key environment variables. Staged tabs load real
websites, which may show cookie banners and region prompts on first use.

1. Launch with `WSURF_STAGE=1` and an owned `WSURF_STAGE_HOME`.
2. Dismiss every banner on every staged tab.
3. Quit. Stage state remains in that home.
4. Relaunch with `WSURF_STAGE_SEED=0` to retain the existing session instead
   of replacing tabs, history and downloads with sample data.

The standardized stage-home path supplies a stable per-home identity for the
preference suite, WebKit data store, CredentialStore service and MCP socket.
Release builds ignore stage mode. The stage app's MCP install action still
targets real client configuration files, so do not use it here. Credential
saving is not verified by this isolation check; do not use production keys.

For migration and rollback checks, keep `WSURF_STAGE=1`, set an owned
`WSURF_STAGE_HOME`, and set `WSURF_STAGE_SEED=0` before launching. Disabling
sample seeding does not disable stage isolation. Restore a consistent
pre-upgrade backup into a separate owned home for the old app; never open an
upgraded database with the old version.

## Write commit messages

WSurf uses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
Start the subject with a type, add a scope in parentheses when the change
belongs to one area, then a colon and a summary. Write the summary as an
instruction: one imperative sentence, capitalized, with no final period. Keep
the whole subject to 72 characters or less.

```
fix(sidebar): Keep the selection after a drag
feat(downloads): Keep the list after a quit
test(agent): Stop a wedged suite from holding the run
```

Use one of these types:

- `feat`: a new capability a person can use.
- `fix`: a correction to behavior.
- `perf`: a change that makes existing behavior faster.
- `refactor`: a change that keeps behavior the same.
- `test`: a change to tests only.
- `docs`: a change to documentation only.
- `build`: a change to the Xcode project or to a package dependency.
- `ci`: a change to a workflow in `.github/workflows`.
- `chore`: a change that no other type describes.

Put an exclamation mark after the type for a change that breaks an existing
setup, such as `feat!:`.

Give the reason for the change in the body. Say what the code did before, and
why that was wrong:

```
ci: Stop re-running tests in the release workflow

CI tests every push to main, and a tag must point at a commit on main, so
the release job ran the same suite a second time.
```

## Pull request checklist

- The change uses a dedicated worktree and feature branch; the PR targets `main`.
- The app builds without new warnings.
- The full test suite passes locally.
- New behavior has meaningful tests.
- User-facing strings remain localizable.
- The change uses existing visual and interaction patterns.
- Comments explain constraints, not syntax or product comparisons.
- Each commit subject follows Conventional Commits and reads as an instruction.

## License of your contribution

WSurf is Apache 2.0. Section 5 of the license puts each contribution under the
same terms, unless you say otherwise in the pull request. There is no separate
agreement to sign.

Your contribution also carries a patent license to everybody who uses WSurf.
That license covers only patents you own that your own contribution needs. Do
not submit code that you cannot license this way.
