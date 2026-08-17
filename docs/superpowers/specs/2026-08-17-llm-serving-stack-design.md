# LLM serving stack: design

- Date: 2026-08-17
- Status: approved, not yet implemented
- Owner: repository owner
- Related: `docs/adr/`

## 1. Context

The starting point was an article that deploys `distilgpt2` on a local kind
cluster with KServe v0.15, the built-in `huggingfaceserver` runtime, Istio
ingress, and PowerShell scripts. The article works as an install walkthrough.
It is not a production design, and it is roughly one and a half years behind the
current KServe line.

This document designs a replacement: a repository that runs the same idea on a
local Apple Silicon Mac first, then on real GPU nodes, and that carries the parts
the article omits (identity, quota, observability, autoscaling, high
availability, benchmarking, CI/CD).

## 2. Goals

1. Learn each layer of the stack well enough to explain why it exists.
2. Run end to end on a local M4 Mac with no GPU.
3. Move to GPU nodes later without changing the control plane or the repo shape.
4. Stay vendor neutral. No manifest may assume a specific cloud.
5. Be measurable. Every performance claim in this repository carries the date it
   was measured and the hardware it was measured on.

## 3. Non-goals

- No conversation storage, no chat UI, no application layer. Those belong to a
  consumer of this API, not to this repository.
- No billing system. Token usage is measured and rate limited, not invoiced.
- No production-grade Keycloak (no external database, no clustering). Keycloak
  runs in dev mode and its realm is imported from git. Production requirements
  are written in a runbook instead of built.
- No model training or fine-tuning.

## 4. Constraints

| Constraint | Value | Source |
|---|---|---|
| Local machine | Apple M4, 32 GB RAM, arm64 | measured on the machine, 2026-08-17 |
| Local GPU | none | Apple Silicon, no CUDA/ROCm |
| `kserve/huggingfaceserver` images | `linux/amd64` only, for `:latest` and `:v0.20.0` | Docker Hub registry query, 2026-08-17 |
| amd64 emulation on macOS | Rosetta 2 does not implement AVX, AVX2, or AVX512, so an x86 vLLM CPU build fails with an illegal instruction | docker/for-mac issues, Apple developer forums |
| vLLM on arm64 | supported, but there is no prebuilt wheel or image; it must be built from source | vLLM CPU install docs |
| CI runners | GitHub `ubuntu-24.04-arm`, 4 vCPU | GitHub changelog |

Two consequences follow directly and shape the whole design:

1. The local engine cannot be vLLM without a source build. So local and cloud
   run different engines.
2. Everything above the engine must therefore be engine independent.

## 5. Architecture

Layered, with one job per layer. The layer boundary is what makes the engine and
the gateway replaceable.

```
                       client
                         │  Authorization: Bearer <JWT>
                         ▼
  ┌────────────────────────────────────────────────────┐
  │ Entry           Istio (ambient), Gateway API        │
  │ Policy          Kuadrant: AuthPolicy,               │
  │                 TokenRateLimitPolicy                │
  ├────────────────────────────────────────────────────┤
  │ Identity        Keycloak (dev mode, realm in git)   │
  ├────────────────────────────────────────────────────┤
  │ Control plane   KServe, Standard deployment mode    │
  │                 ServingRuntime + InferenceService   │
  ├────────────────────────────────────────────────────┤
  │ Engine          local:  llama.cpp server (arm64)    │
  │                 cloud:  vLLM                        │
  ├────────────────────────────────────────────────────┤
  │ Scale           KEDA + OpenTelemetry add-on         │
  │ Telemetry       Prometheus, Grafana, OTel Collector │
  │ Delivery        GitHub Actions (CI), Argo CD (CD)   │
  └────────────────────────────────────────────────────┘
```

Request path, phase 1:

