setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

@test "two replicas are spread across different nodes" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get pods \
    -l serving.kserve.io/inferenceservice=ornith-9b \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | sort -u | wc -l | tr -d ' '"
  [ "$output" -ge 2 ]
}

@test "a PodDisruptionBudget protects one replica" {
  run k -n llm get pdb ornith-9b -o jsonpath='{.status.currentHealthy}'
  [ "$output" -ge 1 ]
  run k -n llm get pdb ornith-9b -o jsonpath='{.status.disruptionsAllowed}'
  [ "$output" -ge 0 ]
}

@test "a streaming response survives a rolling restart" {
  token=$(get_token llm-tier-pro)
  ( curl -sfN "$BASE/v1/chat/completions" \
      -H "authorization: Bearer $token" -H 'content-type: application/json' \
      -d '{"model":"ornith-9b","messages":[{"role":"user","content":"Count slowly to twenty."}],"max_tokens":400,"stream":true}' \
      > /tmp/stream.out ) &
  stream_pid=$!
  sleep 3
  kubectl --context "$KUBECTL_CONTEXT" -n llm rollout restart deploy/ornith-9b-predictor
  wait "$stream_pid"
  run bash -c "grep -c '^data: ' /tmp/stream.out"
  [ "$output" -gt 1 ]
  run bash -c "grep -c 'DONE' /tmp/stream.out"
  [ "$output" -ge 1 ]
}

@test "draining a node keeps the endpoint answering" {
  token=$(get_token llm-tier-pro)
  node=$(kubectl --context "$KUBECTL_CONTEXT" -n llm get pods \
    -l serving.kserve.io/inferenceservice=ornith-9b \
    -o jsonpath='{.items[0].spec.nodeName}')
  kubectl --context "$KUBECTL_CONTEXT" drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/models" -H "authorization: Bearer $token")
  kubectl --context "$KUBECTL_CONTEXT" uncordon "$node"
  [ "$code" = "200" ]
}

@test "the endpoint still answers when the primary has no replicas" {
  token=$(get_token llm-tier-pro)
  kubectl --context "$KUBECTL_CONTEXT" -n llm scale deploy/ornith-9b-predictor --replicas=0
  wait_for 120 "primary to have zero endpoints" bash -c \
    "[ \"\$(kubectl --context $KUBECTL_CONTEXT -n llm get deploy ornith-9b-predictor -o jsonpath='{.status.readyReplicas}')\" = '' ]"
  code=$(curl -s -o /dev/null -w '%{http_code}' http://llm.localtest.me/v1/models -H "authorization: Bearer $token")
  kubectl --context "$KUBECTL_CONTEXT" -n llm scale deploy/ornith-9b-predictor --replicas=2
  [ "$code" = "200" ]
}
