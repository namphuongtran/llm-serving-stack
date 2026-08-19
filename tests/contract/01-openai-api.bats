setup() {
  load '../lib/helpers'
  # Cluster-state assertions below, so a suite that cannot reach the API server
  # must fail rather than report anything. Added 2026-08-20: with Docker down,
  # bare `[ "$status" -ne 0 ]` assertions passed for the wrong reason. See
  # require_cluster in ../lib/helpers.
  require_cluster
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
  # required series".
  #
  # DERIVED, not hardcoded, and that matters here more than anywhere else in the
  # repository. This is tests/contract/, whose whole job per CLAUDE.md boundary 2
  # is to keep everything above the engine engine-INDEPENDENT. Two earlier
  # versions of this block failed that on their own terms: the first listed three
  # `llamacpp:` names and claimed they were "the ones recording-rules.yaml
  # actually consumes" (it consumes seven), and the second listed all seven -
  # which fixed the count and made the engine-independence problem worse, because
  # a vLLM predictor emitting `vllm:*` would then fail a test that is not about
  # vLLM.
  #
  # The list is now read out of platform/30-observability/recording-rules.yaml at
  # run time: every `<prefix>:<name>` series it references that is not already
  # normalised into the `llmstack:` namespace is, by definition, a raw engine
  # series the rules depend on. Swap the engine and its own rules supply their own
  # names, with no edit here. Returns seven today, all `llamacpp:`.
  #
  # This asserts them at the ENGINE. tests/smoke/05-observability.bats asserts the
  # same set through Prometheus, which cannot tell "the engine renamed a series"
  # from "the scrape broke".
  required="$(grep -oE '[a-z_]+:[a-z_]+' platform/30-observability/recording-rules.yaml \
              | grep -v '^llmstack:' | sort -u)"
  [ -n "$required" ] || fail "derived no engine series from recording-rules.yaml; the pattern or the file changed"

  # `[ {]` after the name so a prefix cannot match a longer series:
  # llamacpp:requests_deferred must not be satisfied by a hypothetical
  # llamacpp:requests_deferred_total.
  #
  # > **Untried (2026-08-20):** that all seven appear in this engine's /metrics.
  # > Three were read off a live pod on 2026-08-19; the other four come from the
  # > recording rules and have never been read out of the engine. If one is absent
  # > this fails and names it, which is the outcome to want.
  for series in $required; do
    printf '%s\n' "$output" | grep -qE "^${series}[ {]" \
      || fail "missing required series ${series} in /metrics"
  done
}
