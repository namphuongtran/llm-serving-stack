#!/usr/bin/env bash
# Sync wave 1. Dev mode: state is in memory, so the realm comes from git.
#
# keycloak.yaml carries its image pinned by digest directly (Task 12 removed
# the IMAGE_PLACED_BY_INSTALL_SCRIPT placeholder this script used to sed in,
# because the GitOps path in clusters/local-kind/apps/15-keycloak.yaml never
# runs this script and would otherwise commit a literal placeholder). This
# script is the manual/legacy bootstrap; it still creates the realm ConfigMap
# itself, because it has no kustomize build step the way the GitOps
# Application's configMapGenerator does.
set -euo pipefail
cd "$(dirname "$0")/../.."
. platform/lib/apply.sh

kubectl -n llm create configmap keycloak-realm \
  --from-file=realm-export.json=platform/15-keycloak/realm-export.json \
  --dry-run=client -o yaml | kubectl apply -f -

apply_retry platform/15-keycloak/keycloak.yaml   # namespace llm is governed by Kyverno
apply_retry platform/15-keycloak/httproute.yaml
kubectl -n llm rollout status deploy/keycloak --timeout=5m
