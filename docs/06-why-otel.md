# Why TTFT and queue depth

## The question this answers

Why are CPU usage and average latency the wrong signals for this workload?

## Answer

A request queued behind a full batch does not raise CPU usage: the CPU (or,
in production, the GPU) computing the batch already in flight can sit at or
near 100% while a second request waits its entire turn with no CPU signal
telling anyone it is waiting. `requests_deferred` (normalised here to
`llmstack:requests_waiting`) is llama.cpp's own count of exactly that queue,
read directly off the engine rather than inferred from a resource
utilisation proxy that cannot distinguish "busy and keeping up" from "busy
and falling behind."

Average latency has the same blind spot from the other direction: one slow
request buried among many fast ones moves an average very little, while the
user who sent that one request experienced the full delay. `llmstack:ttft_seconds:p95`
is what would surface that user's experience even if hundreds of other
requests were fast; an average would not.

Autoscaling on CPU (the alternative that was rejected) inherits the first
problem directly: a `ScaledObject` reading CPU would not scale up while the
engine is saturated-but-not-CPU-bound, and would only react once the symptom
finally reached the resource it is watching, usually the same moment users have
already noticed. Scaling on `llmstack:requests_waiting:by_model` reacts to the
queue itself, before it shows up anywhere else.

## The queue signal, measured

**Measured 2026-08-20.** The stack had never been under sustained load. Sixty-four
streaming requests at concurrency 8, over about 7 minutes. The engine holds 2
slots per replica (`runtimes/llamacpp-arm64/servingruntime.yaml:52`,
`--parallel 2`) and there were 2 replicas, so 4 requests in flight and 4
deferred, against a `ScaledObject` threshold of 2.

Queue depth reached **5**. The HPA read `1667m/2 (avg)`, and KEDA set
`spec.replicas: 3` (`docs/STATUS.md`, "The first load test", finding 1).

That is the argument above, working. The queue rose, the recording rule
published it, KEDA read it, and the autoscaler acted. Nothing about CPU was
involved.

**And the outcome was still useless, for a reason in a different layer.** The
third pod never ran:

```
0/3 nodes are available: 1 node(s) had untolerated taint(s),
2 node(s) didn't match pod topology spread constraints.
```

`maxReplicaCount: 3` and `maxSkew: 1` cannot both be satisfied on two schedulable
workers (R8). Worse for this document's purposes,
`tests/smoke/07-autoscaling.bats` **passes anyway**, because it asserts
`.spec.replicas -gt 2`, which is the number KEDA writes rather than the number of
pods serving traffic. Desired went to 3 and `readyReplicas` stayed at 2.

The sentence to keep: a correct signal proves the observability layer works and
proves nothing about the autoscaler. Those are two claims and they need two
measurements.

One half of this document's central argument is still not measured, and the load
test above did not take it.

> **Unmeasured (2026-08-19):** the predictor's CPU usage while saturated, next
> to its queue depth **at the same moment**. The 2026-08-20 load test recorded
> the queue and not the CPU, so it shows that the queue signal moves and not
> that CPU fails to. **The reason has changed and the pair has not been taken.**
> This marker originally said no cluster existed; one has existed since
> 2026-08-19. Settle it by running
> `kubectl -n llm top pod -l serving.kserve.io/inferenceservice=ornith-9b`
> alongside
> `curl -s --get http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=llmstack:requests_waiting:by_model' | jq .`
> with a Prometheus port-forward open, while the cluster is under sustained
> load. kind installs no metrics-server, so `kubectl top` needs one installed
> first, or `docker stats` used instead.

## Normalisation is not renaming

Boundary 3 in `CLAUDE.md` says dashboards, alerts, and the KEDA trigger read only
`llmstack:*`. Writing the recording rules is the easy half. Deciding what each
rule aggregates over is the half that broke.

**R14, found 2026-08-20.** `llmstack:requests_waiting` was
`sum(llamacpp:requests_deferred)` with no `by` clause, so every label was
dropped. The `PodMonitor` scrapes every pod carrying
`serving.kserve.io/inferenceservice`, which includes `fallback-small-predictor`.
So `ornith-9b` was scaling on a number that included a different model's queue.

The fix adds `podTargetLabels` to carry the InferenceService name into every
predictor series, records `llmstack:requests_waiting:by_model` aggregated by it,
and filters the `ScaledObject` on `ornith-9b`
(`platform/30-observability/recording-rules.yaml:38`,
`models/ornith-9b/overlays/local/scaledobject.yaml:44`). The cluster-wide
`llmstack:requests_waiting` stays, because the dashboard reads it unfiltered.
Two rules, two consumers, two different correct answers.

