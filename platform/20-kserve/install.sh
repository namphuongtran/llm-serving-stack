#!/usr/bin/env bash
# Sync wave 2. KServe v0.17 split the chart; the exact chart references are
# pinned in versions.yaml under kserve.charts.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.kserve.version' versions.yaml)"
mapfile -t CHARTS < <(yq -r '.kserve.charts[]' versions.yaml)
[ "${#CHARTS[@]}" -gt 0 ] || { echo "kserve.charts is empty in versions.yaml" >&2; exit 1; }

for chart in "${CHARTS[@]}"; do
  # Each entry is an OCI ref with a trailing ":$VERSION" tag, e.g.
  # oci://ghcr.io/kserve/charts/kserve-resources:v0.20.0 - strip the tag
  # before taking the basename, otherwise name would be "kserve-resources:v0.20.0".
  ref="$chart"
  name="$(basename "${ref%":${VERSION}"}")"
  extra=()
  # kserve-resources is the one chart (of the ten) that owns the controller
  # Deployment and the inferenceservice-config ConfigMap; it is the only one
  # values-kserve.yaml's keys (kserve.controller.*) apply to.
  [ "$name" = "kserve-resources" ] && extra=(-f platform/20-kserve/values-kserve.yaml)
  helm upgrade --install "$name" "$ref" \
    --namespace kserve --create-namespace \
    --version "$VERSION" "${extra[@]}" \
    --wait --timeout 10m
done

kubectl wait --for=condition=Established crd/inferenceservices.serving.kserve.io --timeout=120s
kubectl -n kserve rollout status deploy --timeout=5m
