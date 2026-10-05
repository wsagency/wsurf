# Development rules

These rules apply to all code, documentation, and configuration changes in this repository.

- Use one dedicated Git worktree and a unique `feature/<short-name>` branch per task, based on the latest `origin/main`. Do not develop in the `main` checkout or switch branches in a shared checkout.
- Leave other tasks' uncommitted changes alone. Never stash, discard, move, or commit them as part of your task.
- Keep build output and DerivedData local to your worktree; do not reuse another worktree's build directory.
- Integrate changes only through a PR targeting `main`, after review and required CI checks pass. Never commit or push changes directly to `main`.
- Local development builds, tests, and PR validation builds are allowed on feature branches. Release builds and deployments, including signed previews, use only PR-merged commits on `main` after CI passes. Release tags must point to commits on `main`; never deploy a feature branch or dirty working tree.

Follow [CONTRIBUTING.md](CONTRIBUTING.md#development-workflow) for the worktree setup and PR checklist, and [RELEASING.md](RELEASING.md#source-and-deployment-policy) for release and deployment gates.