```
client → Istio gateway (gatewayClassName: istio)
       → Kuadrant AuthPolicy         (JWT verified against Keycloak JWKS)
       → Kuadrant TokenRateLimitPolicy (counters in Limitador/Redis)
       → HTTPRoute → InferenceService predictor Service
       → llama.cpp server, OpenAI-compatible, streaming
```

One hostname serves both Keycloak and the inference API: `llm.localtest.me`,
which resolves to 127.0.0.1 with no host file edit. This removes the common
failure where the JWT issuer does not match the URL used to fetch JWKS.

## 6. Component decisions

Each decision has its own ADR. Summary:

| Layer | Choice | Main reason | Rejected |
|---|---|---|---|
| Deployment mode | KServe Standard (not Knative) | KServe documents "Start with InferenceService"; Knative adds cold start and an activator we do not need | Knative serverless |
| Gateway | Istio, ambient mode | Istio's data plane is Envoy, so `ext_proc` and the endpoint picker still work, and it adds east-west mTLS | Envoy Gateway (no mesh), Traefik (no `ext_proc`, so no cache-aware routing) |
| Policy layer | Kuadrant | `TokenRateLimitPolicy` reads `usage.total_tokens` from OpenAI-compatible responses; runs on both Istio and Envoy Gateway, so the gateway choice stays reversible | Envoy AI Gateway, which requires Envoy Gateway as its base |
| Identity | Keycloak, dev mode | Issues JWTs; group claims drive per-tier quota; the realm is imported from git | API keys only |
| Local engine | `llama.cpp` server, arm64 | Multi-arch image verified; OpenAI-compatible | vLLM under emulation (no AVX), vLLM built from source (phase 3 spike at most) |
| Cloud engine | vLLM | Continuous batching, paged attention, prefix cache, and the KV-cache events the endpoint picker needs | llama.cpp on GPU |

## 7. The engine contract

Any engine that satisfies these four items can be plugged in. This is the
central abstraction of the repository.

| Item | Requirement |
|---|---|
| API | `GET /v1/models`; `POST /v1/chat/completions` with and without streaming; `POST /v1/completions` |
| Health | Readiness turns true only after weights are loaded, not when the process starts |
| Metrics | Prometheus format on `/metrics`, exposing at least: requests running, requests waiting, input tokens, output tokens |
| Traces | Accepts an OTLP endpoint through environment variables |

llama.cpp and vLLM name their metrics differently. Rather than writing two sets
of dashboards, Prometheus recording rules normalise both into one namespace:

```
llmstack:requests_waiting
llmstack:requests_running
llmstack:ttft_seconds
llmstack:tokens_out_total
```

Dashboards read only the `llmstack:` prefix. Swapping engines changes one
recording-rules file.

The exact upstream metric names are deliberately not written here. They will be
read from a running `/metrics` endpoint of each engine during implementation and
recorded in an ADR with the date they were read.

Known gap, by design: prefix cache hit rate and KV cache utilisation exist only
in vLLM. The endpoint picker learns cache state from ZMQ events emitted by vLLM
pods, which llama.cpp does not emit. Cache-aware routing therefore starts in
phase 2, and the phase 1 dashboard states this in place of an empty panel.

## 8. Observability contract

Every panel answers an operational question. Panels that answer nothing are not
built.

| Question | Signal |
|---|---|
| Do users experience it as slow? | TTFT p50 and p95, inter-token latency p95 |
| Are we about to saturate? | requests waiting, requests running |
| Are we wasting money? | output tokens per second, cache hit rate (phase 2 on) |
| Did the last change make it worse? | the same three, compared against a committed benchmark run |

Metrics are scraped from `/metrics` by Prometheus. Traces are pushed over OTLP
to an OpenTelemetry Collector. These are two independent paths.

OpenTelemetry GenAI semantic conventions are used but not hard-coded: attribute
names live in the Collector configuration, because those conventions were still
experimental as of March 2026.

## 9. Security model

