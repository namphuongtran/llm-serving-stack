# llm-serving-stack

A production-shaped LLM inference platform on Kubernetes, built to be understood
layer by layer. It runs on a local Apple Silicon Mac first, then on GPU nodes,
without changing the control plane or the repository shape.

Status: **scaffolding**. Directories and decisions are in place. Manifests are
not written yet.

## What this is

An answer to a specific question: what is actually missing when a tutorial calls
a model deployment "production ready"? The usual walkthrough gets a model
answering on localhost. It has no identity, no quota, no telemetry, no
autoscaling that means anything, no failure plan, and no measurements.

This repository adds those, one layer at a time, and records why each layer
exists.

## The stack

| Layer | Choice |
|---|---|
| Entry | Istio, ambient mode, Gateway API |
| Policy | Kuadrant: `AuthPolicy`, `TokenRateLimitPolicy` |
| Identity | Keycloak, dev mode, realm imported from git |
| Control plane | KServe, Standard deployment mode |
| Engine | llama.cpp (arm64) locally, vLLM on GPU |
| Scaling | KEDA on queue depth |
| Telemetry | Prometheus, Grafana, OpenTelemetry Collector |
| Delivery | GitHub Actions for CI, Argo CD for CD |

Every choice has an ADR in [`docs/adr/`](docs/adr/) with the evidence behind it.

## Phases

| Phase | Where | Model | New capability |
|---|---|---|---|
| 1 | kind on Apple M4, no GPU | Ornith-1.0-9B, quantised | The whole loop: identity, quota, telemetry, autoscaling, HA drill, CI, benchmark |
| 2 | one GPU node | Ornith-1.0-9B, bf16 | Real vLLM metrics, prefix caching, honest latency numbers |
| 3 | several GPU nodes | a large open-weight model | Cache-aware routing, prefill/decode separation, multi-node parallelism |

Phase 1 does not ship a weaker version of phase 2. It ships every layer except
the GPU, which is what makes the later phases a change of overlay rather than a
rewrite.

## Two constraints that shaped everything

1. `kserve/huggingfaceserver` publishes `linux/amd64` only, and Rosetta 2 does
   not implement AVX, so an emulated x86 vLLM cannot run on Apple Silicon.
   Therefore the local engine is llama.cpp, and everything above the engine is
   engine independent.
2. Recovery time for an LLM service is dominated by model download, not by
   applying YAML. So the recovery drill measures time to the first token, not
   time to `Ready`.

Both are verified with dates in the [design spec](docs/superpowers/specs/2026-08-17-llm-serving-stack-design.md).

## Layout

```
docs/          why each layer exists, decisions, runbooks, the design spec
platform/      cluster components, numbered by install order
security/      authentication and token quota policies
runtimes/      one ServingRuntime per engine
models/        one directory per model; the model is a variable
clusters/      Argo CD composition per environment
bench/         benchmark scenarios and dated results
tests/         smoke tests and engine contract tests
policy/        admission policies, shared by CI and cluster
```

## Rules this repository follows

- A number without the date it was measured is invalid. Re-measure instead of
  quoting forward.
- Images are pinned by digest, never by a floating tag.
- Configuration lives in git. Anything clicked in a web UI cannot be reproduced
  and does not count.
- Upstream version numbers come from the release notes of the exact version
  installed, recorded with the date they were read.

## Getting started

Not yet. `Taskfile.yml` lists the intended entry points; they are stubs while the
scaffolding is in place.
