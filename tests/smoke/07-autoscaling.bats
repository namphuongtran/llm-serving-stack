setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

@test "ScaledObject is Ready and never scales to zero" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get scaledobject ornith-9b -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'"
  [ "$output" = "True" ]
  run k -n llm get scaledobject ornith-9b -o jsonpath='{.spec.minReplicaCount}'
  [ "$output" -ge 1 ]
}

@test "sustained load scales the predictor beyond one replica" {
  token=$(get_token llm-tier-pro)
  for i in $(seq 1 12); do
    curl -s -o /dev/null "$BASE/v1/chat/completions" \
      -H "authorization: Bearer $token" -H 'content-type: application/json' \
      -d '{"model":"ornith-9b","messages":[{"role":"user","content":"Write four sentences about tides."}],"max_tokens":256}' &
  done
  run wait_for 300 "predictor to scale above one replica" bash -c \
    "[ \"\$(kubectl --context $KUBECTL_CONTEXT -n llm get deploy ornith-9b-predictor -o jsonpath='{.spec.replicas}')\" -gt 1 ]"
  wait
  [ "$status" -eq 0 ]
}
