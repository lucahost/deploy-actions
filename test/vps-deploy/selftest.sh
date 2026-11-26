#!/usr/bin/env bash
# Self-test of .github/workflows/vps-deploy.yml (Onboarding v2) on a GitHub runner, without the VPS:
# the workflow's own step scripts (test/vps-deploy/steps.py) and its render/pack action run against
# a zot registry with the platform's access rules and a fake Flux (test/vps-deploy/fake_flux_oci.py).
# Only the tailnet steps are left out. Checks:
#   - the build makes one image per component and migrate; the push pins what the registry serves;
#   - the artifact holds the rendered manifests, extra/ and the secretGenerator, builds, and passes
#     kubeconform; every pod has the secure defaults;
#   - without `live` the run only publishes; after a cutover made `live`, the next run moves it,
#     calls the Receiver and waits (applied passes; a failure and a timeout fail);
#   - refused: another app's registry path, a plaintext secret file, unknown vps.yaml fields.
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
ZOT_IMAGE=ghcr.io/project-zot/zot-minimal-linux-amd64:v2.1.23@sha256:63384d37f482ab49e112e006dba47855edcac567db247d2be9b0fe6a05da7b33
APP_DIR=$W/app

run_step() {  # $1 = step id: its script, the way Actions runs it, in the app's checkout
  python3 -I "$ROOT/test/vps-deploy/steps.py" "$WF" "$1" > "$W/step.$1.sh"
  : > "$W/out.$1"
  (cd "$APP_DIR" && GITHUB_OUTPUT=$W/out.$1 GITHUB_STEP_SUMMARY=$W/summary bash --noprofile --norc -eo pipefail "$W/step.$1.sh")
}
out() { sed -n "s/^$2=//p" "$W/out.$1" | head -1; }

info "fixtures: zot (demo, other, vps-cutover, puller), the demo app, a fake Flux"
DEMO_PW=$(openssl rand -hex 16); OTHER_PW=$(openssl rand -hex 16); CUT_PW=$(openssl rand -hex 16)
mkdir -p "$W/zot" "$W/zotdata"; chmod 0777 "$W/zotdata"
{ printf '%s\n' "$DEMO_PW" | htpasswd -niB -C 6 demo; printf '%s\n' "$OTHER_PW" | htpasswd -niB -C 6 other
  printf '%s\n' "$CUT_PW" | htpasswd -niB -C 6 vps-cutover; } > "$W/zot/htpasswd"
cat > "$W/zot/config.json" <<'EOF'
{
  "distSpecVersion": "1.1.1",
  "storage": {"rootDirectory": "/var/lib/registry", "dedupe": false, "gc": false},
  "http": {
    "address": "0.0.0.0", "port": "5000",
    "auth": {"htpasswd": {"path": "/etc/zot/htpasswd"}},
    "accessControl": {"repositories": {
      "demo/**":  {"policies": [{"users": ["demo"], "actions": ["read", "create", "update"]},
                                {"users": ["vps-cutover"], "actions": ["read", "create", "update"]}], "defaultPolicy": []},
      "other/**": {"policies": [{"users": ["other"], "actions": ["read", "create", "update"]}], "defaultPolicy": []}
    }}
  },
  "log": {"level": "warn"}
}
EOF
chmod 0644 "$W/zot/"*
docker run -d --name zot-v2 -p 127.0.0.1:5000:5000 -v "$W/zot:/etc/zot:ro" -v "$W/zotdata:/var/lib/registry" "$ZOT_IMAGE" >/dev/null
trap 'docker rm -f zot-v2 >/dev/null 2>&1 || true; kill "${FLUX_PID:-0}" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/v2/)" = 401 ] && break; sleep 1; done
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/v2/)" = 401 ] || { docker logs zot-v2 | tail -20; die "zot didn't start"; }
cp -r "$HERE/demo" "$APP_DIR"
git -C "$APP_DIR" init -q && git -C "$APP_DIR" add -A && git -C "$APP_DIR" -c user.name=t -c user.email=t@t commit -qm demo
TOKEN=$(openssl rand -hex 32); printf '%s' "$TOKEN" > "$W/token"
HOOK=$(printf '%s%s%s' "$TOKEN" receiver-demo flux-system | sha256sum | cut -d' ' -f1)
printf 'vps-cutover:%s' "$CUT_PW" > "$W/cutcred"; echo ok > "$W/mode"
python3 -I "$HERE/fake_flux_oci.py" 8088 "$W/token" "$HOOK" http://127.0.0.1:5000 "$W/cutcred" demo "$W/mode" > "$W/flux.log" 2>&1 &
FLUX_PID=$!

