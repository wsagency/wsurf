# Branch handoff, 2026-10-16

Purpose: move all existing work to another computer. This document is metadata only. It is not a feature, not an approval to merge or deploy any old code, and not a build or test result.

## Read this first
- **305 uncommitted paths in 6 local worktrees are NOT in the clone and NOT published.** Only the committed HEAD of each branch was pushed; the dirty contents were not (305 paths in total, listed in "Excluded uncommitted work"). Their owners could not be established, so nothing was committed, stashed, moved or deleted. **Keep the old checkout** (`<original-repo>` with its `.worktrees/` and `build/` directories, and the sibling `../wsurf-worktrees/` directory) until those changes are reviewed. Do not delete or migrate anything automatically.
- **Publication here is archival preservation only. It is NOT a merge, readiness, test or deployment approval.** Do not merge historical branches blindly: they contain old workflow, security and product versions. Review each against current `origin/main` first.
- Do not claim all work is committed. Only committed branch heads are published.
- Generated build output, ignored reports, downloaded tools, local settings and private user data (vaults, credentials, sessions) were deliberately not published.

## Remote state (origin = `wsagency/wsurf`)
- `origin/main` = `9f4b51554cfa` (branding PR [#24](https://github.com/wsagency/wsurf/pull/24), "Flux brand kit (design draft and candidate art)"). Local `main` in the old root checkout is stale (`9606f9d4d146`, 19 commits behind, no unique commits) and was never pushed. Start from `origin/main`.
- Issue [#25](https://github.com/wsagency/wsurf/issues/25) is NOT a general handoff tracker. It is an open task about Apple Passwords import: a transfer containing a note is refused in full because `CredentialExchangeCodec.importCredential` handles only basic authentication, passkey and TOTP and throws `unsupported` for any other kind, and the account model has no field for a note. No fix has been started; the diagnostic change on `feature/native-exchange-malformed-20261015` only names the position, kind and reason.
- The `CI` workflow is disabled on the server (`disabled_manually`) and was kept disabled; no workflow run was started by the branch pushes. The other workflows (Deploy website, Release, Preview) remain active but are not triggered by plain branch pushes. No tag was pushed. **No build, test or CI run was performed for this handoff.**
- All branches were pushed with explicit, non-force refspecs. No `--all`, `--mirror`, tags, push to `main`, pull request or merge was done by this handoff. A pre-publication screen of the outgoing commits (37 commits, 894 blob paths) detected no real credential patterns. This is a bounded screen, not proof of absence. The matches were synthetic test fixtures (for example self-signed test certificates in `WSurfTests/Web/ClientCertificateTests.swift` and test literals in credential-exchange tests).

## Integration branch
`feature/main-integration-20261015` at `a98f51f9f0fb` contains PR #21, #22 and #23 (with the PR #13 spec) plus eight local groups. It is **published but NOT merged into `main`**, and no UI or runtime behaviour of the integrated app is claimed here. Checks recorded earlier were source reviews, SwiftLint (strict) on the tree, and two small component/WKWebView harness runs; the whole-app build, full test suite and UI checks were not run. A native validation on the Pro machine, a PR to `main`, and a signed build remain with DevOps. Details are in PR #23 comment `issuecomment-6202423240`. The branch is 1 commit behind the current `origin/main` (the branding PR).

## Special cases
- `feature/mcp-takeover-20261010`: the old computer's local copy (`6d26f68a0ebf`) is 12 commits behind the remote head (`232074e22977`) and has nothing local-only. The remote is the newer copy and was not touched.
- `feature/wsurf-cloudflare-site` exists only on the remote (no local branch).
- `feature/certilia-smartcard-research-20261014` (`c637c7b53846`) contains two deliberately synthetic, self-signed PKCS12 test identities in a test file. They were published for archival only; the tests were not re-run and nothing claims hardware smart card validation.
- `feature/logo-concepts-20261016` (`e44f1c00d6cb`) adds only `docs/logo-concepts/` (146 original concept files: 129 PNG, 13 SVG, 4 Markdown).
- 15 local tags (`tip`, `v0.1.0` to `v0.8.0`) and 1 local stash entry (`refs/stash`) were NOT pushed. `v0.8.0` is the only tag not contained in `origin/main`.
- A registered worktree at `/tmp/wsurf-pr2-integration-20261006` (branch `feature/wsurf-cloudflare-site-main-integration`) no longer exists on disk; its branch is published at `b143e6ad`.

## Branch to head mapping (the 61 pre-existing local branch heads)
The new branch `feature/branch-handoff-20261016` (this document and its companion) is additional, so the old computer has 62 local heads in total; it is not listed in the table and its own head is not recorded here.
`same` means the remote branch of the same name has the same commit as the old computer's local branch.

| Branch | Local head | Remote head | Status |
|---|---|---|---|
| `backup/main-before-pr7-cleanup-20261006` | `971d10695610` | `971d10695610` | same |
| `chore/main-residual-config-20261006` | `4f4999485714` | `4f4999485714` | same |
| `docs/linen-upstream-20261006` | `971d10695610` | `971d10695610` | same |
| `feat/profile-credentials-20261006` | `19def9701ba6` | `19def9701ba6` | same |
| `feature/anylanguage-016-20261014` | `588a92715e1f` | `588a92715e1f` | same |
| `feature/certilia-smartcard-research-20261014` | `c637c7b5384d` | `c637c7b5384d` | same |
| `feature/chromium-assistant-browser-20261009` | `fb7b91c2c5f5` | `fb7b91c2c5f5` | same |
| `feature/chromium-mcp-verification-20261006` | `ad8638b940a0` | `ad8638b940a0` | same |
| `feature/ci-test-isolation-20261012` | `52e8f54a4dba` | `52e8f54a4dba` | same |
| `feature/credential-account-writes-20261013` | `b1b78fe12e05` | `b1b78fe12e05` | same |
| `feature/credential-exchange-classification-20261012` | `164837776f24` | `164837776f24` | same |
| `feature/credential-fixture-kit-20261012` | `cc3df898148d` | `cc3df898148d` | same |
| `feature/credential-save` | `ca64609308a0` | `ca64609308a0` | same |
| `feature/credential-unlock-window-20261015` | `a5550bc54982` | `a5550bc54982` | same |
| `feature/credential-vault-benchmarks-20261013` | `c2d416cc190b` | `c2d416cc190b` | same |
| `feature/credential-vault-creation-20261013` | `2e836806bd74` | `2e836806bd74` | same |
| `feature/credential-vault-sync-20261012` | `9c5a9601061b` | `9c5a9601061b` | same |
| `feature/credential-vault-ui-20261013` | `de50cbdedf70` | `de50cbdedf70` | same |
| `feature/credential-website-wiring-20261012` | `65d2c09dba08` | `65d2c09dba08` | same |
| `feature/credential-websites-20261012` | `ec3a99be1078` | `ec3a99be1078` | same |
| `feature/credentials-integration-20261010` | `b77dcf5c2495` | `b77dcf5c2495` | same |
| `feature/deployment-approval` | `a98f066ff1ec` | `a98f066ff1ec` | same |
| `feature/development-workflow` | `b4911b94cf2a` | `b4911b94cf2a` | same |
| `feature/embedded-chromium` | `a56f513bd40b` | `a56f513bd40b` | same |
| `feature/flux-brand-system-20261016` | `574ed7a0408a` | `574ed7a0408a` | same |
| `feature/import-export-entry-20261014` | `74eaa5b41045` | `74eaa5b41045` | same |
| `feature/linen-080-assess-20261009` | `fb7b91c2c5f5` | `fb7b91c2c5f5` | same |
| `feature/linen-address-search-20261014` | `593ffd7d89a8` | `593ffd7d89a8` | same |
| `feature/linen-deploy-notes-20261008` | `1ddb8d4a4b6d` | `1ddb8d4a4b6d` | same |
| `feature/linen-device-images-20261014` | `813a4b46b585` | `813a4b46b585` | same |
| `feature/linen-intake-20261014` | `f1f16a010a02` | `f1f16a010a02` | same |
| `feature/linen-migration-plan-20261006` | `469d01d30428` | `469d01d30428` | same |
| `feature/linen-page-tools-20261014` | `182a9d36f696` | `182a9d36f696` | same |
| `feature/linen-ui-polish-20261014` | `10dded87b5de` | `10dded87b5de` | same |
| `feature/linen-upstream-migration` | `b8b5c042c2c9` | `b8b5c042c2c9` | same |
| `feature/linen-upstream-process-20261010` | `2f287a68941d` | `2f287a68941d` | same |
| `feature/linen-upstream-research-20261014` | `d3cf4097c541` | `d3cf4097c541` | same |
| `feature/linen-wheel-refresh-20261014` | `6f1deaea3b44` | `6f1deaea3b44` | same |
| `feature/logo-concepts-20261016` | `e44f1c00d6cb` | `e44f1c00d6cb` | same |
| `feature/main-integration-20261015` | `a98f51f9f0fb` | `a98f51f9f0fb` | same |
| `feature/mandatory-worktrees-20261006` | `90875621ebd0` | `90875621ebd0` | same |
| `feature/mcp-development-mode` | `c47851f6b94b` | `c47851f6b94b` | same |
| `feature/mcp-development-tools` | `971d10695610` | `971d10695610` | same |
| `feature/mcp-spec-refresh-20261014` | `7691c19ea5ad` | `7691c19ea5ad` | same |
| `feature/mcp-takeover-20261010` | `6d26f68a0ebf` | `232074e22977` | DIFFERS - local is 12 commits behind the remote head; remote is the newer copy, local was NOT pushed |
| `feature/mcp-window-scope-diagnostics-20261010` | `a921fed0f2d0` | `a921fed0f2d0` | same |
| `feature/native-exchange-malformed-20261015` | `aaeaa77ce3bf` | `aaeaa77ce3bf` | same |
| `feature/new-tab-title-readiness-20261010` | `7f153fbbd3b2` | `7f153fbbd3b2` | same |
| `feature/nonchromium-release` | `ebcb7b8959fc` | `ebcb7b8959fc` | same |
| `feature/pro-main-snapshot-20261010` | `208d45230a24` | `208d45230a24` | same |
| `feature/pro-refresh-archive-20261010` | `2bfe4b0a10dc` | `2bfe4b0a10dc` | same |
| `feature/remove-browser-passkey-entitlement-20261011` | `27a25103f071` | `27a25103f071` | same |
| `feature/sidebar-customization` | `838eefc10c95` | `838eefc10c95` | same |
| `feature/sidebar-themes-integration-20261006` | `7e47eea39f82` | `7e47eea39f82` | same |
| `feature/sleep-timer-themes-20261015` | `a54d7aa23dad` | `a54d7aa23dad` | same |
| `feature/url-engine-indicator-20261008` | `1c8781363095` | `1c8781363095` | same |
| `feature/wsurf-cloudflare-site-main-integration` | `b143e6ada38b` | `b143e6ada38b` | same |
| `fix/extension-api-stand-ins` | `2e8220eb8545` | `2e8220eb8545` | same |
| `fix/sidebar-theme-ci-format-20261006` | `0d2d2426cb49` | `0d2d2426cb49` | same |
| `main` | `9606f9d4d146` | `9f4b51554cfa` | DIFFERS - local main is stale (19 behind remote), never pushed; do not use |
| `review/I1-ded975d` | `ded975d0e396` | `ded975d0e396` | same |

## Excluded uncommitted work (working-tree changes not checkpointed by this handoff)
These are uncommitted working-tree changes that this handoff did not checkpoint; a clone cannot be assumed to preserve them (equivalent content might exist elsewhere, which was not verified).
Counts are `git status` path entries seen on 2026-10-16. Paths are repository-relative. The two root modifications belong to the user; the remaining changes are unattributed to this session (the credential, Linen and sidebar owners could not claim them). The ownership of the root `docs/devops-handoff.md` is unconfirmed and no authorship is claimed. File contents were not read or copied. All of these stay untouched.

| Worktree (old computer) | Branch | Entries |
|---|---|---|
| `build/sidebar-customization` | `feature/sidebar-customization` | 225 (203 modified, 22 untracked); mostly under `WSurf/Web` (71), `WSurfTests/Web` (41), `WSurf/UI` (32), `WSurf/Settings` (14) |
| `.worktrees/profile-credentials-20261006` | `feat/profile-credentials-20261006` | 72 (34 modified, 38 untracked); mostly under `WSurf/Web` (34), `WSurfTests/Web` (15), `WSurf/Settings` (5), `docs/superpowers` (3); a status summary shows 51 because untracked directories collapse |
| root checkout `<original-repo>` | `main` | 3: `CHANGELOG.md` (M), `WSurf/Web/Tabs/BrowserTab.swift` (M), `docs/devops-handoff.md` (untracked); these belong to the user |
| `.worktrees/linen-upstream-20261006` | `docs/linen-upstream-20261006` | 2: `.gitignore` (M), `docs/linen-upstream.md` (untracked) |
| `../wsurf-worktrees/deployment-approval` (sibling of the repo) | `feature/deployment-approval` | 2: `AGENTS.md` (M), `RELEASING.md` (M) |
| `.worktrees/credential-websites-20261012` | `feature/credential-websites-20261012` | 1: `WSurf/main.swift` (M) |

Total 305. All other worktrees were clean. Several other published branches exist only on this computer as local worktree directories under `.worktrees/`; their committed heads are in the table, and their ignored `build/` directories (reports, tools, harness output) were not published.

## How to continue on the new computer
1. `git clone git@github.com:wsagency/wsurf.git` and `git fetch origin`. Every branch listed above (except local `main` and the unpushed tags/stash) is on origin under the same name.
2. Create worktrees for the branches you need (for example `git worktree add .worktrees/<name> -b <name> origin/<name>`), never work in the root checkout.
3. For the uncommitted items above, go back to the old computer's directories, review each change with its owner, and commit it deliberately.

## Companion document
Curated Linen upstream research: [linen-research-handoff-2026-10-16.md](linen-research-handoff-2026-10-16.md) (pinned upstream state, open inbound candidates, deferred and rejected items, outbound candidates, limits).
