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

# The floor is 2, not 1: scaledobject.yaml sets minReplicaCount: 2 and
# patch-resources.yaml sets minReplicas: 2, both raised for HA (the PDB has
# minAvailable: 1 and KEDA must never scale below the floor that budget can
# protect). An assertion of "> 1" is therefore true at rest, before any load
# is applied, and would pass with KEDA uninstalled. "> 2" is the first
# replica count that can only come from scaling; maxReplicaCount is 3, so 3
# is the only value that satisfies it.
@test "sustained load scales the predictor above its floor of two replicas" {
  token=$(get_token llm-tier-pro)
  for i in $(seq 1 12); do
    curl -s -o /dev/null "$BASE/v1/chat/completions" \
      -H "authorization: Bearer $token" -H 'content-type: application/json' \
      -d '{"model":"ornith-9b","messages":[{"role":"user","content":"Write four sentences about tides."}],"max_tokens":256}' &
  done
  run wait_for 300 "predictor to scale above its floor of two replicas" bash -c \
    "[ \"\$(kubectl --context $KUBECTL_CONTEXT -n llm get deploy ornith-9b-predictor -o jsonpath='{.spec.replicas}')\" -gt 2 ]"
  wait
  [ "$status" -eq 0 ]
}
