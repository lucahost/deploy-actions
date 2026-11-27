# deploy-actions

Shared GitHub Actions for deploying to the Hetzner VPS: apps, static sites included, into its k3s
cluster (`vps-deploy.yml`, Onboarding v2 of [lucahost/vps-gitops](https://github.com/lucahost/vps-gitops)).
`deploy-static.yml` and `scripts/bootstrap-secrets.sh` (rsync over Tailscale SSH as the deploy user
dp-ubuntu-16gb) are gone: no repo used them since the sites moved into the cluster, and the deploy
user is retired (vps-gitops, docs/design.md "Retiring dp-ubuntu-16gb", As built 26).

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
  - **Two identities, picked by the job's OIDC subject.** Repos created after 2026-07-15 get an
    immutable subject from GitHub (`repo:lucahost@5907956/<repo>@<repo id>:…`, no opt-out), which
    the first identity's subject `repo:lucahost/*` doesn't match. The second identity has subject
    `repo:lucahost@5907956/*` and the same claims, scope and tag (`TS_OIDC_*_IMMUTABLE`). A step
    reads only the `sub` of the job's own token and picks the pair, so no repo needs an input.
- **`vps.yaml`'s schema** is `vps/chart/values.schema.json`. Unknown fields are errors, and the
  secure defaults (Pod Security restricted, `hostUsers: false`, a read-only root, drop ALL,
  limits, probes) aren't fields at all. Example: `test/vps-deploy/demo/vps.yaml`.
  - `secretEnv: [<secret>]`: every key of `deploy/secrets/<secret>/` as an environment variable.
  - `secretFiles: {<secret>: <dir>}`: each key of `deploy/secrets/<secret>/` as a file in `<dir>`,
    read-only, root:<the component's gid> 0440 (the pod's `fsGroup`). For certificates and keys
    the app reads from disk. The component's CronJobs mount them too.
  - `init: true`: `shareProcessNamespace`, so the pause container is PID 1 and reaps orphans
    (compose's `init: true`; a .NET host as PID 1 can hang after a fatal start).
  - `postgres.args: ["-c shared_buffers=256MB", …]`: the server's tuning settings, as `-c` arguments.
    The schema allows only memory, WAL and checkpoint, planner-cost, parallelism, autovacuum and
    logging settings (`log_connections`, `log_disconnections`, `log_lock_waits`, `log_statement`,
    `log_min_duration_statement`, `log_line_prefix`), each with plain values. It never allows
    `listen_addresses`, hba or ssl, preload libraries, or any other flag. Each name once.
  - `postgres.memoryRequest` and `redis.memoryRequest` (default: their `memory`): what the scheduler
    reserves. Below `memory` the database is Burstable, with the limit still `memory`. The VPS's
    pods may request about 8 GiB in all, and Guaranteed 1–2 GiB per database didn't fit
    (fantasy-brrr, 2026-11-27) while the databases use a fraction of it. Set it near what the
    database uses. Render refuses any request above its limit.
  - `serviceAccount: true`: the component's pods run as ServiceAccount `<component>`, which the
    tenant entry creates (vps-gitops `rbac:`), with its token mounted. All others get no token.
- **`vps-deploy-selftest.yml`** runs the step scripts, the render and the pack against a local
  registry and a fake Flux.
- **`tailscale-identity-check.yml`** (manual) proves the identity refuses everything but this
  workflow on main in Environment `vps`. Dispatched here, it checks the first identity. For the
  second, a repo with an immutable subject calls it (`workflow_call`, with permissions
  `id-token: write` and `actions: read`), and it picks the pair the same way vps-deploy.yml does.

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
