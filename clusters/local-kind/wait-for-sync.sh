#!/usr/bin/env bash
# The last command of `task local:up`, and the one that decides whether the
# pull-based delivery path worked.
#
# WHY THIS IS A SCRIPT AND NOT THE ONE-LINE `kubectl wait` IT REPLACED
#
# The line it replaced was, in Taskfile.yml until 2026-08-20:
#   kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
#     applications.argoproj.io --all --timeout=30m
#
# On 2026-08-20, the first time anything in `task local:up` past its second
# command was ever exercised, that line exited 0 in ONE SECOND against a
# cluster where the pull path had deployed nothing whatsoever. Read from the
# live cluster at that moment:
#   NAME       SYNC STATUS   HEALTH STATUS
#   root-app   Unknown       Healthy
# and root-app's only status condition was
#   type: ComparisonError
#   message: "Failed to load target state: failed to generate manifest for
#             source 1 of 1: rpc error: code = Unknown desc =
#             clusters/local-kind/apps: app path does not exist"
#
# An Argo CD Application that never managed to compare anything reports
# `health.status: Healthy`. It has no resource to call unhealthy, so it calls
# itself healthy. The old wait read that one field, which is the one field
# that cannot fail. Zero child Applications existed and `task local:up` would
# have reported success.
#
# So this script asserts the three things the old line did not.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Sourced for k() and KUBECTL_CONTEXT. bench/recovery-drill.sh:26 carries the
# reasoning: a bare `kubectl` here would run against whatever context happens
# to be current, and on this machine that has been `docker-desktop`.
# shellcheck source=tests/lib/helpers.bash
source tests/lib/helpers.bash
require_cluster

TIMEOUT="${1:-30m}"

# 1. root-app must be SYNCED, not merely Healthy.
#
# Synced is the field that discriminates. Probed against the live cluster on
# 2026-08-20 while root-app carried the ComparisonError above:
#   --for=jsonpath='{.status.sync.status}'=Synced
#     -> error: timed out waiting for the condition on applications/root-app
#   --for=jsonpath='{.status.health.status}'=Healthy
#     -> application.argoproj.io/root-app condition met
# One of those two reported the truth.
printf 'waiting for root-app to sync (timeout %s)\n' "$TIMEOUT"
k -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/root-app --timeout="$TIMEOUT" || {
  printf '\nroot-app did not sync. Its conditions say why -\n' >&2
  k -n argocd get application root-app \
    -o jsonpath='{range .status.conditions[*]}{.type}{" - "}{.message}{"\n"}{end}' >&2
  exit 1
}

# 2. The children must NUMBER what the directory holds.
#
# root-app syncing only proves Argo CD read the path. It does not prove the
# path held what this repository thinks it holds: `directory.recurse: false`,
# a renamed file, or a manifest whose kind is not Application would all leave
# root-app Synced over a smaller set. Counting from disk is what makes step 3
# below impossible to satisfy vacuously - a wait over 1 object and a wait over
# 16 both print "condition met".
want=$(( $(grep -h '^kind: Application' clusters/local-kind/apps/*.yaml | wc -l) + 1 ))
got=$(k -n argocd get applications.argoproj.io --no-headers | wc -l)
[ "$got" -eq "$want" ] || {
  printf 'expected %s Applications (%s in clusters/local-kind/apps/ plus root-app), found %s\n' \
    "$want" "$((want - 1))" "$got" >&2
  k -n argocd get applications.argoproj.io >&2
  exit 1
}
printf 'root-app synced and created all %s child Applications\n' "$((want - 1))"

# 3. Every Application must be Synced AND Healthy.
#
# `--all` is safe against an empty set here - probed 2026-08-20, zero matching
# objects gives `error: no matching resources found`, exit 1 - but step 2 is
# what makes it safe against a SUBSET, which is the failure that would
# actually happen.
#
# Sync first, then health, and in that order on purpose. A child that has not
# synced yet has no deployed resource to be unhealthy about, so it would pass
# a health check for the same reason root-app did.
k -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  applications.argoproj.io --all --timeout="$TIMEOUT"
k -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  applications.argoproj.io --all --timeout="$TIMEOUT"

k -n argocd get applications.argoproj.io
