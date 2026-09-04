# ADR 0010: Both engines run on the phase 2 node, as a controlled comparison

- Date: 2026-09-04
- Status: accepted
- Extends [ADR 0005](0005-two-runtimes-one-control-plane.md). Reverses nothing.
  [ADR 0002](0002-standard-mode-not-knative.md) still holds: `InferenceService`
  in Standard mode, and `LLMInferenceService` stays in phase 3.

## Context

ADR 0005 put llama.cpp on the laptop and vLLM in the cloud, and said the point
was to prove the engine is a plug-in rather than a foundation. Phase 2 is where
that claim is testable.

The obvious way to run phase 2 is to deploy vLLM on the GPU node and compare its
numbers to phase 1's. That comparison is worthless. It changes the engine, the
architecture, the hardware, the model precision, and the date, all at once, and
then attributes the difference to the engine.

## Decision

**Deploy both engines on the same GPU node, in the same cluster, and benchmark
them on the same day.** Only the engine changes between the two runs.

Five parts.

1. **vLLM runs under a hand-written `ServingRuntime`** wrapping
   `vllm/vllm-openai`, exactly as `runtimes/llamacpp-arm64/servingruntime.yaml`
   already wraps an engine KServe does not document either.
2. **Selection is by path**, on one `HTTPRoute`: `/v1` reaches vLLM,
   `/llamacpp/v1` reaches llama.cpp. One route means one Kuadrant policy target,
   so the quota is defined in exactly one place and applies to both engines.
3. **The two predictors carry distinct aliases**, `ornith-9b` and
   `ornith-9b-llamacpp`, on `InferenceService` objects of the same names.
4. **One overlay.** `models/ornith-9b/overlays/gpu-single/` carries both
   `InferenceService` objects and both runtime references. They are one
   deployment unit with one purpose, and either half alone is meaningless.
5. **`fallback-small` is not deployed here.** ADR 0007 withdrew the failover
   mechanism it existed to serve, so it survives in the local overlay as a
   deployed-but-unrouted remnant. Phase 2 does not carry it onto metered
   hardware.

## Why a hand-written ServingRuntime, and what is unverified about it

KServe publishes no `ServingRuntime` for vLLM. Its `servingruntime.md` contains
zero occurrences of "vllm", and its bundled-runtime table lists only
`kserve-huggingfaceserver`. The documented way to use the `vllm/vllm-openai`
image directly is the `LLMInferenceService` CRD, which ADR 0002 reserves for
phase 3.

Two alternatives were rejected:

| Option | Verdict |
|---|---|
| `kserve/huggingfaceserver:v0.20.0-gpu` | Rejected. It is documented, and KServe's overview says it "uses vLLM backend engine". But `kserve/pyproject.toml` at tag v0.20.0 pins `vllm==0.24.0`, four releases behind v0.28.0, and it puts a Python wrapper in the request path. The comparison would then be llama.cpp against KServe's wrapper around an older vLLM, which is not the claim being tested |
| `LLMInferenceService` in phase 2 | Rejected. It reverses ADR 0002 and pulls phase 3 capability forward to solve a packaging problem |

> **Untried (2026-09-04):** no `ServingRuntime` wrapping `vllm/vllm-openai` has
> been applied to any cluster. Nothing in KServe's documentation describes this
> shape. It is believed to work because a `ServingRuntime` is a container spec
> with a port and a probe, and vLLM serves the OpenAI API natively, exposes
> `/health` and `/metrics`, and takes `--model` as an argument. **The first
> action on the GPU machine is to start this pod.** If it fails, the fallback is
> `kserve/huggingfaceserver:v0.20.0-gpu` and that failure earns its own ADR.

## A policy gap found while deciding this, independent of phase 2

`security/oidc/authpolicy.yaml` sets `targetRef.name: ornith-9b-openai`, a single
`HTTPRoute`. Separately, the comment at the top of
`models/ornith-9b/overlays/local/httproute.yaml` records that with
`enableGatewayApi: true`, KServe's own ingress reconciler generates an
`HTTPRoute` named after the `InferenceService`, at `llm/ornith-9b`. The
hand-written route is named `ornith-9b-openai` specifically to avoid colliding
with it.

So a route exists that the `AuthPolicy` does not target.

> **Untried (2026-09-04):** whether that generated route is reachable from
> outside the cluster has not been checked, and no claim is made either way
> here. Check it on the local cluster, where it costs nothing:
> `kubectl -n llm get httproute -o wide`, then send an unauthenticated request
> to whatever hostname it carries. If it is reachable, this is a security
> finding for phase 1 and belongs in `docs/sad/11-risks-and-debt.md` as a new
> risk, not in phase 2's notes.

**The `AuthPolicy` retargets to the `Gateway`** (`istio-system/llm`) rather than
to one named route, so every route through that gateway is covered, including
any KServe generates. This is worth doing whether or not the gap above turns out
to be reachable, and whether or not phase 2 happens.

## Cost accepted

**The two benchmark runs are not byte-identical.** Their request bodies differ in
the `model` field, because the aliases differ. Distinct aliases were chosen
anyway: a benchmark result whose engine can only be identified by remembering
which URL was used is a number without provenance, and `/v1/models` should say
which engine answered. The difference is one string, and the results must say so.

**`gpu-single/README.md` currently describes one engine.** It reads "One GPU
node, vendor neutral. vLLM runtime, bf16 weights, real engine metrics." That is
now a true description of a superseded plan, and it changes in the same commit
as the overlay.

## Evidence

All read 2026-09-04.

- KServe `docs/concepts/resources/servingruntime.md`: zero occurrences of
  "vllm"; the included-runtime table lists `kserve-huggingfaceserver`.
- KServe `docs/model-serving/generative-inference/llmisvc/llmisvc-configuration.md`
  line 216: `image: vllm/vllm-openai:latest`, inside an `LLMInferenceService`.
- `kserve/kserve` at tag v0.20.0, `python/kserve/pyproject.toml`:
  `llm = [ "vllm==0.24.0", ]`.
- vLLM GitHub releases API: `tag_name: "v0.28.0"`, `published_at:
  "2026-08-26T09:46:30Z"`, `prerelease: false`.
- `security/oidc/authpolicy.yaml`: `targetRef.name: ornith-9b-openai`.
- `models/ornith-9b/overlays/local/httproute.yaml`, header comment: KServe
  "generates an HTTPRoute named after the InferenceService, in the
  InferenceService's namespace - literally llm/ornith-9b".