export FILE=vps.yaml SOURCE_REPO=lucahost/demo RUN_ID=1 VPS_HOST=vps.invalid REGISTRY_PORT=8446 HOOK_PORT=8447 \
  TS_OIDC_CLIENT_ID="" TS_OIDC_AUDIENCE="" VPS_DEPLOY_SELFTEST=1 FLUX_VERSION=2.9.6 \
  FLUX_SHA256=b4d22673e9246cbd628881f1a9ef3b090085dced291e42d804555cee8e8d42c5 \
  REGISTRY_HOST=127.0.0.1:5000 REGISTRY_SCHEME=http FLUX_INSECURE=1 HOOK_BASE=http://127.0.0.1:8088 \
  SET_VPS_REGISTRY_PASSWORD=true SET_VPS_RECEIVER_TOKEN=true VPS_REGISTRY_PASSWORD=$DEMO_PW VPS_RECEIVER_TOKEN=$TOKEN WAIT_SECONDS=20
export RUNNER_TEMP=$W/runner; mkdir -p "$RUNNER_TEMP"

deploy() {  # $1 = commit sha: check, build, push, render+pack (the action's scripts), publish, summary
  # Called with || (which turns off set -e inside), so every step returns on its own failure.
  export SHA=$1; rm -rf "$RUNNER_TEMP/artifact"; : > "$W/summary"
  run_step check || { echo "!! check failed"; return 1; }; APP=$(out check app); export APP
  run_step build || { echo "!! build failed"; return 1; }; NAMES=$(out build names); export NAMES
  run_step push || { echo "!! push failed"; return 1; }; IMAGES=$(out push images); export IMAGES
  printf '%s' "$IMAGES" > "$W/images.json"
  (cd "$APP_DIR" && bash "$ROOT/vps/render.sh" vps.yaml "$W/images.json" "$SHA" "$W/rendered.yaml" \
     && bash "$ROOT/vps/pack.sh" . "$W/rendered.yaml" "$RUNNER_TEMP/artifact") || { echo "!! render/pack failed"; return 1; }
  run_step publish || { echo "!! publish failed"; return 1; }
  DIGEST=$(out publish digest); export DIGEST
  LIVE=$(out publish live) ARTIFACT=$(out publish artifact) run_step summary || { echo "!! summary failed"; return 1; }
}

info "a deploy before the cutover: publish only"
SHA1=$(printf '%040d' 1)
deploy "$SHA1" > "$W/deploy1.log" 2>&1 || { cat "$W/deploy1.log"; die "the first deploy failed"; }
expect_names='["web","api","api-migrate"]'
[ "$(out build names | jq -c 'sort')" = "$(jq -c 'sort' <<<"$expect_names")" ] && ok "built web, api and api-migrate" || fail "built $(out build names)"
grep -q "registry.internal/demo/api:$SHA1@sha256:" <<<"$(out push images)" && ok "images pinned by the registry's digests" || fail "images: $(out push images)"
[ "$(out publish live)" = false ] && ok "no live tag: published only" || fail "live=$(out publish live) before any cutover"
grep -q "Published only" "$W/summary" && ok "the summary says so" || fail "no 'Published only' in the summary"
# flux pull wants an existing output directory; credentials through a docker config, not argv
mkdir -p "$W/pulled" "$W/pull-docker"
AUTH=$(printf 'demo:%s' "$DEMO_PW" | base64 -w0) jq -n '{auths: {"127.0.0.1:5000": {auth: $ENV.AUTH}}}' > "$W/pull-docker/config.json"
if ! DOCKER_CONFIG=$W/pull-docker flux pull artifact "oci://127.0.0.1:5000/demo/manifests:$SHA1" --output "$W/pulled" --insecure-registry > "$W/pull.log" 2>&1; then
  fail "flux pull artifact: $(tail -3 "$W/pull.log")"
