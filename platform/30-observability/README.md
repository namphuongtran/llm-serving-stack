# 30 Observability

Sync wave 3.

Prometheus scrapes `/metrics`. The OpenTelemetry Collector receives traces over
OTLP. Grafana reads only normalised metric names, never engine-specific ones.

The recording rules that do the normalisation live here. They are the reason one
dashboard works for both llama.cpp and vLLM.

llama.cpp has no time-to-first-token metric at all, so `ttft-prober-cronjob.yaml`
measures it client-side, once a minute, and pushes it to `pushgateway-values.yaml`'s
Pushgateway (a CronJob pod exits before Prometheus could ever scrape it directly).
The dashboard panel built from that number says so in its own title. See
`docs/adr/0006-metric-normalisation.md`.
