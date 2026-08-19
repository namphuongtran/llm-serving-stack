setup() {
  load '../lib/helpers'
  PROM="http://127.0.0.1:9090"
}

teardown() {
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
  [ -n "${GF_PID:-}" ] && kill "$GF_PID" 2>/dev/null || true
  true
}

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

# Service name and port confirmed by rendering the pinned chart with this
# repository's own release name on 2026-08-19:
#   helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
#     --version 88.5.0 -n observability -f platform/30-observability/values-prometheus.yaml
# emits Service/kube-prometheus-stack-grafana on port 80. The admin password is
# `admin`, set in that same values file - this is a local kind cluster and the
# credential is already in git.
start_grafana_portforward() {
  kubectl --context "$KUBECTL_CONTEXT" -n observability \
    port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null 2>&1 &
  GF_PID=$!
  wait_for 60 "grafana port-forward" bash -c "curl -sf http://127.0.0.1:3000/api/health"
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

# Added 2026-08-19 with platform/30-observability/tempo.yaml.
@test "tempo is available" {
  run k get deploy -n observability tempo -o jsonpath='{.status.availableReplicas}'
  [ "$output" -ge 1 ]
}

# Asks Grafana, not the ConfigMap. A ConfigMap holding the right YAML proves
# the values file reached the cluster; it does not prove Grafana parsed it or
# that the datasource works. This also guards the duplication this repository
# accepts by necessity: the same additionalDataSources block is written twice,
# in platform/30-observability/values-prometheus.yaml and inline in
# clusters/local-kind/apps/30-observability.yaml, because an Argo CD
# Application cannot read a values file out of this repository. If the GitOps
# copy is edited and the other is not, this is what notices.
@test "grafana is configured with a tempo datasource" {
  start_grafana_portforward
  run bash -c "curl -sf -u admin:admin http://127.0.0.1:3000/api/datasources | jq -r '[.[] | select(.type == \"tempo\")] | length'"
  [ "$output" -ge 1 ]
}

# The trace path has no producer yet: llama.cpp emits no spans (ADR 0005), and
# gateway tracing is a separate change. So this asserts the pipeline is wired,
# not that traces flow - Tempo answering /ready through its own Service is what
# says the collector's exporter has somewhere to send to.
#
# > **Untried (2026-08-19):** that any span ever reaches Tempo. Nothing
# > produces one yet. When gateway tracing lands, the test to add here is a
# > TraceQL query returning at least one trace after tests/contract/ has run.
@test "tempo answers ready through its service, so the collector has a target" {
  run k -n observability run tempo-ready-probe --rm -i --restart=Never \
    --image=curlimages/curl:8.21.0@sha256:56bc0130aabaada5c04bb18d8d7f75e7a78fbcaa38ad44e1811c8c7720606d84 \
    --command -- curl -sf -o /dev/null -w '%{http_code}' http://tempo.observability.svc.cluster.local:3200/ready
  [ "$status" -eq 0 ]
  [[ "$output" == *200* ]]
}

# Added 2026-08-19 with the gateway tracing change. Three tests, in the order a
# span travels: is the mesh told where to send, is the gateway told to send, did
# anything arrive.

# Reads the rendered MeshConfig out of the cluster rather than the values file
# in git. This repository has been bitten twice by a values key that was set and
# never took effect, and both were found only by reading rendered output; see
# CLAUDE.md's evidence rules.
@test "the mesh is configured to export traces to the collector" {
  run k -n istio-system get cm istio -o jsonpath='{.data.mesh}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"otel-tracing"* ]]
  [[ "$output" == *"otel-collector.observability"* ]]
}

# The provider above is a destination. This is what makes the gateway use it.
@test "the gateway is told to produce traces" {
  run k -n istio-system get telemetry gateway-tracing -o jsonpath='{.spec.tracing[0].providers[0].name}'
  [ "$status" -eq 0 ]
  [ "$output" = "otel-tracing" ]
}

# The end of the pipeline, and the only test here that can prove it works.
# tempo_distributor_spans_received_total comes from Tempo's own /metrics, which
# platform/30-observability/podmonitor.yaml scrapes.
#
# This needs traffic to have passed the gateway. The CI observability job runs
# tests/contract/ before this suite for that reason.
#
# > **Untried (2026-08-19):** whether this passes. It is the assertion that
# > settles whether an Istio ambient gateway emits spans through this path at
# > all - see the Untried marker in platform/10-istio/telemetry.yaml. If it
# > fails while the two tests above pass, the wiring is right and the ambient
# > gateway is not producing, which is a finding to record rather than a test
# > to weaken.
@test "spans are reaching tempo" {
  start_prom_portforward
  run bash -c "curl -sf --get $PROM/api/v1/query --data-urlencode 'query=sum(tempo_distributor_spans_received_total) > 0' | jq -r '.data.result | length'"
  [ "$output" -ge 1 ]
}
