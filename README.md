# deploy-actions

Shared GitHub Actions for deploying to the Hetzner VPS: apps into its k3s cluster
(`vps-deploy.yml`, phase 2 of [lucahost/vps-gitops](https://github.com/lucahost/vps-gitops)) and
static `*.hostettler.io` sites (`deploy-static.yml`).

## `vps-app.yml` (reusable, Onboarding v2): an app into the VPS cluster

The way apps deploy from Onboarding v2 on (lucahost/vps-gitops, `docs/design.md` "Onboarding v2").
No deploy repo: the app repo holds `vps.yaml`, `deploy/secrets/<secret>/<KEY>` (one SOPS file per
value) and optionally `deploy/extra/*.yaml`.

What the job does:
1. builds the components `vps.yaml` names;
2. joins the tailnet with the one federated identity;
3. pushes `registry.internal/<app>/<image>:<sha>` as the app's own user;
4. renders `vps.yaml` with `vps/chart` (the commit the workflow pins, through the action `vps/`)
   and packs the artifact;
5. pushes it as `<app>/manifests:<sha>`;
6. **only if `<app>/manifests:live` exists** (the cutover created it), moves `live`, calls the
   app's Receiver and waits until Flux runs it. Before the cutover the run only publishes.

```yaml
permissions:
  contents: read
  id-token: write
jobs:
  deploy:
    uses: lucahost/deploy-actions/.github/workflows/vps-app.yml@<40-character commit sha>   # vps-app, YYYY-MM-DD
    secrets: inherit           # the Environment's two secrets reach the called job only this way
```

- **The Environment `vps`** of the app repo (main only) holds two secrets: `VPS_REGISTRY_PASSWORD`
  and `VPS_RECEIVER_TOKEN`. `vps-onboard` (vps-gitops) creates and sets both.
- **Everything else is a default in `vps-app.yml`:**
  - the tailnet host;
  - the registry user (the app's name);
  - the Receiver path (derived from its token);
  - the Tailscale client ID and audience (not secrets).
- **`vps.yaml`'s schema** is `vps/chart/values.schema.json`. Unknown fields are errors, and the
  secure defaults (Pod Security restricted, `hostUsers: false`, a read-only root, drop ALL,
  limits, probes) aren't fields at all. Example: `test/vps-app/demo/vps.yaml`.
- **`vps-app-selftest.yml`** runs the step scripts, the render and the pack against a local
  registry and a fake Flux.
- **`tailscale-identity-check.yml`** (manual) proves the identity refuses everything but this
  workflow on main in Environment `vps`.

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
permissions:
  contents: read
  id-token: write            # Tailscale workload identity
jobs:
  deploy:
    # A reviewed commit of this repo, not a branch (Renovate proposes updates).
    uses: lucahost/deploy-actions/.github/workflows/vps-deploy.yml@<40-character commit sha>   # vps-deploy, YYYY-MM-DD
    with:
      app: biergit
      components: |
        api=backend
        web=frontend
    secrets: inherit           # how the Environment's secrets reach the called job (see below)
```

Get the SHA with `git ls-remote https://github.com/lucahost/deploy-actions refs/heads/main` after
reviewing that commit. The job reads its secrets and variables from the caller's **Environment
`vps`**. The caller must still pass secrets with `secrets: inherit`: GitHub hands a called workflow
only the secrets its caller passes, Environment secrets included, even when the called job names
the Environment, and otherwise they are silently empty. Keep no repository or organisation
secrets in the calling repo besides that Environment's, since `inherit` would carry them too; the
job reads only its eight names. Don't map them by name (`secrets: {X: ${{ secrets.X }}}`): the
calling job has no Environment, so those would be empty. It runs only for a push to `main` or a `workflow_dispatch` on `main`, and
the Environment's deployment branch policy (main only) enforces the branch. A branch, a PR or a dispatch from a branch gets no
credentials and no tailnet identity.

`components`: one per line, `<image>=<build context>[:<Dockerfile>]`; the image becomes
`registry.internal/<app>/<image>` in the deploy repo. `GIT_SHA` is passed as a build argument.

`publish-only` (default `false`): **dual-publish before an app's cutover.** The job builds, pushes and
bumps `lucahost/vps-app-<app>`, then stops: no Receiver call, no wait, because Flux doesn't run the
app until its cutover adds the Kustomization. The app's old deploy keeps serving it meanwhile, and
the window only has to apply digests that are already in the deploy repo. One repository variable
switches both workflows at once, so the old and the new deploy never both run the app:

```yaml
    with:
      app: biergit
      components: |
        backend=backend:backend/Biergit.Api/Dockerfile
      publish-only: ${{ vars.VPS_LIVE != 'true' }}   # the old deploy's job: if: vars.VPS_LIVE != 'true'
```

**In the app's source repo, Settings → Environments → New environment `vps`.** Set "Deployment
branches and tags" to *Selected branches*, rule `main`. Then add:

| Kind | Name | From |
|---|---|---|
| secret | `VPS_REGISTRY`, `VPS_REGISTRY_USER`, `VPS_REGISTRY_PASSWORD`, `VPS_RECEIVER_URL`, `VPS_RECEIVER_TOKEN`, `VPS_APP_DEPLOY_KEY` | printed by `app-onboard.sh <app>` on the VPS (vps-gitops README, phase 2) |
| variable | `TS_OIDC_CLIENT_ID`, `TS_OIDC_AUDIENCE` | the app's Tailscale federated identity for subject `repo:lucahost/<repo>:environment:vps`, tag `tag:ci-deploy` (vps-gitops README, phase 2) |

No repository or organisation secrets. Tailscale is joined with workload identity: GitHub's OIDC
token for that repo's Environment `vps`, which Tailscale lets join only as `tag:ci-deploy`. There
is no long-lived Tailscale secret. With these, the job can push only to `<app>/`, write only
`lucahost/vps-app-<app>`, and trigger only that app's Receiver. The platform (`tenant-images`,
`flux-tenant`, NetworkPolicies) bounds what the app can run. Rollback: `git revert` the deploy
commit in `lucahost/vps-app-<app>`.

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
