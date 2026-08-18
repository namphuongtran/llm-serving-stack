setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

@test "GET /v1/models lists the served model by its friendly name" {
  run bash -c "curl -sf $BASE/v1/models | jq -r '.data[].id'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ornith-9b"* ]]
}

@test "POST /v1/chat/completions returns a non-empty message" {
  run bash -c "curl -sf $BASE/v1/chat/completions -H 'content-type: application/json' -d '{
      \"model\": \"ornith-9b\",
      \"messages\": [{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}],
      \"max_tokens\": 24
    }' | jq -r '.choices[0].message.content | length'"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "streaming returns more than one chunk and terminates with [DONE]" {
  run bash -c "curl -sfN $BASE/v1/chat/completions -H 'content-type: application/json' -d '{
      \"model\": \"ornith-9b\",
      \"messages\": [{\"role\":\"user\",\"content\":\"Count to five.\"}],
      \"max_tokens\": 48, \"stream\": true
    }'"
  [ "$status" -eq 0 ]
  # More than one chunk: the count of SSE "data: " lines.
  [ "$(echo "$output" | grep -c '^data: ')" -gt 1 ]
  # Terminates with [DONE]: a stream that hangs without ever sending the
  # terminator would otherwise pass on chunk count alone.
  [[ "$output" == *'data: [DONE]'* ]]
}

@test "response reports token usage, which the quota policy depends on" {
  run bash -c "curl -sf $BASE/v1/chat/completions -H 'content-type: application/json' -d '{
      \"model\": \"ornith-9b\",
      \"messages\": [{\"role\":\"user\",\"content\":\"hi\"}],
      \"max_tokens\": 8
    }' | jq -r '.usage.total_tokens'"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "/metrics exposes the minimum required series" {
  pod=$(kubectl --context "$KUBECTL_CONTEXT" -n llm get pod \
        -l serving.kserve.io/inferenceservice=ornith-9b -o name | head -1)
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm exec ${pod} -c kserve-container -- \
      wget -qO- http://127.0.0.1:8080/metrics | grep -cE 'requests|tokens'"
  [ "$output" -gt 0 ]
}
