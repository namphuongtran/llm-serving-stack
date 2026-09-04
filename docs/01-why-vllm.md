# Why an inference engine

Status: written 2026-09-04, from what running the stack showed. The engine that
ran is llama.cpp, not vLLM. This file keeps its name because the question is
about the layer, and `docs/README.md` indexes it as "why an inference engine,
and not plain transformers". vLLM has never run in this repository, so nothing
below is a claim about vLLM. What phase 2 owes is at the end.

## The question this answers

Why not serve the model with plain transformers, one request at a time?

## Answer

A serving engine is not a faster way to call a model. It is three mechanisms
that a request-at-a-time loop does not have, and this repository depends on all
three.

**1. It keeps a batch in flight, and it reports the queue.**
`runtimes/llamacpp-arm64/servingruntime.yaml:52` sets `--parallel 2`, so one
replica holds two slots. Two replicas give four requests in flight. A fifth
request waits, and the engine publishes the wait as its own metric,
`llamacpp:requests_deferred`. A loop that answers one request at a time has no
slots and no queue of its own: the waiting happens in the kernel's accept
backlog, where nothing above can read it. Measured on 2026-08-20 under 64
streaming requests at concurrency 8, the queue reached 5 and KEDA acted on it
(`docs/STATUS.md`, "The first load test", finding 1).

**2. It reuses the KV cache between requests.** A second request that shares a
prompt prefix with the first can skip re-computing that prefix. A loop that
loads, answers, and returns pays the prefill again every time. What that reuse
is worth across *replicas* is a different question, and
[`08-why-llm-d.md`](08-why-llm-d.md) keeps it separate rather than folding it in
here.

**3. It speaks a contract, so nothing above it names an engine.** ADR 0005 sets
that contract at four parts: the OpenAI HTTP surface, readiness that is true
only after weights load, Prometheus metrics with a required minimum set, and an
OTLP traces endpoint. Three of the four hold for llama.cpp. The fourth does not,
and that is recorded below rather than glossed.

## What breaks if this layer is removed

Not "the model does not serve". Three named files stop working, and each one is
a layer this repository already built.

| What breaks | Where | Why |
|---|---|---|
| The token quota counts nothing | `security/oidc/tokenratelimitpolicy.yaml` | A `TokenRateLimitPolicy` extracts `usage.total_tokens` from the response body without extra configuration, which is why that field appears nowhere in the file (ADR 0004, evidence). No engine, no field, nothing to count |
| The autoscaler has no input | `models/ornith-9b/overlays/local/scaledobject.yaml:44` | It scales on `llmstack:requests_waiting:by_model`, which `platform/30-observability/recording-rules.yaml:38` derives from `llamacpp:requests_deferred` |
| The contract suite has nothing to assert against | `tests/contract/` | It exists to keep everything above the engine engine-independent |

The first row is not hypothetical. R21 measured what happens when
`usage.total_tokens` is absent from a response: Kuadrant counts it as zero and
the quota is bypassed entirely (`docs/sad/11-risks-and-debt.md`, R21, measured
2026-08-21). So the failure mode of "no engine reporting usage" has already been
observed in the narrower case of "one response not reporting usage", and it is
silent.

## What it costs to run

**Memory.** Measured 2026-08-19 on a 3-node kind cluster with Docker given 23.2
GiB. The platform layers settled at 7043 MiB. With both models resident the
cluster reached **17855 MiB, 75%**. The jump between the `model` row and the
`security` row of `docs/deployment-log.tsv` is **10766 MiB**, larger than every
platform layer put together. (`docs/deployment-walkthrough.md` calls that jump
"about 10.7 GiB". 10766 MiB is 10.5 GiB. Both point at the same two rows;
re-derived from the tracked log on 2026-09-04.)

Read `docs/deployment-walkthrough.md`, "What each layer costs", for why row 12 of
that table is not the model's cost: it was written two seconds after `kubectl
apply` returned, before either model had loaded.

**Throughput, on this hardware.** Measured 2026-08-20: **0.210 output tokens per
second**, from `01-short.json`, 40 requests at concurrency 4. That number comes
from 9 successful requests out of 40 on a cluster that was also failing, so it
is a first data point and not this stack's performance
(`docs/STATUS.md`, finding 5).

That rate has one consequence sharp enough to state on its own. The realm sets
`accessTokenLifespan: 900` (`platform/15-keycloak/realm-export.json:4`), and
`bench/run.sh:24` fetches one token for the whole run. At 0.210 output tokens
per second **every scenario in `bench/scenarios/` runs longer than 15 minutes**,
so the token expires mid-run and the rest of the requests get 401. Nineteen of
the forty did. No benchmark on this engine can currently finish
(`docs/sad/11-risks-and-debt.md`, R10). That is an engine cost expressed as a
harness defect, which is the honest way round: a faster engine would have hidden
the defect for months.

## The one thing that surprised me while building it

The engine was not chosen. It was forced, and then it cost something nobody
priced in.

ADR 0005 records the forcing: `kserve/huggingfaceserver` publishes
`linux/amd64` only, and Rosetta 2 does not implement AVX, so an emulated vLLM
ends in an illegal instruction rather than in slow success. That left llama.cpp
on arm64, which is why `tests/lib/helpers.bash` carries `require_arm64` and why
CI runs on `ubuntu-24.04-arm`.

The unpriced cost came later, and ADR 0005 says so in its own words: llama.cpp
emits **no traces at all**, and its server documentation mentions neither OTLP
nor OpenTelemetry. That was "found while implementing and not anticipated when
this decision was made". So the engine contract's fourth part is unmet in phase
1, time to first token cannot come from spans, and it is measured instead by a
client-side prober
(`platform/30-observability/ttft-prober-cronjob.yaml`). The OpenTelemetry
Collector's traces pipeline is deployed with zero producers. That is a real cost
paid for a phase that has not arrived yet, and
[`06-why-otel.md`](06-why-otel.md) argues why it is still worth paying.

The lesson is about ADRs, not about engines. The decision was sound on every
fact known when it was taken. One of its costs was only visible from inside the
implementation, and the ADR was amended rather than left looking prescient.

## Measurement tool, built ahead of this document (2026-08-19)

`bench/run.sh`, `bench/harness.py`, and `bench/summarise.py` are an
engine-agnostic harness against the OpenAI-compatible endpoint, so the same four
scenarios in `bench/scenarios/` run unchanged against llama.cpp here in phase 1
and against vLLM once phase 2 swaps the runtime.

The harness has run. It has not yet produced a number worth keeping, for the
token-lifetime reason above.

## What phase 2 owes

> **Unmeasured (2026-09-04):** vLLM's own numbers on this stack, and the
> engine-to-engine comparison the harness was built for. Nothing here has run
> vLLM. Phase 2 settles it by pointing `runtimes/` at a vLLM `ServingRuntime`,
> leaving `models/ornith-9b/` untouched, and running
> `SCENARIOS=bench/scenarios/01-short.json ./bench/run.sh` against both engines.
> Fix R10 first, or the second run will fail the same way the first did.

The comparison is also the test of boundary 2 in `CLAUDE.md`: if swapping the
engine touches anything outside `runtimes/`, the boundary did not hold, and this
repository will have learned that by breaking it rather than by claiming it.
