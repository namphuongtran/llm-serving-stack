#!/usr/bin/env bash
# Gateway API CRDs. Installed BEFORE any gateway implementation, because
# implementations ship their own copies and conflict when they win the race.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.crds.gateway_api' versions.yaml)"
[ -n "$VERSION" ] && [ "$VERSION" != "null" ] || { echo "crds.gateway_api not pinned in versions.yaml" >&2; exit 1; }

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${VERSION}/standard-install.yaml"
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s
