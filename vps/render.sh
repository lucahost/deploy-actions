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
# A request above its limit (memoryRequest > memory) renders, but Kubernetes refuses the pod.
over=$(yq -o=json '.' "$4" | jq -s -r -f "$here/requests-fit-limits.jq")
[ -z "$over" ] || { printf '%s\n' "$over" >&2; echo "render: a request is above its limit (vps.yaml memoryRequest ≤ memory)" >&2; exit 1; }
echo "rendered $(grep -c '^kind:' "$4") objects from $1"
