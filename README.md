# llm-serving-stack

A production-shaped LLM inference platform on Kubernetes, built to be understood
layer by layer. It runs on a local Apple Silicon Mac first, then on GPU nodes,
without changing the control plane or the repository shape.

Status: **run for the first time on 2026-08-19, and partly proven.** Until that
day this line read "code-complete, unrun", and everything below it was written
and statically checked but never observed. A cluster has now run it.

All thirteen layers came up on a 3-node `kind` cluster and the service answered a
real request: HTTP 401 without a token, HTTP 200 with a JWT from Keycloak, and a
streaming chat completion. `docs/deployment-walkthrough.md` is the account, with
every number dated, and `tools/step-up.sh` is how to repeat it one layer at a
time.

**Two of the nine phase 1 acceptance criteria now hold. Seven do not, and they
are not held up by the same thing.** Criterion 1 has not been settled because the
walkthrough used the imperative path, so `task local:up` itself is still
unobserved. The rest are untested rather than failing. The table under
"What is unproven" says which is which.

Running it found seven defects that four separate static review passes had all
missed: a file mode that broke `task local:up` at its second command, a bash 3.2
array expansion that killed the KServe install, two selectors naming a label
Istio removed in 1.24, and three tests that passed while the thing they named was
broken. Each is recorded where it was found.

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

The single most important section of this file. One run on 2026-08-19 settled two
of the nine criteria and a handful of the markers below; the rest are still owed,
so what follows is not a formality.

### The nine phase 1 acceptance criteria

Two hold as of 2026-08-19. Settle the rest with `bats tests/` against a live
cluster, then record the result and the date here.

| # | Criterion | Status | Settle it |
|---|---|---|---|
| 1 | `task local:up` takes an empty machine to a ready service | **fails 2026-08-20**, seven defects found and fixed, re-run owed | `task local:down && task local:up` |
| 2 | A JWT obtained from Keycloak returns a streamed chat completion | **HOLDS 2026-08-19** | `bats tests/smoke/03-identity.bats tests/contract/01-openai-api.bats` |
| 3 | A request without a JWT is rejected with 401 | **HOLDS 2026-08-19** | `bats tests/smoke/06-auth-quota.bats` |
| 4 | Exceeding the token quota returns 429 | untested | `bats tests/smoke/06-auth-quota.bats` |
| 5 | Grafana shows TTFT p95 and requests waiting from real traffic | untested | `bats tests/smoke/05-observability.bats` |
| 6 | Under load, KEDA scales the predictor above its floor of 2 replicas, to 3, with evidence | untested | `bats tests/smoke/07-autoscaling.bats` |
| 7 | Draining a node keeps the service available, PDB holding | untested | `bats tests/smoke/08-availability.bats` |
| 8 | The recovery drill runs and its recovery time is committed | untested | `task drill:recovery` |
| 9 | CI is green on an arm64 runner | untested | push this branch, read `.github/workflows/ci.yml`'s result |

Criterion 1 is the one to read carefully. It was run for the first time on
2026-08-20, on a cluster created from empty, and it failed. Seven defects came
out of that one run, and none of them was visible from the imperative path.
`docs/deployment-walkthrough.md`, section "The pull-based path", is the account.
Two of the seven are worth naming here:

- The old final command of `task local:up` waited only on an Application's
  health status, and an Application that failed to read its git path still
  reports `Healthy`. It exited 0 in one second on a cluster where nothing had
  been deployed. `clusters/local-kind/wait-for-sync.sh` replaces it.
- Argo CD applies client-side by default, which writes each manifest into a
  262144-byte annotation. Five of the fifteen charts here ship CRDs larger than
  that, so KServe, Kyverno, Kuadrant, the observability stack, and KEDA all
  failed. `helm install` never writes that annotation, which is why the
  imperative path installs the same charts without complaint.

All seven fixes are in. The re-run that would settle this criterion is owed. Criterion 2 is met with one caveat recorded in
`docs/deployment-walkthrough.md`: `tests/contract/01-openai-api.bats` passes 4 of
5, and the failing one is about this model being a reasoning model, not about the
API contract.

