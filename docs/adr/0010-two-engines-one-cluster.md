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

## A policy gap I claimed, and why it was wrong

The first draft of this ADR claimed that a KServe-generated `HTTPRoute` exists
which `security/oidc/authpolicy.yaml` does not target, and recommended
retargeting that policy at the `Gateway`. **Both halves were wrong.** The claim
is corrected here rather than deleted, because the reasoning that produced it is
the kind this repository is built to catch: it came from reading one comment and
not reading the configuration that governs it.

**There is no generated route.** `platform/20-kserve/values-kserve.yaml` sets
`disableIngressCreation: true`, and `clusters/local-kind/apps/20-kserve.yaml:57`
carries the same value in its inline Helm values. That file's own comment, dated
2026-08-19, had already reached this conclusion and gave two independent reasons:
the generated routes' hostnames come from `GenerateDomainName`, which produces
`ornith-9b-llm.example.com`, and the Gateway's only listener has
`hostname: llm.localtest.me`, so they would be rejected with
`NoMatchingListenerHostname`; and even if they attached, they would be a second
unauthenticated way into the model. KServe therefore creates no route and marks
`IngressReady` true directly (`httproute_reconciler.go:1066`).

Two live tests already assert this, and they predate this ADR:
`tests/smoke/04-kserve.bats:74` reads `.disableIngressCreation` off the running
ConfigMap, and `:80` requires `httproute/ornith-9b` and
`httproute/ornith-9b-predictor` to be `NotFound`, failing with "KServe generated
an HTTPRoute named $name, which disableIngressCreation should have prevented".

So naming the hand-written route `ornith-9b-openai` is defence in depth against
a collision that cannot currently happen, not a live gap.

**Retargeting the `AuthPolicy` at the `Gateway` would break authentication
entirely, and must not be done.** `platform/15-keycloak/httproute.yaml` attaches
to the same `Gateway` `istio-system/llm`, on the same hostname
`llm.localtest.me`, matching path prefixes `/realms` and `/resources`. The
`AuthPolicy` requires a JWT whose issuer is
`http://llm.localtest.me/realms/llm`. A Gateway-scoped version of it would
demand a valid JWT in order to reach the endpoint that issues JWTs, and to fetch
the JWKS used to verify them. That is a deadlock, and it would break `task
token`, `task chat`, and every smoke test.

`platform/10-istio/gateway.yaml` states the shared-Gateway design in its first
line: "One Gateway for everything: the inference API and Keycloak share a
hostname, so the JWT issuer matches the URL used to fetch JWKS". A policy scoped
to that Gateway cannot distinguish the two consumers.

**What stands.** The `AuthPolicy` stays targeted at the `HTTPRoute`. Decision
part 2 above is what makes that sufficient for two engines: one route with two
path-matched rules means one policy target, and both engines inherit it.

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
- `security/oidc/authpolicy.yaml`: `targetRef.name: ornith-9b-openai`, and
  `issuerUrl: http://llm.localtest.me/realms/llm`.
- `platform/20-kserve/values-kserve.yaml` and
  `clusters/local-kind/apps/20-kserve.yaml:57`: `disableIngressCreation: true`.
- `tests/smoke/04-kserve.bats` lines 74 and 80: the two tests that assert no
  KServe-generated route exists.
- `platform/15-keycloak/httproute.yaml`: `parentRefs` naming Gateway
  `istio-system/llm`, `hostnames: ["llm.localtest.me"]`, path prefixes
  `/realms` and `/resources`.
- `platform/10-istio/gateway.yaml`: one listener, `hostname: llm.localtest.me`.