elif diff -r "$W/pulled" "$RUNNER_TEMP/artifact" >/dev/null; then ok "the artifact in the registry is what was packed"
else fail "pulled artifact differs: $(diff -rq "$W/pulled" "$RUNNER_TEMP/artifact" | head -3)"; fi
if kubectl kustomize "$W/pulled" > "$W/built.yaml" 2> "$W/kustomize.log"; then ok "the artifact builds (kustomize)"
else fail "kustomize build of the artifact: $(tail -3 "$W/kustomize.log")"; fi
[ -s "$W/built.yaml" ] || die "nothing built; the checks below would pass on nothing"
if command -v kubeconform >/dev/null; then
  kubeconform -strict -summary -kubernetes-version master "$W/built.yaml" >/dev/null && ok "kubeconform: valid" || fail "kubeconform: $(kubeconform -strict -kubernetes-version master "$W/built.yaml" 2>&1 | tail -3)"
fi
pods=$(grep -c "hostUsers: false" "$W/built.yaml" || true)
expect_pods=$(grep -cE '^kind: (Deployment|CronJob)$' "$W/built.yaml")
[ "$pods" = "$expect_pods" ] && ok "every pod template ($pods) has hostUsers: false" || fail "hostUsers: false on $pods of $expect_pods pod templates"
for k in 'readOnlyRootFilesystem: true' 'allowPrivilegeEscalation: false' 'runAsNonRoot: true' 'automountServiceAccountToken: false'; do
  [ "$(grep -c "$k" "$W/built.yaml")" -ge "$expect_pods" ] && ok "$k everywhere" || fail "$k missing somewhere"
done
grep -q 'name: demo-env-' "$W/built.yaml" && grep -q 'JWT_SECRET:' "$W/built.yaml" && ok "secretGenerator: Secret demo-env-<hash>, its key, the references rewritten" || fail "no generated Secret"
# Read from the built objects (kustomize rewrites the chart's flow mappings as blocks):
# "<kind>/<name> <volume's secretName> <defaultMode> <mountPath> <readOnly>" per secretFiles volume.
sf=$(python3 -I - "$W/built.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") not in ("Deployment", "CronJob"):
        continue
    t = d["spec"]["template"] if d["kind"] == "Deployment" else d["spec"]["jobTemplate"]["spec"]["template"]
    vols = {v["name"]: v for v in t["spec"].get("volumes", [])}
    for c in t["spec"]["containers"]:
        for m in c.get("volumeMounts", []):
            s = vols.get(m["name"], {}).get("secret")
            if s:
                print(d["kind"] + "/" + d["metadata"]["name"], s["secretName"].rsplit("-", 1)[0], s.get("defaultMode"), m["mountPath"], m.get("readOnly"))
PY
)
expect_sf=$'Deployment/api demo-certs 288 /app/certs True\nCronJob/cleanup demo-certs 288 /app/certs True'
[ "$sf" = "$expect_sf" ] && grep -q 'secretName: demo-certs-' "$W/built.yaml" \
  && ok "secretFiles: Secret demo-certs-<hash> read-only at /app/certs, 0440, in api and its cron" || fail "secretFiles: $sf"
