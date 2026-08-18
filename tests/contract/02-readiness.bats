setup() { load '../lib/helpers'; }

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
