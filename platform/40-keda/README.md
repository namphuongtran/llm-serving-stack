# 40 KEDA

Sync wave 3.

Scales the predictor on queue depth, not on CPU. A GPU can be fully busy while
CPU looks idle, which makes CPU-based autoscaling wrong for this workload.

Uses KEDA's built-in `prometheus` trigger, not the OpenTelemetry add-on: there
is no OTLP metrics producer in this stack (see
`docs/adr/0006-metric-normalisation.md` - llama.cpp emits no OTLP of any
kind), so the trigger reads `llmstack:requests_waiting` straight out of the
Prometheus that Task 7 already deploys. The `ScaledObject` lives with the
model it scales, in `models/ornith-9b/overlays/local/scaledobject.yaml`, not
here; this directory installs the operator.
