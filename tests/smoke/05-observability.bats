setup() {
  load '../lib/helpers'
  PROM="http://127.0.0.1:9090"
}

teardown() { [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true; }

# The service name was confirmed by rendering the pinned kube-prometheus-stack
# chart (helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack
# --version 88.5.0 -n observability) on 2026-08-19: the chart's own Service is
# literally named kube-prometheus-stack-prometheus, which is also what
# platform/40-keda/../models/ornith-9b/overlays/local/scaledobject.yaml's
# Prometheus trigger targets.
start_prom_portforward() {
  kubectl --context "$KUBECTL_CONTEXT" -n observability \
    port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
  PF_PID=$!
  wait_for 60 "prometheus port-forward" bash -c "curl -sf $PROM/-/ready"
}

@test "prometheus is scraping the predictor" {
  start_prom_portforward
  run bash -c "curl -sf --get $PROM/api/v1/query --data-urlencode 'query=up{namespace=\"llm\"}' | jq -r '.data.result | length'"
  [ "$output" -ge 1 ]
}

# Only series whose recording rule ends in `or vector(0)` are asserted here.
# The four rules added on 2026-08-19 divide (llmstack:seconds_per_output_token)
# or read a gauge (llmstack:batch_occupancy, llmstack:context_tokens_max), and
# recording-rules.yaml deliberately gives those no `or vector(0)`, because an
# absent value must not be reported as a confident zero. So they are absent
# until real traffic has flowed, and asserting them here would make this test
# depend on load rather than on wiring.
@test "normalised llmstack series exist" {
  start_prom_portforward
  for series in llmstack:requests_running llmstack:tokens_out_total llmstack:tokens_in_total; do
    run bash -c "curl -sf --get $PROM/api/v1/query --data-urlencode \"query=$series\" | jq -r '.data.result | length'"
    [ "$output" -ge 1 ]
  done
}

# The recording rules deliberately fall back to `or vector(0)` (so KEDA never
# breaks on an empty result), which means the *normalised* query above always
# returns exactly one series whether or not the underlying engine metric
# still exists under that name - a rename would go undetected by that test
# alone. This test closes that gap by querying the raw, un-normalised
# `llamacpp:*` series directly, with no `or vector(0)` anywhere in the path:
# if any of these three names is ever renamed upstream, this fails loudly
# instead of the recording rule silently going to a permanent zero.
@test "raw engine series backing the normalisation still exist" {
  start_prom_portforward
  for series in llamacpp:requests_processing llamacpp:requests_deferred \
                llamacpp:tokens_predicted_total llamacpp:prompt_tokens_total \
                llamacpp:tokens_predicted_seconds_total \
                llamacpp:n_busy_slots_per_decode llamacpp:n_tokens_max; do
    run bash -c "curl -sf --get $PROM/api/v1/query --data-urlencode \"query=$series\" | jq -r '.data.result | length'"
    [ "$output" -ge 1 ]
  done
}

@test "dashboard is provisioned and reads only llmstack series" {
  run bash -c "grep -o 'llmstack:[a-z_]*' platform/30-observability/dashboards/llm-serving.json | sort -u | wc -l | tr -d ' '"
  [ "$output" -ge 3 ]
  run bash -c "grep -cE '\"expr\": \"(llamacpp|vllm):' platform/30-observability/dashboards/llm-serving.json || true"
  [ "$output" -eq 0 ]
}

@test "otel collector accepts OTLP" {
  run k get deploy -n observability otel-collector -o jsonpath='{.status.availableReplicas}'
  [ "$output" -ge 1 ]
}

# Added 2026-08-19 with the istio-gateway PodMonitor. This test exists because
# of the failure mode, not the feature: a PodMonitor whose selector or port
# does not match discovers no targets and reports no error, so every
# llmstack:gateway_* recording rule would go permanently silent and the
# dashboard panels would sit empty looking exactly like a quiet service.
#
# `up{namespace="istio-system"}` rather than a job name: the Prometheus
# Operator copies the pod's namespace onto every PodMonitor target, and this
# repository scrapes nothing else in that namespace, whereas the `job` label's
# value depends on pod labels this repository does not set.
@test "prometheus is scraping the istio gateway, not only the predictor" {
  start_prom_portforward
  run bash -c "curl -sf --get $PROM/api/v1/query --data-urlencode 'query=up{namespace=\"istio-system\"}' | jq -r '.data.result | length'"
  [ "$output" -ge 1 ]
}

# The same argument as "raw engine series backing the normalisation still
# exist" above, for the gateway side. Both names were read from Istio's own
# reference documentation on 2026-08-19
# (https://istio.io/latest/docs/reference/config/metrics/) rather than from a
# live endpoint, so this is the test that turns a rename upstream into a red
# run instead of three silent recording rules.
#
# istio_requests_total needs at least one request to have passed the gateway.
# The CI observability job runs tests/contract/ before this suite for exactly
# that reason.
@test "raw gateway series backing the normalisation still exist" {
  start_prom_portforward
  for series in istio_requests_total istio_request_duration_milliseconds_bucket; do
    run bash -c "curl -sf --get $PROM/api/v1/query --data-urlencode \"query=$series\" | jq -r '.data.result | length'"
    [ "$output" -ge 1 ]
  done
}
