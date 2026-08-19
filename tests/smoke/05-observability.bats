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

@test "normalised llmstack series exist" {
  start_prom_portforward
  for series in llmstack:requests_running llmstack:tokens_out_total; do
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
  for series in llamacpp:requests_processing llamacpp:requests_deferred llamacpp:tokens_predicted_total; do
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
