# llm-serving-stack

A production-shaped LLM inference platform on Kubernetes, built to be understood
layer by layer. It runs on a local Apple Silicon Mac first, then on GPU nodes,
without changing the control plane or the repository shape.

Status: **code-complete, unrun** (checked 2026-08-19). Every manifest, script,
test, and policy for phase 1 is written and statically checked - `helm
install --dry-run=client`, `kustomize build`, CRD schemas read from the
pinned charts themselves, `bash -n` under bash 3.2.57, `bats --count`,
`actionlint`, and the real `kyverno` CLI. None of it has been observed
working against a live Kubernetes cluster: the machine building it cannot
spare the memory Docker needs to run `kind` alongside the rest of this stack.

**None of the nine phase 1 acceptance criteria (design spec, section 15) hold
as of 2026-08-19, because none has been executed.** This is not nine
different failures; it is one fact (no cluster has run) with nine
consequences. See [`docs/UNVERIFIED.md`](docs/UNVERIFIED.md) for the full,
reconciled account of what is unproven, what is unverified by construction,
and the one place this repository has a specific technical reason to doubt a
mechanism rather than merely lack a measurement of it (cross-backend
failover, `docs/adr/0007-failover-not-expressible-in-gateway-api.md`).

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

Both are recorded with dates in tracked documents. The first is
[ADR 0005](docs/adr/0005-two-runtimes-one-control-plane.md), which states the
`linux/amd64`-only constraint and what follows from it. The second is
[the recovery drill runbook](docs/runbooks/recovery-drill.md), which measures
the arrival of the first streamed chunk rather than `Ready`.

The fuller evidence log lives in `docs/superpowers/specs/`, which is a local
working document and is not in git.

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

**Untried (2026-08-19): the commands below have never been run against a real
cluster.** They are what the manifests and scripts say should happen, not a
report of what was observed. Do not read the presence of these instructions
as a claim that they work; see `docs/UNVERIFIED.md`.

Prerequisites: `kubectl`, `helm`, `kind`, `task`, `yq`, `jq`, `bats`,
`kustomize`, and Docker Desktop with at least 8 CPUs and 20 GiB of memory
allocated (`task preflight` checks all of this and fails with a specific
message if something is missing).

```bash
task preflight        # verify tools and Docker resources
task local:up         # kind cluster -> Argo CD -> every platform layer, in sync-wave order
task test:smoke       # tests/smoke: identity, quota, autoscaling, availability, gitops, policy...
task test:contract    # tests/contract: the engine contract, so engines stay swappable
task token            # obtain a JWT from Keycloak
task chat             # send one streaming chat completion
task bench            # run every benchmark scenario, write a dated result directory
task drill:recovery   # delete the llm namespace, let Argo CD rebuild it, measure recovery time
task local:down       # delete the cluster
```

`task local:up` is the single entry point Task 12 built: it creates the
`kind` cluster, installs Argo CD (the only imperative step), and applies
`clusters/local-kind/root-app.yaml`, which brings in every other layer as an
Argo CD Application. Reproducing the whole stack from an empty machine is
exactly `task local:down && task local:up && bats tests/` - the acceptance
test for the whole repository, and itself one of the entries in
`docs/UNVERIFIED.md`.

`task token`, `task chat`, `task local:status`, and `task drill:drain` remain
stubs (`task --list-all` shows every task; a stub prints what it would do
rather than doing it). Everything else above runs a real command even though
none has been run against a live cluster yet.
