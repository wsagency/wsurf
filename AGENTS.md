# Development rules

These rules apply to all code, documentation, and configuration changes in this repository.

- Use Superpowers for every task: start with `using-superpowers` and follow the relevant skills using native omp tools.

- Use one dedicated Git worktree and a unique `feature/<short-name>` branch per task, based on the latest `origin/main`. Do not develop in the `main` checkout or switch branches in a shared checkout.
- Leave other tasks' uncommitted changes alone. Never stash, discard, move, or commit them as part of your task.
- Keep build output and DerivedData local to your worktree; do not reuse another worktree's build directory.
- Integrate changes only through a PR targeting `main`, after review and required CI checks pass. Never commit or push changes directly to `main`.
- Local development builds, tests, and PR validation builds are allowed on feature branches. Release builds and deployments, including signed previews, use only PR-merged commits on `main` after CI passes. Release tags must point to commits on `main`; never deploy a feature branch or dirty working tree.

Follow [CONTRIBUTING.md](CONTRIBUTING.md#development-workflow) for the worktree setup and PR checklist, and [RELEASING.md](RELEASING.md#source-and-deployment-policy) for release and deployment gates.

## Native builds and verification

- Develop locally on the Air (`m5air.local`); build and test the native app on Pro through the existing SSH alias `pro`.
- Pro has full Xcode at `/Applications/Xcode.app`. Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; do not change global `xcode-select`.
- Preserve Pro's `~/projects/wsurf` working tree and existing builds. Sync sources into an owned snapshot with separate DerivedData, result bundles, and stage data.
- The Air has Command Line Tools, not full Xcode. A missing `SwiftUIMacros` there is a local toolchain limitation; do not fake macros or change app semantics to bypass it.
- Before reporting missing Xcode, check Pro's `xcode-select -p`, `xcodebuild -version`, and `xcrun swift --version` with the explicit developer directory.
- Follow the native `xcodebuild` workflow in `CONTRIBUTING.md`. Copy the app to Air for actual UI verification using `WSURF_STAGE=1` and an owned `WSURF_STAGE_HOME`.
- Component probes do not prove a whole-app build or real UI behavior. Production app replacement is separate from stage verification and requires the user's deployment authorization.
