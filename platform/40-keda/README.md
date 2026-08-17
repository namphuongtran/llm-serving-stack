# 40 KEDA

Sync wave 3.

Scales the predictor on queue depth, not on CPU. A GPU can be fully busy while
CPU looks idle, which makes CPU-based autoscaling wrong for this workload.

Uses the OpenTelemetry add-on so engine metrics can drive scaling decisions.
