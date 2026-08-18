#!/usr/bin/env bash
# Sync wave 2. KServe v0.17 split the chart; kserve.charts in versions.yaml
# is the ordered install list for phase 1 Standard mode (kserve-crd, then
# kserve-resources) - see the comment there for the install guide this was
# checked against. The rest of the split lives under kserve.charts_available
# and is not installed here.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.kserve.version' versions.yaml)"

# Portable read loop, not `mapfile`/`readarray`: macOS ships bash 3.2 as
# /bin/bash, which has neither builtin, and this script has no reason to
# require bash 4+.
CHARTS=()
while IFS= read -r c; do CHARTS+=("$c"); done < <(yq -r '.kserve.charts[]' versions.yaml)
[ "${#CHARTS[@]}" -gt 0 ] || { echo "kserve.charts is empty in versions.yaml" >&2; exit 1; }

for chart in "${CHARTS[@]}"; do
  # Each entry is an OCI ref with a trailing ":$VERSION" tag, e.g.
  # oci://ghcr.io/kserve/charts/kserve-resources:v0.20.0. Strip the tag so
  # the ref and --version are not passed redundantly, and so the basename
  # gives the bare chart name instead of "kserve-resources:v0.20.0".
  ref="${chart%":${VERSION}"}"
  name="$(basename "$ref")"
  extra=()
  # kserve-resources is the chart that owns the controller Deployment and
  # the inferenceservice-config ConfigMap; it is the only one
  # values-kserve.yaml's keys (kserve.controller.*) apply to.
  [ "$name" = "kserve-resources" ] && extra=(-f platform/20-kserve/values-kserve.yaml)
  helm upgrade --install "$name" "$ref" \
    --namespace kserve --create-namespace \
    --version "$VERSION" "${extra[@]}" \
    --wait --timeout 10m
done

kubectl wait --for=condition=Established crd/inferenceservices.serving.kserve.io --timeout=120s
kubectl -n kserve rollout status deploy --timeout=5m