[ "$(grep -c 'fsGroup: 1654' "$W/built.yaml")" = 2 ] && ok "… with fsGroup = api's gid (1654), only where secretFiles are" || fail "fsGroup: $(grep -c fsGroup "$W/built.yaml")"
[ "$(grep -c 'shareProcessNamespace: true' "$W/built.yaml")" = 3 ] && ok "init: true → shareProcessNamespace in api and its cron (postgres has it anyway)" \
  || fail "shareProcessNamespace: $(grep -c 'shareProcessNamespace: true' "$W/built.yaml")"

info "a parked app (vps-gitops As built 21): live is the parked artifact, a deploy only publishes"
# What `vps` does on a rollback or reset, as vps-cutover: an empty kustomization annotated parked,
# pushed as demo/manifests:parked, its manifest PUT under live.
mkdir -p "$W/parked" "$W/cut-docker"
printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' 'resources: []' > "$W/parked/kustomization.yaml"
AUTH=$(printf 'vps-cutover:%s' "$CUT_PW" | base64 -w0) jq -n '{auths: {"127.0.0.1:5000": {auth: $ENV.AUTH}}}' > "$W/cut-docker/config.json"
if DOCKER_CONFIG=$W/cut-docker flux push artifact oci://127.0.0.1:5000/demo/manifests:parked --path "$W/parked" --source vps-gitops \
     --revision "parked@sha1:$(printf '%040d' 0)" --annotations vps.hostettler.io/parked=true --reproducible --insecure-registry > "$W/park.log" 2>&1; then
  pmt=application/vnd.oci.image.manifest.v1+json
  printf 'user = "vps-cutover:%s"\n' "$CUT_PW" | curl -fsS -K - -H "Accept: $pmt" -o "$W/parked.json" http://127.0.0.1:5000/v2/demo/manifests/manifests/parked \
    && printf 'user = "vps-cutover:%s"\n' "$CUT_PW" | curl -fsS -K - -X PUT -H "Content-Type: $pmt" --data-binary @"$W/parked.json" -o /dev/null \
         http://127.0.0.1:5000/v2/demo/manifests/manifests/live && ok "live → the parked artifact (what a rollback does)" || fail "parking live"