### Measurements still owed

Every owed number is marked at the place it belongs, not in a central list, so
it cannot drift away from the claim it qualifies. Find them all with:

```
git ls-files -z | xargs -0 grep -n '\*\*Unmeasured (20'
```

which returned **15** on 2026-08-19, across 12 files. Each marker names the
command that settles it.

It returned 14 earlier the same day. The twelfth file is
`docs/deployment-walkthrough.md`, and its marker owes the one number the run could
not produce: the `max_tokens` at which this model emits `content` rather than only
`reasoning_content`. 512 was not enough.

The command counts tracked files, and that is the point. It used to be
`grep -rn ... --exclude-dir=.git --exclude-dir=docs/superpowers`, which did not
work: `--exclude-dir` matches a directory's basename, never a path, so
`docs/superpowers` excluded nothing. That form also missed `.superpowers/` and
`docs/UNVERIFIED.md`, both ignored by `.gitignore`. Run verbatim on 2026-08-19
it returned 52 rather than 14. The published number was always the tracked-file
number; only the command was wrong. A fresh clone hides this, because a clone
has none of those three paths.

`Untried` is the companion marker, for a mechanism nobody has exercised rather
than a number nobody has measured. Find those with:

```
git ls-files -z | xargs -0 grep -nE 'Untried \(20[0-9]{2}-'
```

which returned **13** on 2026-08-20, across eight files: this one,
`docs/deployment-walkthrough.md`, `platform/10-istio/telemetry.yaml`,
`platform/12-kyverno/install.sh`, `tests/contract/01-openai-api.bats`, two in
`platform/30-observability/tempo.yaml`, two in
`tests/smoke/05-observability.bats`, and four in `.github/workflows/ci.yml`.

It moved three times across two days, and every move is the shape this is
supposed to take rather than a regression. From 10 to 11 when `actions/checkout`
went v4 to v7, because v7 needs the node24 runtime and no local command can prove
these runners have it. To 12 when the stack was first run layer by layer, because
the CoreDNS manifest that run produced had only ever been applied by hand. To 13
on 2026-08-20, when a review pass replaced two claims that had been asserted
without a mutation to back them, in `tempo.yaml` and the contract suite.

The same two days RETIRED three markers that running settled, and one that was
simply wrong. `tempo.yaml` no longer wonders whether Tempo 3.0.3 starts, because
it does. `podmonitor.yaml` no longer wonders whether the gateway pod declares
port 15020 or whether Prometheus scrapes it, because both were observed; its
second marker had also contradicted `docs/deployment-walkthrough.md` outright,
and the walkthrough was right.

The count rising is the expected shape of this work, not a regression. Every
component added since 2026-08-19 has been written and never run, so each one
brings its own marker naming the command that would settle it.

A third marker form was introduced and retired on the same day, 2026-08-19, when
the stack was first run layer by layer on a real cluster:

```
git ls-files -z | xargs -0 grep -n '\*\*BLOCKED (20'
```

which returns **0**. `BLOCKED` is for something that was tried, failed, and is
understood: it carries the exact error and the upstream source lines that explain
it. It is deliberately not `Untried`, because trying it is what produced the
finding. The one instance was the model layer, and it lasted a few hours;
`models/ornith-9b/overlays/local/patch-resources.yaml` now carries the resolved
record instead. Keep the form available: it is the honest marker for a finding
that is understood but not yet fixed.

The date digits in that pattern are not decoration. Without them the pattern
matches the line that documents the marker form, `CLAUDE.md:199`, so it reports
14 instead of 13. It cited `CLAUDE.md:176` until 2026-08-20, which is a different
bullet in the same section: that line is the "a number without the date it was
measured is invalid" rule, not the marker form. A citation that resolves and does
not hold is the exact defect this section exists to warn about. The `Unmeasured` pattern above dodges the same trap a
different way, by requiring the `**` a real marker carries.

This paragraph said "reports 7" until 2026-08-19. That number was never
producible: dropping the digits can only ADD matches, so a number below the real
count was wrong in direction as well as in size. Re-measured by diffing the two
greps over tracked files, which shows exactly one added line.

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
