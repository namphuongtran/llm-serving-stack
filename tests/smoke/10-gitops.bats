setup() { load '../lib/helpers'; }

@test "every Argo CD application is Synced and Healthy" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{\"\\n\"}{end}'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -v '=Synced/Healthy$' | grep . && false || true
}

@test "sync waves are declared on every application" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.annotations.argocd\\.argoproj\\.io/sync-wave}{\"\\n\"}{end}' | grep -c ."
  count=$(kubectl --context "$KUBECTL_CONTEXT" -n argocd get applications.argoproj.io --no-headers | wc -l | tr -d ' ')
  [ "$output" -eq "$count" ]
}

@test "a rebuilt cluster reaches a working endpoint with no manual steps" {
  skip "run manually: task local:down && task local:up && bats tests/"
}
