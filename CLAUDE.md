# WSurf deployment

## Where your changes appear

The website deployment target is `https://wsurf.app`: assets-only Cloudflare
Worker `wsurf-site`, with `wsurf.app/` as the document root. Follow `AGENTS.md`:
develop in a dedicated feature worktree and merge through a reviewed PR.
A merged `main` push in `wsagency/wsurf` runs the existing `CI` workflow.
Only its successful push/main completion activates
[`.github/workflows/deploy-site.yml`](.github/workflows/deploy-site.yml),
which checks out the tested SHA, skips superseded main commits, and publishes
with `npx --yes wrangler@4.136.2 deploy`. This is the sole production path;
never deploy feature branches or dirty trees, bypass CI, create a native
Workers Builds connection, or add a second Actions/manual deploy path.

There is no website build, JavaScript Worker, or application dependency.
Preserve `.well-known/apple-app-site-association` and its existing identity.
`_headers` is the exact JSON MIME override. Verify the live anonymous HTTPS
response operationally: HTTP 200, `Content-Type: application/json`, valid TLS,
and no redirect.

`CLOUDFLARE_API_TOKEN` is a GitHub secret with **Individual Workers Editor**
for only the existing `wsurf-site`; no account-wide, DNS, route, KV, or R2
permissions. `wrangler.jsonc` omits `routes` and keeps `workers_dev` false.
The existing Custom Domain is managed separately; modifying that binding
requires explicit operator approval and separate credentials.
Native app CI/releases, signing entitlements, and credential/vault behavior
are separate. Provider, domain, token, and integration changes require
explicit operator approval. Keep secrets, signing material, and private data
out of the website and Git.
