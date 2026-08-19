#!/usr/bin/env bash
# The only component installed imperatively (`task local:up` runs this
# directly, not through an Application). Everything else in platform/ and
# models/ is one of its children: clusters/local-kind/root-app.yaml, applied
# right after this script, brings in every Application in
# clusters/local-kind/apps/.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.charts.argo_cd' versions.yaml)"
[ -n "$VERSION" ] && [ "$VERSION" != "null" ] || { echo "charts.argo_cd not pinned in versions.yaml" >&2; exit 1; }

# server.insecure: TLS terminates at the Istio gateway in front of Argo CD's
# own ingress in a real deployment; phase 1 never exposes the Argo CD UI
# through the gateway at all; this only lets `kubectl port-forward` reach the
# API server over plain HTTP for local inspection.
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "$VERSION" \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 10m

kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
