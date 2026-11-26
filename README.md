# deploy-actions

Shared GitHub Actions for deploying to the Hetzner VPS: apps into its k3s cluster
(`vps-deploy.yml`, Onboarding v2 of [lucahost/vps-gitops](https://github.com/lucahost/vps-gitops))
and static `*.hostettler.io` sites (`deploy-static.yml`).

## `vps-deploy.yml` (reusable): an app into the VPS cluster

The way apps deploy from Onboarding v2 on (lucahost/vps-gitops, `docs/design.md` "Onboarding v2").
It replaced phase 2's workflow of the same name in place, so the one federated Tailscale identity's
`job_workflow_ref` claim (`lucahost/deploy-actions/.github/workflows/vps-deploy.yml@*`) names it;
phase 2's inputs (`app`, `components`, `publish-only`) and its deploy repos `lucahost/vps-app-<app>`
are gone. No deploy repo: the app repo holds `vps.yaml`, `deploy/secrets/<secret>/<KEY>` (one SOPS
file per value) and optionally `deploy/extra/*.yaml`.

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
    uses: lucahost/deploy-actions/.github/workflows/vps-deploy.yml@<40-character commit sha>   # vps-deploy, YYYY-MM-DD
    with:
      file: vps.yaml           # the default; a repo deploying several apps has vps/<app>.yaml files
    secrets: inherit           # the Environment's two secrets reach the called job only this way
```

The job runs only for a push to `main` or a dispatch on `main`; the Environment's deployment branch
policy (main only) enforces the branch, and a branch, a PR or a dispatch from a branch gets no
credentials and no tailnet identity. Keep no repository or organisation secrets in the calling repo
besides that Environment's, since `inherit` would carry them too.

- **The Environment `vps`** of the app repo (main only) holds two secrets: `VPS_REGISTRY_PASSWORD`
  and `VPS_RECEIVER_TOKEN`. `vps-onboard` (vps-gitops) creates and sets both.
- **Everything else is a default in `vps-deploy.yml`:**
  - the tailnet host;
  - the registry user (the app's name);
  - the Receiver path (derived from its token);
  - the Tailscale client ID and audience (not secrets). The identity's `job_workflow_ref` claim
    (`…/vps-deploy.yml@*`) also matches this file on other branches and old commits: a lucahost
    main job calling `vps-deploy.yml@<branch>` would join as `tag:ci-deploy`, which reaches only
    the VPS's :8446 and :8447. Callers pin a reviewed SHA, never a branch.
- **`vps.yaml`'s schema** is `vps/chart/values.schema.json`. Unknown fields are errors, and the
  secure defaults (Pod Security restricted, `hostUsers: false`, a read-only root, drop ALL,
  limits, probes) aren't fields at all. Example: `test/vps-deploy/demo/vps.yaml`.
  - `secretEnv: [<secret>]`: every key of `deploy/secrets/<secret>/` as an environment variable.
  - `secretFiles: {<secret>: <dir>}`: each key of `deploy/secrets/<secret>/` as a file in `<dir>`,
    read-only, root:<the component's gid> 0440 (the pod's `fsGroup`). For certificates and keys
    the app reads from disk. The component's CronJobs mount them too.
  - `init: true`: `shareProcessNamespace`, so the pause container is PID 1 and reaps orphans
    (compose's `init: true`; a .NET host as PID 1 can hang after a fatal start).
- **`vps-deploy-selftest.yml`** runs the step scripts, the render and the pack against a local
  registry and a fake Flux.
- **`tailscale-identity-check.yml`** (manual) proves the identity refuses everything but this
  workflow on main in Environment `vps`.

**The smoke app** (`smoke/`, `.github/workflows/smoke.yml`) is the end-to-end proof. It deploys
with `vps-deploy.yml` (`smoke/vps.yaml`; vps-gitops `tenants/smoke.yaml`): a merge that touches it,
`vps/` or `vps-deploy.yml` publishes it, and once smoke is switched over (`sudo vps cutover smoke`)
deploys it to the VPS. `vps-deploy-selftest.yml` runs the workflow's own step scripts against a
local registry and a fake Flux on every PR that touches the workflows, `vps/`, `test/vps-deploy/`
or `smoke/`.

### CI budget

Actions minutes are the owner's own and limited; a job is billed in whole minutes.

- Docs-only PRs run nothing. The self-test (≈1 minute) runs once per push to a PR that touches
  what it tests, not again on main after the merge. A newer push cancels the run still going.
- `smoke.yml` runs on main only, for merges that touch `smoke/`, `vps/` or the two workflows,
  and deploys for real (never cancelled halfway).
- Batch commits and push once per review round; no WIP pushes. Run ShellCheck and
  `python3 -I test/vps-deploy/structure.py .github/workflows/vps-deploy.yml .` locally first.
- Throwaway probe workflows on branches cost minutes too: delete the branch when the probe is done.

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
