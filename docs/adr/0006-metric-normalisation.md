# ADR 0006: Metric normalisation into an `llmstack:` namespace

- Date: 2026-08-19
- Status: accepted, documentation-derived (not yet observed on a running engine)

## Context

Dashboards must not name an engine directly, because phase 2 adds a second
engine (vLLM) behind the same predictor contract, and a dashboard built around
`llamacpp_*` series would have to be rebuilt rather than extended. The fix is
a normalisation layer: Prometheus recording rules read each engine's own
series and publish an `llmstack:`-prefixed name every dashboard panel reads
instead.

**This ADR cannot record metric names read from a running engine.** No
cluster exists in phase 1 authoring (the human's machine cannot spare the
memory Docker needs - see the plan's Ruling 9), so there is no
`ornith-9b-predictor` pod to `wget http://127.0.0.1:8080/metrics` against. The
mapping table below is derived from the engine's own upstream documentation
instead, pinned to the exact commit the running image was built from, not
guessed and not carried over from a different llama.cpp version. The command
that will confirm it against a live endpoint is recorded at the end of this
document; it has not been run.

## Evidence: which commit, which document

The image pinned as `images.llamacpp_server` in `versions.yaml` is:

```
ghcr.io/ggml-org/llama.cpp@sha256:5be603b8cbf1ee9e078232ae5e1d02794e7540e210299b53bac04cbc6debc77b
```

Read on 2026-08-19 with:

```
$ docker buildx imagetools inspect --format '{{json .}}' \
    ghcr.io/ggml-org/llama.cpp@sha256:5be603b8cbf1ee9e078232ae5e1d02794e7540e210299b53bac04cbc6debc77b
```

The image's OCI labels give the exact source commit and build:

```
org.opencontainers.image.revision: 25ae3a9b331fffea50ff8d07a5cad34c33f1276f
org.opencontainers.image.version:  b10481
org.opencontainers.image.created:  2026-08-18T04:50:51Z
```

(the same `docker buildx imagetools inspect --format '{{json .}}'` output also
carries a `2026-08-18T04:59:40Z` timestamp, nine minutes later - that one is
the image config's own top-level `.created` field, a separate value from the
`org.opencontainers.image.created` OCI label above, and this ADR does not rely
on it for anything.)

The full metric list below is the `/metrics` section of `tools/server/README.md`
at that exact commit, fetched on 2026-08-19 from:

```
https://raw.githubusercontent.com/ggml-org/llama.cpp/25ae3a9b331fffea50ff8d07a5cad34c33f1276f/tools/server/README.md
```

(a second fetch against `master` on the same date returned an identical
metrics table, but the commit-pinned URL above is the one this ADR relies on,
because `master` can move and the pinned image cannot).

## Full metric list this engine exposes

| Metric | Type | Description (verbatim from the README) |
|---|---|---|
| `llamacpp:prompt_tokens_total` | Counter | Number of prompt tokens processed. |
| `llamacpp:prompt_seconds_total` | Counter | Prompt process time in seconds. |
| `llamacpp:prompt_tokens_seconds` | Gauge | Average prompt throughput in tokens/s. |
| `llamacpp:tokens_predicted_total` | Counter | Number of generation tokens processed. |
| `llamacpp:tokens_predicted_seconds_total` | Counter | Predict process time in seconds. |
| `llamacpp:predicted_tokens_seconds` | Gauge | Average generation throughput in tokens/s. |
| `llamacpp:requests_processing` | Gauge | Number of requests processing. |
| `llamacpp:requests_deferred` | Gauge | Number of requests deferred. |
| `llamacpp:n_tokens_max` | Counter | High watermark of the context size observed. |
| `llamacpp:n_decode_total` | Counter | Total Number of llama_decode() calls. |
| `llamacpp:n_busy_slots_per_decode` | Gauge | Average number of busy slots per llama_decode() call. |
| `llamacpp:spec_decode_num_draft_tokens_total` | Counter | Total draft tokens generated (0 when spec-decode is off). |
| `llamacpp:spec_decode_num_accepted_tokens_total` | Counter | Total draft tokens accepted by the target model (0 when spec-decode is off). |
| `llamacpp:spec_decode_num_drafts_total` | Counter | Total speculative decoding verification steps (0 when spec-decode is off). |
| `llamacpp:spec_decode_num_accepted_tokens_per_pos_total` | Counter | Accepted tokens per draft position (labeled `position="N"`; absent when spec-decode is off). |

That is the complete list; nothing here is invented, and nothing needed for
this task's mapping was missing from the documentation, so there is no
`Unmeasured` marker in this ADR for the mapping itself. There is one for the
live confirmation, at the end.

## Mapping to `llmstack:` names

| `llmstack:` name | Source expression | Notes |
|---|---|---|
| `llmstack:requests_running` | `sum(llamacpp:requests_processing) or vector(0)` | Direct gauge read. |
| `llmstack:requests_waiting` | `sum(llamacpp:requests_deferred) or vector(0)` | Direct gauge read; this is the queue-depth signal Task 9's `ScaledObject` scales on. |
| `llmstack:tokens_out_total` | `sum(llamacpp:tokens_predicted_total) or vector(0)` | Direct counter read; the dashboard wraps it in `rate(...)` for throughput. |
| `llmstack:ttft_seconds:p50` / `:p95` | `quantile_over_time(0.5\|0.95, llm_ttft_probe_seconds[15m])` | Not derived from any engine series - see below. |

## Panels this engine cannot fill, and why

| Spec panel | Status | Reason |
|---|---|---|
| Prefix cache hit rate | Not available | vLLM-specific; llama.cpp does not report prefix cache statistics as a metric. |
| KV cache utilisation | Not available | vLLM-specific; llama.cpp's `/metrics` has no KV-cache-block series (see ADR 0005: the KServe scheduler's cache-aware routing depends on ZMQ events vLLM emits and llama.cpp does not). |
| Time-to-first-token (p50/p95) | Filled, but not by the engine | llama.cpp exposes only the counters and gauges in the table above - no histogram or summary of any per-request latency exists to read. There is nothing for a `histogram_quantile` to consume. Filled instead by a client-side prober: `platform/30-observability/ttft-prober-cronjob.yaml` sends one streaming request per minute and measures the delay to the first response byte with curl's own `time_starttransfer`, publishing it as `llm_ttft_probe_seconds` to a Pushgateway. `quantile_over_time` turns the resulting series of single samples into a rolling p50/p95. The dashboard panel is titled to say so explicitly, because a synthetic number must never be mistaken for a served one. |
| Traces / spans | Not available in phase 1 at all | llama.cpp's server documentation has zero mentions of OTLP or OpenTelemetry (checked 2026-08-19). The OpenTelemetry Collector is still deployed (`otel-collector.yaml`) with a `traces` pipeline that has no producer in this phase; it exists so the GenAI attribute naming lives in one place ahead of phase 2, where vLLM does emit spans. |

