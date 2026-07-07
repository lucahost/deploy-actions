# deploy-actions

Shared GitHub Actions for deploying static `*.hostettler.io` sites to the Hetzner VPS.

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

## One-time setup

This is a **private** repo, so its reusable workflow is callable from other
lucahost-owned repos only because Actions access is set to `user`:

```bash
gh api -X PUT repos/lucahost/deploy-actions/actions/permissions/access \
  -f access_level=user
```
