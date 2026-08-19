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

**None of the nine phase 1 acceptance criteria hold as of 2026-08-19, because
none has been executed.** This is not nine different failures; it is one fact
(no cluster has run) with nine consequences. They are listed in full under
"What is unproven" below.

Three kinds of gap appear in this repository, and they are not the same kind:

- **Unproven.** A number or outcome nobody has measured, because no cluster
  exists to measure it against. The manifest and the test are both believed
  correct; the measurement is owed.
- **Doubted.** A mechanism there is a specific, sourced, technical reason to
  believe does not work as designed, whether or not a cluster ever confirms
  it. There is one: cross-backend failover, recorded in
  [ADR 0007](docs/adr/0007-failover-not-expressible-in-gateway-api.md), which
  is withdrawn from phase 1 rather than pending.
- **Unverified by construction.** Phase 1's own acceptance bar, which cannot
  be met until the suite runs once, end to end.

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

## What is unproven

The single most important section of this file. This repository is
code-complete and unrun, so what follows is not a formality.

### The nine phase 1 acceptance criteria

None has been executed. Settle all nine at once with `bats tests/` against a
live cluster, then record the result and the date here.

| # | Criterion | Settle it |
|---|---|---|
| 1 | `task local:up` takes an empty machine to a ready service | `task local:down && task local:up` |
| 2 | A JWT obtained from Keycloak returns a streamed chat completion | `bats tests/smoke/03-identity.bats tests/contract/01-openai-api.bats` |
| 3 | A request without a JWT is rejected with 401 | `bats tests/smoke/06-auth-quota.bats` |
| 4 | Exceeding the token quota returns 429 | `bats tests/smoke/06-auth-quota.bats` |
| 5 | Grafana shows TTFT p95 and requests waiting from real traffic | `bats tests/smoke/05-observability.bats` |
| 6 | Under load, KEDA scales the predictor above its floor of 2 replicas, to 3, with evidence | `bats tests/smoke/07-autoscaling.bats` |
| 7 | Draining a node keeps the service available, PDB holding | `bats tests/smoke/08-availability.bats` |
| 8 | The recovery drill runs and its recovery time is committed | `task drill:recovery` |
| 9 | CI is green on an arm64 runner | push this branch, read `.github/workflows/ci.yml`'s result |

### Measurements still owed

Every owed number is marked at the place it belongs, not in a central list, so
it cannot drift away from the claim it qualifies. Find them all with:

```
grep -rn '\*\*Unmeasured (20' . --exclude-dir=.git --exclude-dir=docs/superpowers
```

which returned **14** on 2026-08-19, across 11 files. Each marker names the
command that settles it.

Two details in that pattern are deliberate, and both were found by running it
rather than by reasoning about it. It matches the marker form `**Unmeasured (`
rather than the bare phrase, so it does not count this paragraph or any other
prose that mentions the pattern it counts. And it requires a real date, `(20`,
so it skips the rule that defines the marker in `CLAUDE.md`, which is written
`(<date>)`.

### An accepted gap, not an owed measurement

llama.cpp emits no traces at all. The engine contract requires an OTLP traces
endpoint, and llama.cpp's server documentation mentions neither OTLP nor
OpenTelemetry.
[ADR 0005](docs/adr/0005-two-runtimes-one-control-plane.md), lines 58 to 64,
records this as a cost found while implementing and not anticipated when the
decision was taken. The OTel Collector is deployed anyway, with a receiver no
engine feeds. The practical effect is that time to first token cannot come
from spans, and is measured instead by the client-side prober in
`platform/30-observability/ttft-prober-cronjob.yaml`. Nothing is owed here
short of adding vLLM in phase 2.

## What is proven, and the sharp limit on it

Nothing that requires a cluster. What holds without one:

- Every `helm install --dry-run=client` and `helm template` this repository's
  install scripts and Argo CD Applications were checked against **renders
  without error**.
- Every `kustomize build` across every overlay renders without error.
- Every CRD field this repository's manifests use was confirmed against the
  pinned chart's own rendered schema, not memory.
- The real `kyverno` CLI confirms the admission policies reject exactly what
  `tests/smoke/11-policy.bats` asserts they reject (`policy/tests/`), and the
  fixtures were mutation-checked: reverting the policy under test makes the
  corresponding case fail.
- Every shell script parses under bash 3.2.57 (`/bin/bash -n`, the version
  macOS ships, which `shellcheck` alone does not stand in for).
- `actionlint` reports the CI workflow clean.
- **Every pinned image digest resolves to a `linux/arm64` image, and every tag
  written beside it belongs to that digest.** Checked 2026-08-19 against
  ghcr.io, quay.io, and Docker Hub over HTTPS, with no Docker daemon: for each
  entry the tag's index was fetched and the pinned digest confirmed as one of
  its children, then the digest's own config blob was read for its `os` and
  `architecture`. All five report `linux/arm64`. This is the substance of
  `tests/contract/03-images.bats`'s first test, which still cannot run here
  because `require_arm64` calls `docker buildx imagetools inspect`. The
  registry answered the same question by a different route. That is not the
  same as having run the test.

**A passing dry-run does not prove the rendered values are the intended ones.**
It proves the chart rendered. `CLAUDE.md`'s evidence rules record the two real
defects that survived several review rounds on this branch for exactly this
reason.

## Getting started

**Untried (2026-08-19): the commands below have never been run against a real
cluster.** They are what the manifests and scripts say should happen, not a
report of what was observed. Do not read the presence of these instructions
as a claim that they work; see "What is unproven" above.

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
test for the whole repository, and itself criterion 1 under "What is
unproven" above.

`task local:status` and `task drill:drain` remain stubs (`task --list-all`
shows every task; a stub prints what it would do rather than doing it).
Everything else above runs a real command, even though none has been run
against a live cluster yet.

`task chat` is the only human-facing way to reach the model here. It goes
through the gateway, so one command exercises the route, the `AuthPolicy`, and
the `TokenRateLimitPolicy`:

```bash
task chat -- "Explain sync waves in two sentences."
CLIENT=llm-tier-free task chat    # spend the free tier's budget and watch the 429
```
