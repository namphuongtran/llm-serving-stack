#!/usr/bin/env bash
# Every Argo CD Application in apps/ must declare a sync wave. Delivery is
# ordered by wave (CLAUDE.md, boundary 4), so an Application without one syncs
# at wave 0 and can reach the cluster before the layer it depends on.
#
# This runs with no cluster, which is the point. tests/smoke/10-gitops.bats
# asserts the same property against live Application objects, and that suite
# has never run anywhere. This check covers the files in git today.
#
# Deliberately scoped to apps/ and NOT to ../root-app.yaml. root-app is the
# one Application applied by hand by `task local:up`; nothing orders it
# against anything, so it carries no wave. See docs/UNVERIFIED.md for the
# consequence: tests/smoke/10-gitops.bats counts every Application in the
# cluster, root-app included, and is predicted to fail on that difference the
# first time it runs.
set -euo pipefail
cd "$(dirname "$0")"

missing=""
for a in apps/*.yaml; do
  kind="$(yq -r '.kind // ""' "$a")"
  [ "$kind" = "Application" ] || continue
  wave="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave" // ""' "$a")"
  [ -n "$wave" ] || missing="$missing $a"
done

if [ -n "$missing" ]; then
  printf 'sync-wave missing on -%s\n' "$missing" >&2
  exit 1
fi

count="$(ls apps/*.yaml | wc -l | tr -d ' ')"
printf 'sync-waves ok (%s applications)\n' "$count"
