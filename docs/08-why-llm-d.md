# Why round-robin is wrong

## The question this answers

Why does sending a request to the least busy pod make the service slower?

Round-robin, and even load-aware routing, treats every replica as
interchangeable. It is not: a replica that already holds a request's shared
prompt prefix in its KV cache can skip re-computing that prefix entirely.
Routing the next request with the same prefix to a *different*, cold replica
throws that work away and pays the full prefill cost again. Cache-aware
routing is choosing the replica by what it already knows, not just by how
busy it is.

## What this repository can show today, and what it cannot

`bench/scenarios/03-shared-prefix.json` exists specifically to produce the
local half of this comparison: a 3,500-token shared prefix across 24 prompts,
against `01-short.json`'s 32-token prompts with no shared prefix. Run against
the same llama.cpp engine, the two scenarios' output-tokens-per-second and
time-to-first-token numbers would show whatever benefit a *single* replica's
own KV cache reuse already gives this engine, on this machine, today - that
comparison needs no llm-d, no cache-aware routing, and no second replica; it
is available in phase 1.

> **Unmeasured (2026-08-19):** the throughput and TTFT difference between
> `03-shared-prefix.json` and `01-short.json` on `ornith-9b`/llama.cpp.
> **The reason has changed twice and the number is still owed.** This marker
> originally said no cluster existed. A cluster has existed since 2026-08-19,
> `task bench` has run, and it still cannot produce this pair. The three
> obstacles are named in the next section. Run both scenarios once they are
> cleared, and record the pair of numbers here with the date.

## Why the local half is still not measurable, and it is no longer for lack of a cluster

`task bench` ran on 2026-08-20. It produced the first benchmark numbers this
repository has ever had, and none of them can answer the question above.

**1. No scenario can finish before its own token expires (R10).**
`bench/run.sh:24` fetches one token for a whole run, and
`platform/15-keycloak/realm-export.json` sets `accessTokenLifespan: 900`. The
first completed run, `01-short.json`, 40 requests at concurrency 4, took about
19 minutes:

| TTFT p50 | TTFT p95 | ITL p95 | out tok/s | errors |
|---|---|---|---|---|
| 186.494s | 199.852s | 29.684s | 0.210 | **31 of 40** |

Nineteen of the thirty-one errors were HTTP 401, and they are the token
expiring at about minute 15. Nine were 500 and three were 503, both from the
auth degradation under load recorded as R7. The latency figures come from **9
successful requests out of 40, on a cluster that was also failing**. They are a
first data point and not this stack's performance.

At 0.210 output tokens per second, every scenario in `bench/scenarios/` runs
longer than 15 minutes. So this is not a corner case, and
`03-shared-prefix.json` is the more expensive of the two: 24 prompts of 4000
tokens each, against `01-short.json`'s 32-token prompts.

**2. The cluster was not quiet.** R7's 500s and 503s are in the error column
above. A shared-prefix comparison measures a difference between two runs, and a
difference between two contaminated runs is not a measurement.

**3. Any TTFT taken through the gateway needs `stream_options.include_usage`
(R22).** Measured 2026-08-21 on identical small requests, that field the only
difference: **without** it `ttfb=2.38s total=40.93s`; **with** it `ttfb=1.92s
total=1.92s`. When `usage` is absent, the Kuadrant Wasm shim holds the streamed
response open long after the last byte. `bench/harness.py:18` already sets the
field, so the harness itself is safe. Any hand-rolled `curl` comparison run
beside it is not, and it would report a total time that says more about the
policy layer than about the engine.

The order of work is therefore fixed: fix the token refresh in `bench/run.sh`,
re-run on a quiet cluster, and only then compare the two scenarios.

## What routing does today

Nothing in phase 1 is cache aware, and it is worth being precise about what
*is* running. The `HTTPRoute` sends requests to the KServe predictor Service,
which distributes across the two replicas without any knowledge of what either
one holds in cache. Two replicas ran on separate nodes on 2026-08-20, confirmed
independently at 06:02:02Z: `ornith-9b-predictor` replicas 2, on `worker` and
`worker2` (`docs/STATUS.md`, criterion 1).

So the behaviour this document calls wrong is the behaviour in production here
right now. That is deliberate: phase 1's job was to build the layers that make
the comparison possible, not to win it.

