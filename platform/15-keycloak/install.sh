#!/usr/bin/env bash
# Sync wave 1. Dev mode: state is in memory, so the realm comes from git.
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE="$(yq -r '.images.keycloak' versions.yaml)"
[ -n "$IMAGE" ] && [ "$IMAGE" != "null" ] || { echo "images.keycloak not pinned" >&2; exit 1; }
case "$IMAGE" in *@sha256:*) ;; *) echo "images.keycloak must be pinned by digest" >&2; exit 1;; esac

kubectl -n llm create configmap keycloak-realm \
  --from-file=realm-export.json=platform/15-keycloak/realm-export.json \
  --dry-run=client -o yaml | kubectl apply -f -

sed -e "s|IMAGE_PLACED_BY_INSTALL_SCRIPT|${IMAGE}|" \
    platform/15-keycloak/keycloak.yaml \
  | yq 'select(.kind != "ConfigMap")' \
  | kubectl apply -f -

kubectl apply -f platform/15-keycloak/httproute.yaml
kubectl -n llm rollout status deploy/keycloak --timeout=5m
