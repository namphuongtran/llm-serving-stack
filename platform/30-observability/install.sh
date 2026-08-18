#!/usr/bin/env bash
# Sync wave 3. Metrics via Prometheus scrape, traces via OTLP. Two paths.
set -euo pipefail
cd "$(dirname "$0")/../.."

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observability --create-namespace \
  --version "$(yq -r '.charts.kube_prometheus_stack' versions.yaml)" \
  -f platform/30-observability/values-prometheus.yaml --wait --timeout 10m

helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace observability \
  --version "$(yq -r '.charts.otel_collector' versions.yaml)" \
  -f platform/30-observability/otel-collector.yaml --wait

# Pushgateway backs the TTFT prober below: a CronJob pod exits seconds after
# each measurement, so there is no long-lived target to scrape a gauge from
# directly.
helm upgrade --install pushgateway prometheus-community/prometheus-pushgateway \
  --namespace observability \
  --version "$(yq -r '.charts.prometheus_pushgateway' versions.yaml)" \
  -f platform/30-observability/pushgateway-values.yaml --wait

kubectl apply -f platform/30-observability/recording-rules.yaml
kubectl apply -f platform/30-observability/ttft-prober-cronjob.yaml

# Scrape the predictor. KServe pods expose the engine port directly.
kubectl apply -f - <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata: { name: llm-predictors, namespace: observability }
spec:
  namespaceSelector: { matchNames: [llm] }
  selector:
    matchExpressions: [{ key: serving.kserve.io/inferenceservice, operator: Exists }]
  podMetricsEndpoints: [{ port: http, path: /metrics, interval: 15s }]
YAML

kubectl -n observability create configmap llm-serving-dashboard \
  --from-file=platform/30-observability/dashboards/llm-serving.json \
  --dry-run=client -o yaml | \
  kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f -
