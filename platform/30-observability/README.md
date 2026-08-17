# 30 Observability

Sync wave 3.

Prometheus scrapes `/metrics`. The OpenTelemetry Collector receives traces over
OTLP. Grafana reads only normalised metric names, never engine-specific ones.

The recording rules that do the normalisation live here. They are the reason one
dashboard works for both llama.cpp and vLLM.