## Why this ADR lets phase 2 add vLLM without re-deriving anything

Every row in the mapping table above is keyed by the `llmstack:` name, not by
the engine. Adding vLLM means adding a second source expression to each
existing recording rule (`sum(llamacpp:X) or sum(vllm:Y) or vector(0)`, the
pattern the recording rules file already comments), reading vLLM's own metric
names the same way this ADR read llama.cpp's - from vLLM's documentation,
pinned to whatever commit its own image resolves to. No dashboard panel
changes, because no panel names an engine.

## A correction to the section above, found by reading vLLM's own metric names

Added 2026-09-04, in the same spirit as the cost paragraph appended to
[ADR 0005](0005-two-runtimes-one-control-plane.md): the decision recorded here
is unchanged and still correct, and one sentence about what it would cost was
optimistic. The sentence stays, and this section says where it is wrong.

"Adding vLLM means adding a second source expression to each existing recording
rule" holds for three of the four capabilities that section implies. It does not
hold for prefix cache hit rate.

vLLM publishes **no** hit-rate metric. It publishes two counters, and the rate
has to be derived from them. Read from
`vllm/v1/metrics/loggers.py` on `main`, 2026-09-04:

| Needed | vLLM metric | Type | Line |
|---|---|---|---|
| KV cache utilisation | `vllm:kv_cache_usage_perc` | Gauge | 562 |
| Requests waiting | `vllm:num_requests_waiting` | Gauge | 504 |
| Time to first token | `vllm:time_to_first_token_seconds` | Histogram | 797 |
| Prefix cache hit rate | **does not exist** | | |
| ... hits | `vllm:prefix_cache_hits` | Counter | 596 |
| ... queries | `vllm:prefix_cache_queries` | Counter | 585 |

So `llmstack:prefix_cache_hit_rate` must be a **division of two counters**, not a
second `or` branch on an existing expression. It is the one rule in this file
whose shape changes when the second engine arrives.

**Two names that do not exist, and would fail silently.** `vllm:gpu_cache_usage_perc`
was removed; a grep for `gpu_cache_usage` in `loggers.py` returns nothing on
2026-09-04. And `hit_rate` appears in that file only as a Python attribute on a
log line, never as a metric `name=`. A recording rule written against either
name produces no series, and an empty panel is indistinguishable from a broken
one, which is the exact failure this ADR's dashboard note already warns about.

**One thing gets better, not worse.** The "Panels this engine cannot fill" table
says of time to first token that llama.cpp exposes "no histogram or summary of
any per-request latency" and that "There is nothing for a `histogram_quantile`
to consume". `vllm:time_to_first_token_seconds` is a histogram, so in phase 2
there is. The client-side prober stops being the only source, and
`llmstack:ttft_seconds:p50` / `:p95` can read the engine directly on the GPU
node.

> **Untried (2026-09-04):** none of these vLLM series has been scraped by this
> repository's Prometheus. The names above come from vLLM's source, not from a
> running endpoint. Confirm them the same way ADR 0006 requires for llama.cpp,
> by reading `/metrics` off a live predictor pod, before writing any rule.

## What must be confirmed against a live endpoint

> **Unmeasured (2026-08-19):** whether the `llamacpp:*` series above are
> actually present, unrenamed, and carrying the same units, on the running
> `ornith-9b-predictor` pod's `/metrics` endpoint. Run
> `kubectl -n llm exec "$(kubectl -n llm get pod -l serving.kserve.io/inferenceservice=ornith-9b -o name | head -1)" -c kserve-container -- wget -qO- http://127.0.0.1:8080/metrics | grep -E '^# (HELP|TYPE)' | sort`,
> once a cluster exists.
