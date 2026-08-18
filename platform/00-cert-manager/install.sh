#!/usr/bin/env bash
# Sync wave 0. Required by KServe for webhook certificates, in every
# deployment mode (KServe install dependencies, read 2026-08-17).
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.charts.cert_manager' versions.yaml)"
[ -n "$VERSION" ] && [ "$VERSION" != "null" ] || { echo "charts.cert_manager not pinned in versions.yaml" >&2; exit 1; }

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "$VERSION" \
  --set crds.enabled=true \
  --wait --timeout 5m

kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=3m