**Normalisation also has a delay, and CI measured it.** Run `32336384415` failed
on tests 12 and 13, `prometheus is scraping the predictor` and `normalised
llmstack series exist`. Test 14, `raw engine series backing the normalisation
still exist`, **passed in the same run**. The engine series were there and the
recording rules had not produced their output yet. Twenty-two of twenty-four
tests passed (`docs/STATUS.md`, criterion 9). A normalisation layer is a second
place where a value can be missing, and "the metric is absent" and "the engine is
not reporting" are different failures that look identical on a dashboard.

## Time to first token comes from a prober, not from the engine

llama.cpp exposes counters and gauges and **no per-request latency histogram at
all**, so there is nothing for a `histogram_quantile` to consume, and it emits no
traces either (ADR 0005, ADR 0006). Time to first token is therefore measured by
a client-side prober: `platform/30-observability/ttft-prober-cronjob.yaml` sends
one streaming request a minute and reads curl's own `time_starttransfer`,
publishing `llm_ttft_probe_seconds` to a Pushgateway.
`quantile_over_time` turns that series of single samples into a rolling p50 and
p95. The dashboard panel is titled to say so, because a synthetic number must
never be mistaken for a served one.

It works. Run 4 of the pull path, 2026-08-20, recorded
`ttft-prober: 0.392332s`.

Three prober pods in that same run were in `Error`, and reading `kubectl get
pods` alone would have raised a false alarm. Two reasons, both real: they ran 8
to 10 minutes before the check while the model was still loading its weights, so
there was nothing to probe; and the prober's `activeDeadlineSeconds: 45` sits
inside the window R22 measured, where the gateway holds a streamed response open
long after the body is complete. The prober now sets
`stream_options.include_usage`, which is what closes the response on its last
byte.

## What breaks if this layer is removed

Without the recording rules and the dashboard, the operator's only visibility
into the predictor is whatever the platform's generic pod metrics show (CPU,
memory, restart count), none of which distinguish "serving fine" from "queue is
growing". The KEDA `ScaledObject` also has nothing to read: it targets
`llmstack:requests_waiting:by_model` directly, so removing this layer removes the
autoscaling signal, not just the dashboard.

That coupling was demonstrated by accident on 2026-08-20. An
`AuthorizationPolicy` experiment in namespace `llm` put all three predictor
scrape targets into `health=down`, and `llamacpp:requests_deferred` returned
nothing at all. The dashboard going blank is visible. KEDA losing its only input
is not (R12).

## What it costs to run

Measured 2026-08-19: the `observability` step took **126 seconds**, the slowest
layer, and moved the cluster from 4389 MiB to 5737 MiB. That **1348 MiB** jump is
the largest of any platform layer, which is expected: it brings Prometheus,
Grafana, Alertmanager, node-exporter, kube-state-metrics, the OpenTelemetry
Collector, Pushgateway, and Tempo (`docs/deployment-log.tsv`).

The OpenTelemetry Collector's `traces` pipeline costs something with no benefit
yet in phase 1: it has **zero producers**, because llama.cpp emits no OTLP of any
kind. It stays deployed anyway, because the GenAI attribute naming it carries is
where phase 2's vLLM traces land, and standing that pipeline up later would mean
re-deriving those names from scratch instead of changing one file.

One limit on the alerting half, and it is not a small one.
`platform/30-observability/values-prometheus.yaml:48` sets `alertmanager:
enabled: false`, so a firing alert reaches Prometheus and its `ALERTS` series
and nothing else. Nobody is paged. Enabling Alertmanager is its own decision with
its own memory cost.

## The one thing that surprised me while building it

**The one failure this stack has actually suffered was being recorded, and
nothing was reading it.**

Until 2026-08-20 this repository contained exactly one alert, `TTFTProberStale`,
and it watched the prober rather than the service. Meanwhile
`llmstack:gateway_error_ratio:rate5m` was recorded and had no consumer at all.
So R7, the gateway returning 500 on both paths under load, was already visible in
Prometheus and would have raised nothing (R18). The metric existed. The
dashboard could draw it. No alert named it.

There are five alerts now, read 2026-09-04 from
`platform/30-observability/recording-rules.yaml`: `LLMGatewayWasmShimNotLoaded`,
`LLMGatewayErrorRatioHigh`, `LLMQueueAboveScaleThreshold`,
`LLMPredictorReplicasNotReady`, and `TTFTProberStale`. Each one exists because a
specific thing went wrong on a real cluster first.

That order is the finding. Every argument at the top of this document is about
choosing the right *signal*, and every one of them held. What did not hold was
the step after it: a signal that is recorded, graphed, and unread is not
observability. It is a number waiting for somebody to already suspect the answer.

## What is still owed

Criterion 5 asks that Grafana show TTFT p95 and requests waiting **from real
traffic**. It is untested. `bats tests/smoke/05-observability.bats` settles it
against a live cluster, and `docs/STATUS.md` is the count of record.
