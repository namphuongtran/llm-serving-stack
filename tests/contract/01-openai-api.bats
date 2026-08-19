setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
  TOKEN="$(get_token llm-tier-pro)"
  AUTH="authorization: Bearer $TOKEN"
}

@test "GET /v1/models lists the served model by its friendly name" {
  run bash -c "curl -sf $BASE/v1/models -H \"$AUTH\" | jq -r '.data[].id'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ornith-9b"* ]]
}

@test "POST /v1/chat/completions returns a non-empty message" {
  run bash -c "curl -sf $BASE/v1/chat/completions -H \"$AUTH\" -H 'content-type: application/json' -d '{
      \"model\": \"ornith-9b\",
      \"messages\": [{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}],
      \"max_tokens\": 24
    }' | jq -r '.choices[0].message.content | length'"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "streaming returns more than one chunk and terminates with [DONE]" {
  run bash -c "curl -sfN $BASE/v1/chat/completions -H \"$AUTH\" -H 'content-type: application/json' -d '{
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
  run bash -c "curl -sf $BASE/v1/chat/completions -H \"$AUTH\" -H 'content-type: application/json' -d '{
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
  [ -n "$pod" ] || fail "no predictor pod matched the inferenceservice label"

  # curl, not wget. The pinned engine image has no wget: llama.cpp's
  # .devops/cpu.Dockerfile at tag b10481 builds `FROM base AS server`, and the
  # base stage installs exactly `libgomp1 curl ffmpeg` on ubuntu:24.04. The
  # image's own HEALTHCHECK is `curl -f http://localhost:8080/health`.
  #
  # The old `wget` call did not fail usefully. kubectl's "executable file not
  # found" text landed in $output, and the integer test below then reported
  # `integer expression expected` - a malformed integer, not a missing binary.
  # This test runs first in both CI cluster jobs, so that was the first red
  # line anyone would have seen. Found by reading the Dockerfile at the pinned
  # tag, 2026-08-19.
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm exec ${pod} -c kserve-container -- \
      curl -sS http://127.0.0.1:8080/metrics"
  [ "$status" -eq 0 ] || fail "could not read /metrics from ${pod}: $output"

  # Name the series, do not count matches of a loose pattern. `grep -cE
  # 'requests|tokens'` matched `# HELP` and `# TYPE` comment lines too, so any
  # engine exposing any Prometheus output passed a test called "the minimum
  # required series". These three are the ones
  # platform/30-observability/recording-rules.yaml actually consumes, so they
  # are the real contract.
  for series in llamacpp:requests_deferred \
                llamacpp:tokens_predicted_total \
                llamacpp:prompt_tokens_total; do
    printf '%s\n' "$output" | grep -q "^${series}" \
      || fail "missing required series ${series} in /metrics"
  done
}
