setup() {
  load '../lib/helpers'
  # Every assertion below is about cluster state, so a suite that cannot reach the
  # API server must fail rather than report anything. Added across the suites on
  # 2026-08-20: with Docker down, five files gave 4 passes and 22 failures, and
  # three of those four passes were bare `[ "$status" -ne 0 ]` assertions
  # satisfied by kubectl failing to connect. See require_cluster in ../lib/helpers.
  require_cluster
}

@test "readiness is false while weights are still loading" {
  # Recreate the predictor and observe that it does not report ready immediately.
  kubectl --context "$KUBECTL_CONTEXT" -n llm delete pod \
    -l serving.kserve.io/inferenceservice=ornith-9b --wait=false
  sleep 5
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get pod \
      -l serving.kserve.io/inferenceservice=ornith-9b \
      -o jsonpath='{.items[0].status.containerStatuses[?(@.name==\"kserve-container\")].ready}'"
  [ "$output" != "true" ]
}

@test "readiness becomes true and the model answers" {
  run wait_for 900 "predictor to become ready after reload" bash -c \
    "kubectl --context $KUBECTL_CONTEXT -n llm get inferenceservice ornith-9b \
      -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
  [ "$status" -eq 0 ]
  run bash -c "curl -sf http://llm.localtest.me/v1/models | jq -e '.data | length > 0'"
  [ "$status" -eq 0 ]
}
