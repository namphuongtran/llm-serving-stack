# 12. Glossary

> **Part of:** the [Software Architecture Document](README.md). arc42 section 12.

Each entry names the document of record rather than restating it. Where a term
has a repository-specific meaning, that meaning is given here and the file that
sets it is named.

## LLM serving

| Term | Meaning here | Record |
|---|---|---|
| **TTFT** | Time to first token. The delay from sending a request to receiving the first byte of the answer. Here it is measured by a client-side prober with curl's `time_starttransfer`, because llama.cpp exposes no per-request latency histogram | [ADR 0006](../adr/0006-metric-normalisation.md) |
| **Prefill** | Computing the attention state for the whole prompt, before any token is generated. Its cost grows with prompt length | [`docs/08-why-llm-d.md`](../08-why-llm-d.md) |
| **Decode** | Generating the answer one token at a time, after prefill | [`docs/08-why-llm-d.md`](../08-why-llm-d.md) |
| **KV cache** | The stored attention state a replica holds for prompts it has already seen. A replica holding a matching prefix can skip re-computing that prefill | [`docs/08-why-llm-d.md`](../08-why-llm-d.md) |
| **Cache-aware routing** | Choosing the replica by what it already holds in its KV cache, not only by how busy it is. Phase 3 | [ADR 0003](../adr/0003-gateway-istio-ambient.md) |
| **Queue depth** | The engine's own count of requests waiting for a slot. `llamacpp:requests_deferred`, normalised to `llmstack:requests_waiting`. The autoscaling signal | [`docs/06-why-otel.md`](../06-why-otel.md) |
| **Token quota** | A budget counted from the response's own `usage.total_tokens`, not from a request count | [`docs/04-why-kuadrant.md`](../04-why-kuadrant.md) |
| **GGUF** | The quantised model file format llama.cpp loads. One file, verified here against a recorded `sha256` | `models/ornith-9b/base/model.yaml` |
| **Engine** | The process that runs the model and serves the OpenAI-compatible API. llama.cpp in phase 1. **Both** llama.cpp and vLLM in phase 2, on the same node, so the benchmark changes one variable | [ADR 0005](../adr/0005-two-runtimes-one-control-plane.md), [ADR 0010](../adr/0010-two-engines-one-cluster.md) |
| **Engine contract** | The four things any engine here must provide: the OpenAI HTTP surface, readiness that is true only after weights load, Prometheus metrics with a required minimum set, and an OTLP traces endpoint. The fourth is unmet in phase 1, because llama.cpp emits no traces | [ADR 0005](../adr/0005-two-runtimes-one-control-plane.md) |
| **Alias** | The served model name a caller puts in a request's `model` field, set by `--alias`. A model fact, never a runtime fact. In phase 2 the two engines carry different aliases so a result can name the engine that produced it | [ADR 0010](../adr/0010-two-engines-one-cluster.md) |

## Platform

| Term | Meaning here | Record |
|---|---|---|
| **Ambient mode** | Istio without per-pod sidecars: one `ztunnel` per node. Chosen because the whole stack shares one laptop | [ADR 0003](../adr/0003-gateway-istio-ambient.md) |
| **`ext_proc`** | Envoy's external processing filter. The Gateway API Inference Extension's endpoint picker is an `ext_proc` server, so a gateway without it cannot do cache-aware routing | [ADR 0003](../adr/0003-gateway-istio-ambient.md) |
| **`ServingRuntime`** | The KServe object that supplies the engine: image, args, ports, probes. **No model fact may appear in one** | `runtimes/llamacpp-arm64/` |
| **`InferenceService`** | The KServe object that binds one model to one engine: format, runtime name, arguments. The binding belongs to an **overlay**. `models/*/base/` names no engine, because one model is served by different engines in different phases | `models/ornith-9b/overlays/`, [ADR 0010](../adr/0010-two-engines-one-cluster.md) |
| **Index digest** | The digest of a multi-architecture image index, as opposed to the digest of one of its per-architecture children. This repository pins the index, so one value is correct on arm64 and amd64 alike | [ADR 0009](../adr/0009-pin-index-digests-not-arch-children.md) |
| **Standard mode** | KServe's plain deployment mode, without Knative. No scale to zero by default | [ADR 0002](../adr/0002-standard-mode-not-knative.md) |
| **Sync wave** | An Argo CD annotation that orders Applications. Ordering, never a guarantee: an Application that cannot read its git path still reports `Healthy` | [05-building-blocks](05-building-blocks.md) |
| **Overlay** | A Kustomize directory that adapts the base model for one environment: `local`, `ci`, `cost-saving`, `gpu-single`, `gpu-multi` | `models/ornith-9b/overlays/` |
| **Recording rule** | A Prometheus rule that publishes an `llmstack:`-prefixed series from an engine's own series, so no consumer names an engine | `platform/30-observability/recording-rules.yaml` |
| **Tier** | A JWT claim, `free` or `pro`, that the quota counter is keyed on. Two Keycloak clients, `llm-tier-free` and `llm-tier-pro` | `security/oidc/` |

## Evidence vocabulary

This repository uses these words precisely. Mixing them up is the defect the
vocabulary exists to prevent.

| Term | Meaning | Marker |
|---|---|---|
| **Unproven** | Nobody has measured it. The manifest and the test are both believed correct; the measurement is owed | `> **Unmeasured (<date>):**` |
| **Untried** | Nobody has exercised the mechanism at all | `**Untried (<date>):**` |
| **Doubted** | There is a specific, sourced, technical reason to believe it does not work as designed, whether or not a cluster ever confirms it | Recorded in an ADR |
| **Blocked** | Tried, failed, and understood. Carries the exact error and the upstream source lines that explain it | `> **BLOCKED (<date>):**` |
| **Unverified by construction** | Phase 1's own acceptance bar, which cannot be met until the suite runs end to end once | [`docs/STATUS.md`](../STATUS.md) |

`Untried` is deliberately not `Blocked`. Trying something is what produces a
`Blocked` finding, so the two can never describe the same thing.

## Sources

Every entry names its own record. The evidence vocabulary is
[`docs/STATUS.md`](../STATUS.md) and [`CLAUDE.md`](../../CLAUDE.md).

---

[Prev: Risks and technical debt](11-risks-and-debt.md) · [Index](README.md)
