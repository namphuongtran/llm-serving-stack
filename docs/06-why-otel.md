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

Autoscaling on CPU (Task 9's alternative that was rejected) inherits the
first problem directly: a `ScaledObject` reading CPU would not scale up while
the engine is saturated-but-not-CPU-bound, and would only react once the
symptom finally reached the resource it is watching - usually the same
moment users have already noticed. Scaling on `llmstack:requests_waiting`
reacts to the queue itself, before it shows up anywhere else.

## What breaks if this layer is removed

Without the recording rules and the dashboard, the operator's only visibility
into the predictor is whatever the platform's generic pod metrics show (CPU,
memory, restart count) - none of which distinguish "serving fine" from
"queue is growing." The KEDA `ScaledObject` in Task 9 also has nothing to
read: it targets `llmstack:requests_waiting` directly, so removing this
layer removes the autoscaling signal, not just the dashboard.

## What it costs to run

Two extra components (kube-prometheus-stack, the OpenTelemetry Collector)
plus a Pushgateway for the TTFT prober, sized deliberately small in
`values-prometheus.yaml` and `pushgateway-values.yaml` to run beside a 6 GB
model on a 32 GB laptop. The OpenTelemetry Collector's `traces` pipeline
specifically costs something with no benefit yet in phase 1: it has zero
producers, because llama.cpp emits no OTLP of any kind (ADR 0005, ADR 0006).
It stays deployed anyway, because the GenAI attribute naming it carries is
where phase 2's vLLM traces land, and standing that pipeline up later would
mean re-deriving those names from scratch instead of changing one file.

## The one thing that surprised me while building it

That the queue-depth signal this document argues for could not be verified
the way the design originally called for - by comparing a measured CPU
number against a measured queue depth on a saturated predictor. No cluster
exists in phase 1 authoring (see the plan's Ruling 9), so there is no running
predictor to saturate and no `kubectl top pod` to run. The argument above is
the same argument the design always made; what changed is that it is stated
as reasoning rather than as a measured pair of numbers, and the pair is
recorded below as still owed.

> **Unmeasured (2026-08-19):** the predictor's CPU usage while saturated,
> next to its queue depth at the same moment, run
> `kubectl -n llm top pod -l serving.kserve.io/inferenceservice=ornith-9b`
> alongside
> `curl -s --get http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=llmstack:requests_waiting' | jq .`
> (with the Task 7 Prometheus port-forward open) once a cluster exists and is
> under sustained load.
