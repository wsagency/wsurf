# Development rules

These rules apply to all code, documentation, and configuration changes in this repository.

- Use Superpowers for every task: start with `using-superpowers` and follow the relevant skills using native omp tools.

- Use one dedicated Git worktree and a unique `feature/<short-name>` branch per task, based on the latest `origin/main`. Do not develop in the `main` checkout or switch branches in a shared checkout.
- Put every linked worktree in the main repository's `.worktrees/<task>` directory, including worktrees on Pro. Do not create sibling `wsurf-worktrees` directories or put worktrees under `build`.
- Leave other tasks' uncommitted changes alone. Never stash, discard, move, or commit them as part of your task.
- Keep build output and DerivedData local to your worktree; do not reuse another worktree's build directory.
- Integrate changes only through a PR targeting `main`, after review and required CI checks pass. Never commit or push changes directly to `main`.
- Local development builds, tests, and PR validation builds are allowed on feature branches. Release builds and deployments, including signed previews, use only PR-merged commits on `main` after CI passes. Release tags must point to commits on `main`; never deploy a feature branch or dirty working tree.

Follow [CONTRIBUTING.md](CONTRIBUTING.md#development-workflow) for the worktree setup and PR checklist, and [RELEASING.md](RELEASING.md#source-and-deployment-policy) for release and deployment gates.

## Agent workflow

- Use Superpowers for all work in this repository.
- At the start of each task, read `skill://using-superpowers`, then load and
  follow the relevant Superpowers skills before responding or acting.
- Use native omp tools for the workflows: `read` for skills, `task` for
  subagents, and `todo` for task lists.

## Native builds and verification

- Develop locally on the Air (`m5air.local`); build and test the native WSurf app
  on the MacBook Pro through the existing SSH alias `pro`.
- The full Xcode installation is on Pro at `/Applications/Xcode.app`. Verified:
  Xcode 27.0 (`27A266a`), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`). Recheck the
  remote toolchain when a build reports an incompatibility.
- The Air currently has Command Line Tools, not full Xcode. Local Swift/CEF
  probes can work while the SwiftUI app build fails because `SwiftUIMacros` is
  missing. This is a local toolchain limitation, not a project-wide blocker.
  Do not fake macros or alter application semantics to bypass it.
- Before reporting missing Xcode or proposing an installation, check Pro:

  ```sh
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes pro \
    'hostname && xcode-select -p && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift --version'
  ```

- Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for remote
  build/test commands; do not change global `xcode-select` settings.
- Pro's established project is `~/projects/wsurf`. Preserve its working tree
  and existing builds. Sync current sources into an isolated worktree or owned
  build snapshot, then use the native `xcodebuild` workflow in `CONTRIBUTING.md`.
- Copy the resulting app back to the Air for real UI verification. Use a
  separate stage app and `WSURF_STAGE=1` with an owned `WSURF_STAGE_HOME`; do not
  replace the user's installed app or use production browsing data.
- Report component probes separately from whole-app builds and UI checks.
  Never claim the app is verified from a CEF probe or Swift syntax check alone.
- Production app replacement is separate from stage verification and requires the user's deployment authorization.