| Concern | Mechanism | Note |
|---|---|---|
| Who may call | Kuadrant `AuthPolicy`, JWT verified against Keycloak JWKS | No database call on the request path. The gateway verifies the signature itself |
| What they may call | JWT claim based authorisation | Group claim decides which models are reachable |
| How much they may use | Kuadrant `TokenRateLimitPolicy` | Counted in tokens, not requests. Counters in Limitador |
| Traffic inside the cluster | Istio ambient mTLS | ztunnel per node rather than a sidecar per pod |
| Credentials for model download | Kubernetes Secret locally; external-secrets or workload identity in cloud | The `HF_TOKEN` never enters git |

Keycloak dev mode keeps state in memory. The realm is therefore defined by a
`realm-export.json` file in git and imported at start. Clicking through the
Keycloak UI is not a supported way to change configuration, because it cannot be
reproduced.

## 10. Autoscaling

- KEDA scales on queue depth, using the OpenTelemetry add-on, not on CPU. GPU
  can be saturated while CPU looks idle.
- The default overlay sets `minReplicas: 1`. Scale to zero is not the default,
  because cold start on a large model is minutes.
- A separate `cost-saving` overlay demonstrates scale to zero, and its cold
  start cost is measured and committed like any other number.

## 11. High availability and recovery

| Failure | Response | LLM-specific detail |
|---|---|---|
| One pod lost | 2 replicas, PodDisruptionBudget `minAvailable: 1` | On GPU nodes the second replica is expensive; the cloud overlay documents the trade-off |
| Rolling update | Long `terminationGracePeriodSeconds`, `preStop` delay | Streaming responses last tens of seconds and must not be cut mid-answer |
| Overload | Engine concurrency limit, 429 from the rate limit policy | Refuse early rather than degrade everything |
| Slow response | Raised HTTPRoute timeouts | Default gateway timeouts are too short for streaming |
| Engine unavailable | Failover route to a smaller model | A weaker answer beats no answer |
| Namespace lost | Argo CD re-syncs from git | Recovery time is dominated by model download, not by applying YAML |

Recovery is exercised, not assumed: a single task deletes the namespace, lets
Argo CD rebuild, and measures time to the first successful token. That number is
the real recovery time objective and it is committed to `bench/results/`.

## 12. Benchmark method

Tool: vLLM's `benchmark_serving` in its OpenAI-chat mode. It only needs an
OpenAI-compatible endpoint, so the same tool measures llama.cpp locally and vLLM
in the cloud. That is what makes phase comparisons fair.

Scenarios:

1. Short prompt, short output. Latency sensitivity.
2. Long prompt (about 8k tokens), short output. Prefill-heavy.
3. Many requests sharing a prompt prefix. Shows what cache-aware routing buys in
   phase 3.
4. Concurrency sweep at 1, 4, 16, 64. Finds the saturation point.

Every run records date, hardware, image digests, and engine arguments. Result
directories are named by date and hardware. A number without a date is treated
as invalid in this repository.

## 13. CI and CD

CI on GitHub Actions, on `ubuntu-24.04-arm`, so continuous integration runs the
same architecture as the local Mac:

1. Lint: build every overlay, validate against CRD schemas.
2. Policy: reject manifests without resource limits, reject floating image tags,
   require labels.
3. Build: multi-architecture image build for any runtime image this repo owns.
4. Supply chain: sign images, generate an SBOM and attestation.
5. Smoke test: create a kind cluster, deploy a very small model, call
   `/v1/chat/completions`, assert the OpenAI response contract.
6. Dependency updates: automated pull requests when pinned versions change.

Runners have 4 vCPU and no GPU. So the CI overlay uses a model of roughly 0.5B
parameters, and any test that needs a GPU runs as a Job inside the cloud cluster
instead.

CD is pull based, with Argo CD in the cluster. A push-based pipeline would need
cluster credentials stored in GitHub, and it could not reach a kind cluster on a
laptop at all. Sync waves replace manual ordering:

