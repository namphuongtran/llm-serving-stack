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
> `03-shared-prefix.json` and `01-short.json` on `ornith-9b`/llama.cpp. No
> cluster exists in this authoring pass (the human's machine cannot spare the
> memory Docker needs), so `task bench` has never run against a live
> `ornith-9b-predictor` (`bench/results/README.md` records the same gap). Run
> both scenarios once a cluster exists and record the pair of numbers here,
> with the date.

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
