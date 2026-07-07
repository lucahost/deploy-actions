#!/usr/bin/env bash
# Set the two Tailscale OAuth secrets on a site repo that deploys via
# lucahost/deploy-actions. Reads values from the environment, or prompts.
#
# Usage:
#   TS_OAUTH_CLIENT_ID=... TS_OAUTH_SECRET=... ./scripts/bootstrap-secrets.sh lucahost/move
#   ./scripts/bootstrap-secrets.sh lucahost/move        # prompts for both
set -euo pipefail

REPO="${1:?usage: bootstrap-secrets.sh <owner/repo>}"

: "${TS_OAUTH_CLIENT_ID:=}"
: "${TS_OAUTH_SECRET:=}"

if [[ -z "$TS_OAUTH_CLIENT_ID" ]]; then
  read -rp  "TS_OAUTH_CLIENT_ID: " TS_OAUTH_CLIENT_ID
fi
if [[ -z "$TS_OAUTH_SECRET" ]]; then
  read -rsp "TS_OAUTH_SECRET: " TS_OAUTH_SECRET; echo
fi

gh secret set TS_OAUTH_CLIENT_ID --repo "$REPO" --body "$TS_OAUTH_CLIENT_ID"
gh secret set TS_OAUTH_SECRET    --repo "$REPO" --body "$TS_OAUTH_SECRET"

echo "✓ Set TS_OAUTH_CLIENT_ID + TS_OAUTH_SECRET on $REPO"
