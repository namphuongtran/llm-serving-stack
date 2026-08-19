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

Pushgateway serves the last value it was ever given, forever, so a dead
prober would otherwise look identical to a healthy one. `recording-rules.yaml`
alerts on `push_time_seconds` (a meta-metric Pushgateway itself adds per
pushed job) going stale, and the dashboard has its own freshness stat panel
next to the TTFT panel so a frozen number is visible even without the alert.

## What is measured, and where each signal comes from

Extended 2026-08-19. Before that, three engine series were normalised and
twelve of the fifteen llama.cpp exposes were unused, and the gateway's own
metrics were produced on every request and discarded.

| Question | Series | Source |
|---|---|---|
| When does the answer start? | `llmstack:ttft_seconds:p50` / `:p95` | Client-side prober, not the engine |
| How fast is it written after that? | `llmstack:seconds_per_output_token` | Engine |
| Are we saturating? | `llmstack:requests_waiting`, `llmstack:requests_running` | Engine |
| Is batching working? | `llmstack:batch_occupancy` | Engine |
| Prefill against decode | `llmstack:tokens_in_total`, `llmstack:tokens_out_total` | Engine |
| How close to the context limit? | `llmstack:context_tokens_max` | Engine |
| Is anything failing? | `llmstack:gateway_requests:rate5m`, `llmstack:gateway_error_ratio:rate5m` | Gateway |
| Whole-request latency at the edge | `llmstack:gateway_request_seconds:p95` | Gateway |

The split matters. llama.cpp reports no HTTP status code and no request
latency, so error rate can only come from the Envoy in front of it. It also
reports no KV cache series, so `llmstack:context_tokens_max` is a substitute
and not the real thing: it is a high-watermark that never falls, so it answers
"how close has traffic come to the limit", never "how full is the cache now".

`docs/adr/0006-metric-normalisation.md` holds the full engine metric list and
the table of panels this engine cannot fill. That ADR is not edited here -
ADRs are append-only, and its "cannot fill" table was true when written and is
still true. What changed is which of the *available* series this layer reads.

## Two signals still missing on purpose

- **Prefix cache hit rate and KV cache utilisation.** vLLM only. Phase 2.
- **Logs.** Nothing persists them. `kubectl logs` is the whole history, and it
  ends at the previous pod. That is what a log backend would fix, and it is not
  built here.
