#!/usr/bin/env bash
# Assembles the artifact Flux applies (pushed as registry.internal/<app>/manifests:<sha>):
#   vps/pack.sh <app repo dir> <rendered.yaml> <out dir>
#
#   <out>/manifests.yaml                 the chart's output
#   <out>/extra/*.yaml                   deploy/extra/*.yaml as they are (still bound by the tenant)
#   <out>/secrets/<secret>/<KEY>         deploy/secrets/<secret>/<KEY>: one SOPS file per value
#   <out>/kustomization.yaml             resources + one secretGenerator per secret directory
#
# kustomize-controller decrypts every Secret value that is itself a SOPS document, so the
# generated Secret <secret> carries the plain values in the cluster. A file that isn't SOPS-encrypted
# is refused: no plaintext secret ever lands in the registry.
set -euo pipefail
[ "$#" -eq 3 ] || { echo "usage: $0 <app repo dir> <rendered.yaml> <out dir>" >&2; exit 2; }
repo=$1; rendered=$2; out=$3
[ ! -e "$out" ] || { echo "pack: $out exists" >&2; exit 1; }
install -d "$out"
cp "$rendered" "$out/manifests.yaml"
res=("manifests.yaml")
if [ -d "$repo/deploy/extra" ]; then
  install -d "$out/extra"
  for f in "$repo"/deploy/extra/*.yaml; do
    [ -e "$f" ] || continue
    cp "$f" "$out/extra/"; res+=("extra/$(basename "$f")")
  done
fi
gen=""
if [ -d "$repo/deploy/secrets" ]; then
  for d in "$repo"/deploy/secrets/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    [[ "$s" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "pack: bad secret name '$s'" >&2; exit 1; }
    install -d "$out/secrets/$s"
    files=""
    for f in "$d"*; do
      [ -f "$f" ] || continue
      k=$(basename "$f")
      [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "pack: bad key name '$s/$k'" >&2; exit 1; }
      jq -e 'has("sops") and has("data")' "$f" >/dev/null 2>&1 || { echo "pack: $s/$k isn't a SOPS-encrypted file; refusing" >&2; exit 1; }
      cp "$f" "$out/secrets/$s/$k"
      files+="      - $k=secrets/$s/$k"$'\n'
    done
    [ -n "$files" ] || continue
    gen+="  - name: $s"$'\n'"    type: Opaque"$'\n'"    files:"$'\n'"$files"
  done
fi
{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  for r in "${res[@]}"; do echo "  - $r"; done
  if [ -n "$gen" ]; then echo "secretGenerator:"; printf '%s' "$gen"; fi
} > "$out/kustomization.yaml"
echo "packed: ${#res[@]} resource files, $(grep -c '^  - name:' "$out/kustomization.yaml" || true) secrets"
