#!/usr/bin/env bash
# Sync wave 2. Chosen over Envoy AI Gateway, which requires Envoy Gateway as
# its base. See docs/adr/0004-policy-layer-kuadrant.md.
set -euo pipefail
cd "$(dirname "$0")/../.."

CHART="$(yq -r '.kuadrant.operator_chart' versions.yaml)"
CHART_VERSION="$(yq -r '.kuadrant.operator_chart_version' versions.yaml)"

# --version is not optional below. Without it, helm silently installs
# whatever chart version is newest, which loses the pin without producing an
# error. versions.yaml keeps operator_chart and operator_chart_version as two
# separate keys (it is a classic repo reference, not an OCI "name:version"
# one), so both must be checked here rather than one combined string.
if [ -z "$CHART" ] || [ "$CHART" = "null" ]; then
  echo "kuadrant.operator_chart not pinned in versions.yaml" >&2
  exit 1
fi
if [ -z "$CHART_VERSION" ] || [ "$CHART_VERSION" = "null" ]; then
  echo "kuadrant.operator_chart_version not pinned in versions.yaml" >&2
  exit 1
fi

helm upgrade --install kuadrant-operator "$CHART" --version "$CHART_VERSION" \
  --namespace kuadrant-system --create-namespace --wait --timeout 10m

# The Kuadrant CR turns the operator on and deploys Authorino and Limitador.
# apiVersion confirmed against the installed CRD, not carried over from
# memory: `helm template` of kuadrant/kuadrant-operator --version 1.5.2 (the
# version pinned above) on 2026-08-19 renders the kuadrants.kuadrant.io CRD
# with exactly one served+storage version, v1beta1. `spec: {}` is valid: the
# same CRD's schema has no required fields under spec.
kubectl apply -f - <<'YAML'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata: { name: kuadrant, namespace: kuadrant-system }
spec: {}
YAML

kubectl wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=5m
