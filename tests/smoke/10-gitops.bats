setup() {
  load '../lib/helpers'
  # Every assertion below is about cluster state, so a suite that cannot reach the
  # API server must fail rather than report anything. Added across the suites on
  # 2026-08-20: with Docker down, five files gave 4 passes and 22 failures, and
  # three of those four passes were bare `[ "$status" -ne 0 ]` assertions
  # satisfied by kubectl failing to connect. See require_cluster in ../lib/helpers.
  require_cluster
}

@test "every Argo CD application is Synced and Healthy" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{\"\\n\"}{end}'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -v '=Synced/Healthy$' | grep . && false || true
}

# PREDICTED TO FAIL. Found by reading on 2026-08-19; this suite has never run
# anywhere, so nobody has seen it either way.
#
# This test compares two counts: Applications carrying a sync-wave annotation,
# and all Applications in namespace argocd. All 15 files in
# clusters/local-kind/apps/ carry a wave - confirmed with
# `yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"'` over the
# directory. clusters/local-kind/root-app.yaml does not, and `task local:up`
# applies it into that same namespace as a sixteenth Application. So this is
# expected to compare 15 against 16 and fail.
#
# It is left as it is, on purpose. Two resolutions exist once someone can run
# it, and choosing between them is a real decision, not a formality. Either
# root-app gains a wave, which is harmless but meaningless because nothing
# orders root-app against anything. Or this test narrows to the Applications
# root-app manages. Do not pick one to make a red run go green.
#
# clusters/local-kind/check-sync-waves.sh covers a different thing without a
# cluster: the files in git, not the objects in a cluster. It is not a fix for
# this.
@test "sync waves are declared on every application" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.annotations.argocd\\.argoproj\\.io/sync-wave}{\"\\n\"}{end}' | grep -c ."
  count=$(kubectl --context "$KUBECTL_CONTEXT" -n argocd get applications.argoproj.io --no-headers | wc -l | tr -d ' ')
  [ "$output" -eq "$count" ]
}

@test "a rebuilt cluster reaches a working endpoint with no manual steps" {
  skip "run manually: task local:down && task local:up && bats tests/"
}
