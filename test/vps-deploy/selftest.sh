#!/usr/bin/env bash
# Self-test of .github/workflows/vps-deploy.yml on a GitHub runner, without the VPS: the workflow's
# own step scripts (test/vps-deploy/steps.py) run against a zot registry with the platform's access
# rules, a local bare deploy repo and a fake Flux (test/vps-deploy/fake_flux.py). Only the tailnet
# steps are left out. Checks: the bump pins the digest the registry serves; the commit message; a
# signed Receiver call; the wait step passes when Flux applies, fails when Flux reports a failure
# or nothing converges; a wrong token and another app's registry path are refused; a re-run with the
# same images commits nothing.
# shellcheck disable=SC2015  # "check && ok … || fail …": ok() always succeeds
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WF=$ROOT/.github/workflows/vps-deploy.yml
W=$(mktemp -d)
FAILED=0
ok()   { printf '   ok: %s\n' "$*"; }
fail() { printf '   FAIL: %s\n' "$*"; FAILED=1; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }
info() { printf '\n== %s\n' "$*"; }
# The registry the VPS runs (lucahost/vps-gitops infrastructure/registry/deployment.yaml).
ZOT_IMAGE=ghcr.io/project-zot/zot-minimal-linux-amd64:v2.1.23@sha256:63384d37f482ab49e112e006dba47855edcac567db247d2be9b0fe6a05da7b33

run_step() {  # $1 = step id: its script, the way Actions runs it; outputs go to $W/out.<id>
  python3 -I "$HERE/steps.py" "$WF" "$1" > "$W/step.$1.sh"
  : > "$W/out.$1"
  GITHUB_OUTPUT=$W/out.$1 bash --noprofile --norc -eo pipefail "$W/step.$1.sh"
}
out() {  # $1 = step id, $2 = output name (key=value or key<<EOF … EOF)
  python3 -I - "$W/out.$1" "$2" <<'PY'
import sys
lines, key = open(sys.argv[1]).read().split("\n"), sys.argv[2]
for i, line in enumerate(lines):
    if line.startswith(key + "="):
        print(line[len(key) + 1:]); break
    if line.startswith(key + "<<"):
        end = line[len(key) + 2:]; j = i + 1; vals = []
        while lines[j] != end:
            vals.append(lines[j]); j += 1
        print("\n".join(vals)); break
PY
}

info "fixtures: zot with per-app users, a bare deploy repo, a fake Flux"
SMOKE_PW=$(openssl rand -hex 16); OTHER_PW=$(openssl rand -hex 16)
mkdir -p "$W/zot" "$W/zotdata"; chmod 0777 "$W/zotdata"
{ printf '%s\n' "$SMOKE_PW" | htpasswd -niB -C 6 smoke; printf '%s\n' "$OTHER_PW" | htpasswd -niB -C 6 biergit; } > "$W/zot/htpasswd"
cat > "$W/zot/config.json" <<'EOF'
{
  "distSpecVersion": "1.1.1",
  "storage": {"rootDirectory": "/var/lib/registry", "dedupe": false, "gc": false},
  "http": {
    "address": "0.0.0.0", "port": "5000",
    "auth": {"htpasswd": {"path": "/etc/zot/htpasswd"}},
    "accessControl": {"repositories": {
      "smoke/**":   {"policies": [{"users": ["smoke"],   "actions": ["read", "create", "update"]}], "defaultPolicy": []},
      "biergit/**": {"policies": [{"users": ["biergit"], "actions": ["read", "create", "update"]}], "defaultPolicy": []}
    }}
  },
  "log": {"level": "warn"}
}
EOF
chmod 0644 "$W/zot/"*
docker run -d --name zot -p 127.0.0.1:5000:5000 -v "$W/zot:/etc/zot:ro" -v "$W/zotdata:/var/lib/registry" "$ZOT_IMAGE" >/dev/null
trap 'docker rm -f zot >/dev/null 2>&1 || true; kill "${FLUX_PID:-0}" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/v2/)" = 401 ] && break; sleep 1
done
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/v2/)" = 401 ] || { docker logs zot | tail -20; die "zot didn't start"; }
ok "zot: smoke may push to smoke/**, biergit to biergit/**"

git init -q --bare -b main "$W/deploy.git"
git clone -q "$W/deploy.git" "$W/seed" 2>/dev/null
cat > "$W/seed/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
images:
  - name: registry.internal/smoke/hello
    newTag: loop-20261125-071022
    digest: sha256:c3bcf3d1a53a027bfa515b9fe4fbbe7bf6b791476a5af853de439ad494b145bd
EOF
cat > "$W/seed/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: hello}
spec:
  selector: {matchLabels: {app: hello}}
  template:
    metadata: {labels: {app: hello}}
    spec: {containers: [{name: hello, image: registry.internal/smoke/hello}]}
EOF
git -C "$W/seed" add -A
git -C "$W/seed" -c user.name=seed -c user.email=seed@example.invalid commit -qm seed
git -C "$W/seed" push -q origin main
ok "bare deploy repo with the smoke app's kustomization"

openssl rand -hex 32 | tr -d '\n' > "$W/token"
echo ok > "$W/mode"; : > "$W/hook.log"
python3 -I "$HERE/fake_flux.py" 8447 "$W/token" /hook/selftest "$W/deploy.git" "$W/mode" "$W/hook.log" &
FLUX_PID=$!
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8447/status/smoke && break; sleep 0.2; done
ok "fake Flux: Receiver /hook/selftest, GET /status/<app>"