| Wave | Contents |
|---|---|
| 0 | Gateway API CRDs, cert-manager |
| 1 | Istio, Keycloak, Redis |
| 2 | KServe, Kuadrant |
| 3 | Prometheus, Grafana, OTel Collector, KEDA |
| 4 | ServingRuntime, InferenceService, AuthPolicy, TokenRateLimitPolicy, HTTPRoute |

All images are pinned by digest.

## 14. Repository structure

```
Taskfile.yml            single entry point for local operations
docs/
  01..08-why-*.md       one short document per layer: what breaks without it
  adr/                  decisions, with the evidence that supported them
  runbooks/             what to do when something fails
  superpowers/specs/    this document
platform/
  00-cert-manager/  10-istio/    15-keycloak/  20-kserve/
  25-kuadrant/      30-observability/          40-keda/
security/oidc/          AuthPolicy and TokenRateLimitPolicy
runtimes/
  llamacpp-arm64/       ServingRuntime for local
  vllm/                 ServingRuntime for cloud
models/
  ornith-9b/base/       InferenceService, environment agnostic
  ornith-9b/overlays/   local, ci, gpu-single, gpu-multi
clusters/
  local-kind/           Argo CD app-of-apps and sync waves
  gpu-cloud/
bench/scenarios/        workload definitions
bench/results/          measurements, one directory per date and machine
tests/smoke/            end-to-end checks
tests/contract/         OpenAI API contract checks
policy/                 admission policies, shared by CI and cluster
.github/workflows/      CI
```

Four rules the structure enforces:

1. The model is a variable. Changing models touches one directory under
   `models/`, nothing else.
2. Kustomize for manifests this repository owns; Helm only for upstream charts.
   No templating on top of templating.
3. `platform/` is numbered because install order carries meaning. The numbers
   increase with the Argo CD sync wave, so reading the directory listing gives
   the install order.
4. Benchmark results are named by date and hardware.

## 15. Phases

| Phase | Where | Model | KServe resource | New capability |
|---|---|---|---|---|
| 1 | kind on M4 | Ornith-1.0-9B, quantised GGUF | `InferenceService` + custom `ServingRuntime` | The whole loop: identity, quota, telemetry, autoscaling, HA drill, CI, benchmark |
| 2 | one GPU node, vendor neutral | Ornith-1.0-9B, bf16 | `InferenceService` + vLLM runtime | Real vLLM metrics, prefix caching, measured TTFT and inter-token latency |
| 3 | several GPU nodes | a large open-weight model | `LLMInferenceService` + llm-d | Cache-aware routing, prefill/decode separation, multi-node parallelism |

Phase 1 is complete when all of the following hold:

1. `task local:up` takes an empty machine to a ready service.
2. A JWT obtained from Keycloak returns a streamed chat completion.
3. A request without a JWT is rejected with 401.
4. Exceeding the token quota returns 429.
5. Grafana shows TTFT p95 and requests waiting from real traffic.
6. Under load, KEDA scales the predictor from 1 to 2 replicas, with evidence.
7. Draining a node keeps the service available, with the PodDisruptionBudget
   holding.
8. The recovery drill runs and its recovery time is committed.
9. CI is green on an arm64 runner.

## 16. Risks

| # | Risk | Fallback |
|---|---|---|
| R1 | KServe's storage initialiser may not fetch a single GGUF file from Hugging Face | Own init container using the Hugging Face CLI with a filename filter |
| R2 | A custom `ServingRuntime` may not match how KServe passes arguments and probes | Use a fully custom predictor via `spec.predictor.containers` |
| R3 | Keycloak issuer may not match the JWKS URL | Solved by serving both through one hostname |
| R4 | 32 GB may be tight with Istio, Kuadrant, Keycloak, Prometheus, Grafana, KEDA, and a 6 GB model | Measure real memory and commit the number; reduce Prometheus retention; fall back to a 3B model locally |
| R5 | CI runners have 4 vCPU | CI overlay uses a 0.5B model |
| R6 | CRD conflicts between Istio and Gateway API. llm-d additionally states that a pre-existing Istio install conflicts with its gateway | Install Gateway API CRDs first, pin versions, and re-read llm-d prerequisites before phase 3 |
| R7 | Istio's Gateway API Inference Extension support is alpha and its documented example uses sidecar mode, not ambient | Kuadrant runs on both gateways, so the policy layer survives a gateway change. Re-decide at the start of phase 3 with a new ADR |
| R8 | Minimum Kubernetes and component versions are inconsistent across upstream documentation pages | Pin versions from the release notes of the exact version installed, and record the date they were read |

