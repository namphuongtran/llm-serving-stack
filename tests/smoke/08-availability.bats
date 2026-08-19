setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

# This assertion and the constraint that makes it true were reconciled on
# 2026-08-19: patch-resources.yaml's topologySpreadConstraint used
# whenUnsatisfiable: ScheduleAnyway, which permits both replicas on one node,
# so the test could fail with a correct manifest. The constraint is now
# DoNotSchedule. The assertion is deliberately left as-is rather than
# loosened - the two tests below it (the PDB budget, and the node drain) both
# assume genuine spread, so a version of this test that passes with both pods
# on one node would assert nothing.
@test "two replicas are spread across different nodes" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get pods \
    -l serving.kserve.io/inferenceservice=ornith-9b \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | sort -u | wc -l | tr -d ' '"
  [ "$output" -ge 2 ]
}

@test "a PodDisruptionBudget protects one replica" {
  # With minReplicas: 2 on the InferenceService and minAvailable: 1 on the
  # PDB, two healthy replicas means both are currently healthy and exactly
  # one of them may be disrupted at a time. Anything else - a missing
  # replica, a PDB with the wrong minAvailable - should fail this test for
  # a stated reason, not pass because ">= 0" is true of every valid integer.
  run k -n llm get pdb ornith-9b -o jsonpath='{.status.currentHealthy}'
  [ "$output" -eq 2 ]
  run k -n llm get pdb ornith-9b -o jsonpath='{.status.disruptionsAllowed}'
  [ "$output" -eq 1 ]
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
  skip "ADR 0007: cross-backend failover is withdrawn, not just unmeasured - weight:0 backendRefs are never selected by Envoy's retry (issue 5891), so phase 1 has no mechanism for this to prove"
  token=$(get_token llm-tier-pro)
  kubectl --context "$KUBECTL_CONTEXT" -n llm scale deploy/ornith-9b-predictor --replicas=0
  wait_for 120 "primary to have zero endpoints" bash -c \
    "[ \"\$(kubectl --context $KUBECTL_CONTEXT -n llm get deploy ornith-9b-predictor -o jsonpath='{.status.readyReplicas}')\" = '' ]"
  code=$(curl -s -o /dev/null -w '%{http_code}' http://llm.localtest.me/v1/models -H "authorization: Bearer $token")
  kubectl --context "$KUBECTL_CONTEXT" -n llm scale deploy/ornith-9b-predictor --replicas=2
  [ "$code" = "200" ]
}