export APP=smoke SHA SOURCE_REPO=lucahost/deploy-actions RUN_ID=selftest KUSTOMIZE_VERSION KUSTOMIZE_SHA256
KUSTOMIZE_VERSION=$(python3 -I -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy"]["env"]["KUSTOMIZE_VERSION"])' "$WF")
KUSTOMIZE_SHA256=$(python3 -I -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy"]["env"]["KUSTOMIZE_SHA256"])' "$WF")
SHA=$(git -C "$ROOT" rev-parse HEAD)
export DEPLOY_REPO_URL=file://$W/deploy.git COMPONENTS=hello=smoke BUILD_ARGS="" HAVE_SECRETS=true
export VPS_REGISTRY=127.0.0.1:5000 VPS_REGISTRY_USER=smoke VPS_REGISTRY_PASSWORD=$SMOKE_PW REGISTRY_SCHEME=http
export VPS_APP_DEPLOY_KEY="unused with a file:// deploy repo"
export VPS_RECEIVER_URL=http://127.0.0.1:8447/hook/selftest WAIT_SECONDS=60
VPS_RECEIVER_TOKEN=$(cat "$W/token"); export VPS_RECEIVER_TOKEN
cd "$ROOT"

info "deploy: check, build, push, bump, Receiver, wait"
run_step check && ok "inputs and secrets checked"
t0=$(date +%s)
run_step build && ok "built smoke/ for linux/amd64"
run_step push && ok "pushed as smoke"
IMAGES=$(out push images); export IMAGES
digest=$(curl -fsSI -u "smoke:$SMOKE_PW" -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "http://127.0.0.1:5000/v2/smoke/hello/manifests/$SHA" | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}')
[ "$IMAGES" = "registry.internal/smoke/hello:$SHA@$digest" ] && ok "image line pins the digest the registry serves ($digest)" \
  || fail "images output '$IMAGES' vs registry digest '$digest'"
run_step bump && ok "bumped the deploy repo"
BUMP_SHA=$(out bump bump-sha); export BUMP_SHA
[ "$(out bump changed)" = true ] && ok "a new deploy commit" || fail "no commit made"
k=$(git --git-dir "$W/deploy.git" show main:kustomization.yaml)
grep -q "newTag: $SHA" <<<"$k" && grep -q "digest: $digest" <<<"$k" && ok "kustomization.yaml: newTag $SHA, digest $digest" \
  || { fail "kustomization.yaml not bumped:"; printf '%s\n' "$k"; }
msg=$(git --git-dir "$W/deploy.git" log -1 --format=%s main)
[ "$msg" = "deploy(smoke): hello ${SHA:0:7} (lucahost/deploy-actions@${SHA:0:7}, run selftest)" ] && ok "commit: $msg" || fail "commit message: $msg"
[ "$(git --git-dir "$W/deploy.git" rev-parse main)" = "$BUMP_SHA" ] && ok "bump-sha is the deploy repo's main" || fail "bump-sha differs from main"
run_step notify && ok "Receiver accepted the signed call"
[ "$(grep -c '^accepted ' "$W/hook.log")" = 1 ] && ok "fake Flux verified one HMAC signature" || fail "hook log: $(cat "$W/hook.log")"
grep -q "\"bump\":\"$BUMP_SHA\"" "$W/hook.log" && ok "the body names the deploy commit" || fail "body lacks the bump sha"
if run_step wait; then ok "wait: applied and Ready seen through GET /status/smoke"; else fail "wait failed on a good deploy"; fi
ok "build → live here: $(( $(date +%s) - t0 )) s (no tailnet; the VPS timings come from the smoke workflow's summary)"

info "a re-run with the same images commits nothing"
run_step bump >/dev/null
[ "$(out bump changed)" = false ] && [ "$(out bump bump-sha)" = "$BUMP_SHA" ] && ok "no second commit" || fail "re-run committed again"

info "failures the job must report"
# Each failure comes with a new deploy commit, as a real failing deploy would (a Receiver call for a
# revision Flux already runs leaves it Ready, and the wait rightly passes at once).
new_bump() {  # $1 = a fake digest character: commits a bump to that digest, exports BUMP_SHA
  IMAGES="registry.internal/smoke/hello:$1$1$1@sha256:$(printf '%064d' 0 | tr 0 "$1")" run_step bump >/dev/null
  BUMP_SHA=$(out bump bump-sha); export BUMP_SHA
}
new_bump d
echo fail > "$W/mode"; run_step notify >/dev/null
if out_w=$(run_step wait 2>&1); then fail "wait passed although Flux reported HealthCheckFailed"; else
  grep -q "Flux couldn't apply" <<<"$out_w" && ok "wait fails when Flux reports a failure" || fail "wait failed for another reason: $out_w"; fi
new_bump e
echo never > "$W/mode"; run_step notify >/dev/null
if out_w=$(WAIT_SECONDS=6 run_step wait 2>&1); then fail "wait passed although nothing converged"; else
  grep -q "not applied and healthy after 6s" <<<"$out_w" && ok "wait fails when nothing converges in time" || fail "wait failed for another reason: $out_w"; fi
if VPS_RECEIVER_TOKEN=wrong run_step notify >/dev/null 2>&1; then fail "a wrong token was accepted"; else ok "the Receiver refuses a wrong token"; fi
if APP=biergit run_step build >/dev/null 2>&1 && APP=biergit run_step push >/dev/null 2>&1; then
  fail "smoke's credentials pushed to biergit/"; else ok "smoke's credentials can't push to biergit/"; fi

if [ "$FAILED" -ne 0 ]; then echo; echo "!! vps-deploy self-test FAILED"; exit 1; fi
echo; echo "vps-deploy self-test: all checks passed"