## 17. Evidence log

Facts verified at their source. Anything not on this list is treated as
unverified until it is.

| Date | Fact | Source |
|---|---|---|
| 2026-08-17 | `kserve/huggingfaceserver:latest` and `:v0.20.0` publish `linux/amd64` only | Docker Hub registry manifest query |
| 2026-08-17 | `ghcr.io/ggml-org/llama.cpp:server` publishes `linux/amd64`, `linux/arm64`, `linux/s390x` | GHCR registry manifest query |
| 2026-08-17 | `quay.io/keycloak/keycloak:latest` publishes `linux/amd64`, `linux/arm64`, `linux/ppc64le` | quay.io registry manifest query |
| 2026-08-17 | KServe v0.20.0 released 2026-08-06; v0.17 released 2026-03-13 and introduced production `LLMInferenceService` built on llm-d | kserve/kserve releases page, KServe v0.17 blog |
| 2026-08-17 | KServe names Envoy Gateway as the default gateway provider for `LLMInferenceService`; Istio is also named as a provider | KServe llmisvc dependencies and control-plane architecture pages |
| 2026-08-17 | The endpoint picker tracks KV cache blocks via ZMQ events from vLLM pods; prefix cache scorer weight 2.0, load-aware 1.0 | KServe control-plane architecture page |
| 2026-08-17 | The inference extension works through Envoy's `ext_proc` filter, so it upgrades ext-proc capable gateways | Gateway API Inference Extension site |
| 2026-08-17 | Istio's inference extension support uses `v1alpha1` CRDs, experimental pilot flags, and a sidecar profile example | Istio Gateway API Inference Extension task |
| 2026-08-17 | "Envoy AI Gateway is built on top of Envoy Gateway"; requires Envoy Gateway 1.8.1+ and Kubernetes 1.32+ | Envoy AI Gateway prerequisites |
| 2026-08-17 | Kuadrant `TokenRateLimitPolicy` extracts `usage.total_tokens` from OpenAI-compatible backends including vLLM and KServe; installs on Istio or Envoy Gateway; core policies are at v1 | Kuadrant documentation and v1 blog |
| 2026-08-17 | ModelMesh serving repository archived 2026-04-14 | GitHub search result for kserve/modelmesh-serving |
| 2026-08-17 | llm-d accepted into the CNCF Sandbox on 2026-03-12 | CNCF blog |
| 2026-08-17 | Ornith-1.0-9B is MIT licensed, about 19 GB in bf16, 262144 token context, with quantised builds for llama.cpp and Ollama | Hugging Face model card |
| 2026-08-17 | Rosetta 2 does not implement AVX, AVX2, or AVX512 | docker/for-mac issue 7137, Apple developer forums |
| 2026-08-17 | GitHub arm64 hosted runners are generally available, including private repositories since 2026-01-29 | GitHub changelog |

Numbers quoted from vendor blogs and not independently verified, kept separate
on purpose: the reported 3x output tokens per second and 2x lower time to first
token from cache-aware routing on Llama 3.1 70B with four MI300X GPUs; Istio
ambient footprint figures; engine-to-engine throughput comparisons between vLLM,
SGLang, and TensorRT-LLM. These are treated as claims to test in phase 2 and
phase 3, not as facts.