That single-replica number is not the phase 3 claim, and this document does
not conflate the two. What it cannot show at all, on one llama.cpp replica on
one laptop, is the *cross-replica* case: whether routing a second request
with the same shared prefix to the specific replica that already holds it in
cache - rather than to whichever replica round-robin or load-aware scoring
picks - produces a *further* gain on top of whatever single-replica reuse
already gives. That requires more than one replica whose caches can actually
differ, which is multi-node territory (docs/adr/0002, the design spec's
phase table): llm-d's endpoint picker scores candidate pods by tracking KV
cache blocks through ZMQ events vLLM pods emit, weighted `2.0` against
load-awareness's `1.0` - a mechanism llama.cpp does not participate in at all
(ADR 0005: no ZMQ events, no cache-aware routing, in phase 1, full stop).

## The specific claim phase 3 will test

The design spec's own evidence log records this, deliberately kept separate
from its verified facts table. The claim is quoted in full below, because its
source (`docs/superpowers/specs/2026-08-17-llm-serving-stack-design.md`,
section 17) is a local working document and is not in git:

> "the reported 3x output tokens per second and 2x lower time to first token
> from cache-aware routing on Llama 3.1 70B with four MI300X GPUs... treated
> as claims to test in phase 2 and phase 3, not as facts."

That figure is a vendor-blog number about a specific model and GPU
configuration this repository has never run, and it is not this repository's
own ADR 0003 (ambient Istio's footprint numbers, a different claim entirely -
misattributed once already in this repository's own commit history and
corrected there; not repeated here). Phase 3's job is not to repeat the vendor
number. It is to measure, on this stack's own two scenarios above, run
against multiple replicas of the *same* engine on the *same* hardware class:
does routing by cache locality beat routing by load alone, and by how much,
here - not on Llama 3.1 70B and MI300X GPUs, but on whatever model and
hardware phase 3 actually runs. Until that measurement exists, the vendor
figure is a reason to expect a real effect, not a number this repository is
entitled to quote as its own.

## What breaks if this layer is removed

Nothing, today, because it is not installed. This is the only document in the
`why` series describing a layer that does not exist yet, and saying so plainly
is more useful than inventing a dependency.

What you keep instead is the routing described above: every replica treated as
interchangeable, and the shared prefix re-computed whenever a request lands on a
replica that does not hold it. The cost of that is a prefill, and the size of a
prefill is the one thing this stack can already see. `01-short.json` sends
32-token prompts; `03-shared-prefix.json` sends 4000-token prompts of which 3500
are shared. Recomputing 3500 tokens of prefill is what round-robin risks paying
on every request, and `llmstack:tokens_in_total`
(`platform/30-observability/recording-rules.yaml`) is where it would show up.

## What it costs to run

Unknown on this stack, because llm-d has never been installed here. Two costs
are already documented rather than estimated, and both are structural:

- **A gateway conflict to re-check.** ADR 0003's accepted cost 4 records that
  llm-d states a pre-existing Istio install conflicts with its own gateway. That
  has to be re-checked before phase 3, and it is the one item that could reopen
  the gateway decision.
- **A different KServe resource.** ADR 0002 defers `LLMInferenceService` to
  phase 3, where multi-node inference and cache-aware routing require it.
  `InferenceService` does not expose prefill and decode separation, multi-node
  orchestration, or intelligent scheduling.

Both costs land entirely in phase 3. Neither is being paid now.

## The one thing that surprised me while building it

**The half of the comparison that looked free was the half that got blocked.**

The reasoning in this document separates two claims carefully: what a single
replica's own KV cache reuse gives, which needs no llm-d and no second replica,
and what cache-aware routing adds on top of it, which needs both. The first was
supposed to be available in phase 1 for the price of running two scenarios.

It was not, and none of the three obstacles has anything to do with routing or
caching. A token lifespan of 900 seconds meets an engine that generates 0.210
tokens per second. An auth layer degrades under the very load a benchmark
creates. A policy shim holds a streamed connection open when the client does not
ask for its own usage. Each one is correct behaviour in its own layer, and
together they make a throughput comparison impossible on this machine today.

That is the argument for building the layers before trying to win the
comparison, and it is also the warning. A performance question is answered by
the whole stack, not by the component the question names.
