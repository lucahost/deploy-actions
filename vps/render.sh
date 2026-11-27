#!/usr/bin/env bash
# Renders an app's vps.yaml with this repo's chart (vps/chart) into plain manifests.
#   vps/render.sh <vps.yaml> <images.json> <revision> <out.yaml>
# images.json maps each built image ("<component>", "<component>-migrate") to its digest-pinned
# reference, registry.internal/<app>/<image>:<sha>@sha256:<digest>. The chart's values.schema.json
# rejects unknown fields; helm template refuses a values file that doesn't validate.
set -euo pipefail
[ "$#" -eq 4 ] || { echo "usage: $0 <vps.yaml> <images.json> <revision> <out.yaml>" >&2; exit 2; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
helm=${HELM:-helm}
images=$(jq -c . "$2")
"$helm" template vps-app "$here/chart" -f "$1" --set-json "images=$images" --set-string "revision=$3" > "$4"
# The rendered objects as JSON: yq where it is (the CI runners), else python3's PyYAML (the VPS has
# python3-yaml and no yq). YQ names another yq; the self-test points it at none for the fallback.
docs_json() {
  if command -v "${YQ:-yq}" >/dev/null 2>&1; then "${YQ:-yq}" -o=json '.' "$1"
  else python3 -I -c 'import json, sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])): print(json.dumps(d))' "$1"; fi
}
# A request above its limit (memoryRequest > memory) renders, but Kubernetes refuses the pod.
over=$(docs_json "$4" | jq -s -r -f "$here/requests-fit-limits.jq") \
  || { echo "render: couldn't read $4 back (yq, or python3 with PyYAML: apt install python3-yaml)" >&2; exit 1; }
[ -z "$over" ] || { printf '%s\n' "$over" >&2; echo "render: a request is above its limit (vps.yaml memoryRequest ≤ memory)" >&2; exit 1; }
echo "rendered $(grep -c '^kind:' "$4") objects from $1"
