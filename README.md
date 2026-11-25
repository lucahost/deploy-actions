# deploy-actions

Shared GitHub Actions for deploying to the Hetzner VPS: apps into its k3s cluster
(`vps-deploy.yml`, phase 2 of [lucahost/vps-gitops](https://github.com/lucahost/vps-gitops)) and
static `*.hostettler.io` sites (`deploy-static.yml`).

## `vps-deploy.yml` (reusable): an app into the VPS cluster

For an app that has a tenant in vps-gitops and its own deploy repo `lucahost/vps-app-<app>`. The
job builds each component on the GitHub runner, joins the tailnet as `tag:ci-deploy` (which may
reach only the VPS's registry on :8446 and its Receivers/status on :8447), pushes
`<app>/<component>:<git sha>` as the app's own registry user, commits the digest-pinned bump to
`lucahost/vps-app-<app>` with that repo's own write deploy key, calls the app's own Flux Receiver,
and waits until Flux has applied that commit and the workloads are healthy (`GET /status/<app>`
returns Flux's Kustomization). It fails if Flux reports a failure or nothing converges within
`wait-seconds` (default 300). The job summary lists the time of each step and commit → live.

```yaml
jobs:
  deploy:
    uses: lucahost/deploy-actions/.github/workflows/vps-deploy.yml@main
    with:
      app: biergit
      components: |
        api=backend
        web=frontend
    secrets:
      TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      TS_OAUTH_SECRET: ${{ secrets.TS_OAUTH_SECRET }}
      VPS_REGISTRY: ${{ secrets.VPS_REGISTRY }}
      VPS_REGISTRY_USER: ${{ secrets.VPS_REGISTRY_USER }}
      VPS_REGISTRY_PASSWORD: ${{ secrets.VPS_REGISTRY_PASSWORD }}
      VPS_RECEIVER_URL: ${{ secrets.VPS_RECEIVER_URL }}
      VPS_RECEIVER_TOKEN: ${{ secrets.VPS_RECEIVER_TOKEN }}
      VPS_APP_DEPLOY_KEY: ${{ secrets.VPS_APP_DEPLOY_KEY }}
```

`components`: one per line, `<image>=<build context>[:<Dockerfile>]`; the image becomes
`registry.internal/<app>/<image>` in the deploy repo. `GIT_SHA` is passed as a build argument.

**Secrets, per app, only in that app's source repo** (no organisation or shared secrets):

| Secret | From |
|---|---|
| `VPS_REGISTRY`, `VPS_REGISTRY_USER`, `VPS_REGISTRY_PASSWORD`, `VPS_RECEIVER_URL`, `VPS_RECEIVER_TOKEN`, `VPS_APP_DEPLOY_KEY` | printed once by `sudo bash bootstrap/app-onboard.sh <app>` on the VPS (vps-gitops README, phase 2) |
| `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` | a Tailscale OAuth client that may only issue `tag:ci-deploy` (vps-gitops README, phase 2) |

With them the job can push only to `<app>/`, write only `lucahost/vps-app-<app>`, and trigger only
that app's Receiver; the platform (`tenant-images`, `flux-tenant`, NetworkPolicies) bounds what
the app can run. Rollback: `git revert` the deploy commit in `lucahost/vps-app-<app>`.

**The smoke app** (`smoke/`, `.github/workflows/smoke.yml`) is the end-to-end proof: a merge that
touches it or `vps-deploy.yml` deploys it to the VPS. `vps-deploy-selftest.yml` runs the
workflow's own step scripts against a local registry, git repo and fake Flux on every PR.

## `deploy-static.yml` (reusable)

Joins the tailnet via Tailscale and `rsync`s the calling repo's root to the VPS
webroot, with Cloudflare cache-busting of `assets/*` URLs. The VPS Tailscale IP
(`100.102.93.2`) and SSH user (`dp-ubuntu-16gb`) are baked in — the same for
every site — so callers only supply their domain + webroot and inherit the two
Tailscale OAuth secrets.

Caller example:

```yaml
jobs:
  deploy:
    uses: lucahost/deploy-actions/.github/workflows/deploy-static.yml@main
    with:
      domain: move.hostettler.io
      deploy_path: /var/www/move.hostettler.io
    secrets: inherit
```

## `scripts/bootstrap-secrets.sh`

Sets `TS_OAUTH_CLIENT_ID` + `TS_OAUTH_SECRET` on a new site repo in one run:

```bash
./scripts/bootstrap-secrets.sh lucahost/<repo>
```

## `renovate/default.json5` (shared Renovate preset)

Dependency updates for every repo that deploys to the VPS, run by the hosted
[Mend Renovate app](https://github.com/apps/renovate). Each repo opts in with
a two-line `.github/renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["local>lucahost/deploy-actions//renovate/default.json5"]
}
```

Policy, in short: every merge deploys to prod, so **nothing automerges**.
Updates arrive as PRs in a weekly batch (Monday before 08:00 Europe/Zurich).
Security fixes skip the schedule. npm, PyPI and NuGet releases wait 3 days
before a PR opens. Postgres and Redis majors wait for a tick on each repo's
Dependency Dashboard issue. The comments in the preset explain the
reasoning for each rule.

Renovate reads the preset from `main` on every run, so editing it changes all
repos at once. Check changes before merging:

```bash
npx --package renovate -- renovate-config-validator --strict --no-global renovate/default.json5
```

**Adding a repo:** commit the `.github/renovate.json` above, then add the repo
to the app's repository list (GitHub → Settings → Applications → Renovate →
Configure). The config must reach the default branch before the app first
sees the repo; otherwise Renovate opens its own "Configure Renovate" PR.

Repos currently enrolled: biergit-v2, deploy-actions, go-web,
hostettler-auth, loore-8053, luna-eats, move, personal-website, silent-sync,
trading-platform, zueri-radar.

**Public repos keep a copy.** Mend's hosted Renovate won't let a public repo
read a preset from this private repo; the run fails with "Cannot find preset's
package". So **go-web** and **personal-website** carry a copy of the policy
in their own `.github/renovate.json5`, with private repo names removed from
the comments. When you change `renovate/default.json5`, mirror the change in
both. A new public repo needs a copy too, not the two-line `extends`.

## One-time setup

This is a **private** repo, so its reusable workflow is callable from other
lucahost-owned repos only because Actions access is set to `user`:

```bash
gh api -X PUT repos/lucahost/deploy-actions/actions/permissions/access \
  -f access_level=user
```