else fail "pushing the parked artifact: $(tail -3 "$W/park.log")"; fi
parked=$(printf 'user = "demo:%s"\n' "$DEMO_PW" | curl -s -I -K - -H 'Accept: application/vnd.oci.image.manifest.v1+json' http://127.0.0.1:5000/v2/demo/manifests/manifests/live | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}')
SHAP=$(printf '%040d' 9)
deploy "$SHAP" > "$W/deployp.log" 2>&1 || { cat "$W/deployp.log"; die "the deploy while parked failed"; }
[ "$(out publish live)" = false ] && ok "live parked: published only" || fail "live=$(out publish live) while parked"
grep -q "live is parked" "$W/deployp.log" && grep -q "Published only" "$W/summary" && ok "… it says so, and the summary too" || fail "no 'live is parked' / 'Published only'"
now=$(printf 'user = "demo:%s"\n' "$DEMO_PW" | curl -s -I -K - -H 'Accept: application/vnd.oci.image.manifest.v1+json' http://127.0.0.1:5000/v2/demo/manifests/manifests/live | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}')
[ -n "$parked" ] && [ "$now" = "$parked" ] && ok "live still the parked artifact ($now)" || fail "live moved while parked: $parked → $now"

info "the cutover makes live; the next deploy moves it and waits"
# What `vps cutover` does as vps-cutover: the artifact's manifest PUT under "live".
mt=application/vnd.oci.image.manifest.v1+json; d1=$(out publish digest)
if printf 'user = "vps-cutover:%s"\n' "$CUT_PW" | curl -fsS -K - -H "Accept: $mt" -o "$W/m1.json" "http://127.0.0.1:5000/v2/demo/manifests/manifests/$d1" \
   && printf 'user = "vps-cutover:%s"\n' "$CUT_PW" | curl -fsS -K - -X PUT -H "Content-Type: $mt" --data-binary @"$W/m1.json" -o /dev/null \
        "http://127.0.0.1:5000/v2/demo/manifests/manifests/live"; then
  ok "vps-cutover tagged live (what 'vps cutover' does)"
else fail "vps-cutover couldn't tag live: $(docker logs zot-v2 2>&1 | tail -5)"; fi
SHA2=$(printf '%040d' 2)
deploy "$SHA2" > "$W/deploy2.log" 2>&1 || { cat "$W/deploy2.log"; die "the second deploy failed"; }
[ "$(out publish live)" = true ] && ok "live exists: this run deploys" || fail "live=$(out publish live) after the cutover"
live=$(printf 'user = "demo:%s"\n' "$DEMO_PW" | curl -s -I -K - -H 'Accept: application/vnd.oci.image.manifest.v1+json' http://127.0.0.1:5000/v2/demo/manifests/manifests/live | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}')
[ "$live" = "$DIGEST" ] && ok "live moved to this run's artifact ($live)" || fail "live is $live, the run pushed $DIGEST"
run_step notify >/dev/null && ok "Receiver accepted the signed call" || fail "Receiver refused"
run_step wait >/dev/null && ok "wait: applied (live@$DIGEST) and Ready" || fail "wait failed on a good deploy"
# A new artifact Flux can't get healthy, then one that never converges: each fails the wait.
echo fail > "$W/mode"; SHA3=$(printf '%040d' 3); deploy "$SHA3" > "$W/deploy3.log" 2>&1 || { cat "$W/deploy3.log"; die "the third deploy failed"; }
run_step notify >/dev/null
if out_w=$(run_step wait 2>&1); then fail "wait passed although Flux reported a failure"; else
  grep -q "Flux couldn't apply" <<<"$out_w" && ok "wait fails when Flux reports a failure" || fail "wait failed for another reason: $out_w"; fi
echo never > "$W/mode"; SHA4=$(printf '%040d' 4); deploy "$SHA4" > "$W/deploy4.log" 2>&1 || { cat "$W/deploy4.log"; die "the fourth deploy failed"; }
run_step notify >/dev/null
if out_w=$(WAIT_SECONDS=6 run_step wait 2>&1); then fail "wait passed although nothing converged"; else
  grep -q "not applied and healthy after 6s" <<<"$out_w" && ok "wait fails when nothing converges in time" || fail "wait failed for another reason: $out_w"; fi
if VPS_RECEIVER_TOKEN=wrong run_step notify >/dev/null 2>&1; then fail "a wrong token was accepted"; else ok "the Receiver refuses a wrong token"; fi

info "refusals"
if APP=other run_step push >/dev/null 2>&1; then fail "demo's password pushed to other/"; else ok "demo's password can't push to another app's path"; fi
printf 'not encrypted\n' > "$APP_DIR/deploy/secrets/demo-env/PLAIN"
if (cd "$APP_DIR" && bash "$ROOT/vps/pack.sh" . "$W/rendered.yaml" "$W/plain-art") > "$W/plain.log" 2>&1; then fail "pack took a plaintext secret"
else grep -q "isn't a SOPS-encrypted file" "$W/plain.log" && ok "pack refuses a plaintext secret file" || fail "pack failed for another reason: $(cat "$W/plain.log")"; fi
rm "$APP_DIR/deploy/secrets/demo-env/PLAIN"
printf 'app: demo\ncomponents:\n  web: {build: {context: web}, uid: 101, memory: 64Mi, securityContext: {privileged: true}}\n' > "$W/bad.yaml"
if bash "$ROOT/vps/render.sh" "$W/bad.yaml" "$W/images.json" x "$W/bad.out" > "$W/bad.log" 2>&1; then fail "render took an unknown field"
else grep -q "additional properties 'securityContext' not allowed" "$W/bad.log" && ok "render refuses fields that aren't in the schema (no securityContext overrides)" || fail "render failed for another reason: $(tail -2 "$W/bad.log")"; fi

echo
if [ "$FAILED" -ne 0 ]; then echo "!! vps-deploy self-test FAILED"; exit 1; fi
echo "vps-deploy self-test: all checks passed"
