# Unverified

This repository is code-complete and unrun. No `kind` cluster was created at
any point across all fourteen tasks of the phase 1 plan (the machine building
it cannot spare the memory Docker needs alongside the rest of this stack).
Every manifest, script, test, and policy is written and statically checked
- `helm install --dry-run=client`, `kustomize build`, `bash -n` under bash
3.2.57, `bats --count`, `actionlint`, and the real `kyverno` CLI where those
tools need no cluster to run - but nothing here has been observed working
against a live Kubernetes API server. This document is the one place that
says so plainly, rather than leaving a reader to infer it from an absent
result directory or a skipped step buried in a task report.

Three kinds of claim below are not the same kind of gap, and this document
keeps them apart:

- **Unproven** - a number or an outcome nobody has measured yet, because no
  cluster exists to measure it against. The manifest and the test are both
  believed correct; the measurement is simply owed.
- **Doubted** - a mechanism this repository has a specific, sourced, technical
  reason to believe does not work as designed, independent of whether a
  cluster ever confirms it.
- **Unverified by construction** - phase 1's own acceptance bar, which by
  definition cannot be met until the suite runs once, end to end.

## Withdrawn: cross-backend failover

Not a pending measurement. This capability does not exist in phase 1, on
purpose, for a reason established without a cluster and confirmed by a
second, independent defect.

The design spec (section 11) and the implementation plan specified failover
to a smaller fallback model via a `weight: 0` `backendRef` on the `ornith-9b`
`HTTPRoute`, reached through Envoy retries. **ADR 0007**
(`docs/adr/0007-failover-not-expressible-in-gateway-api.md`) records two
independent defects, found by reading Envoy's own issue tracker and Istio's
reference documentation, not by running a cluster:

1. Envoy selects among weighted clusters once, at the initial route match.
   Retries are attempted against a different host **inside the already
   selected cluster**, never against a different cluster (Envoy issue 5891,
   closed without the behaviour changing). A `weight: 0` backend therefore
   has zero probability of ever being selected, on the first attempt or any
   retry.
2. The retry policy attached via `spec.gateways: [istio-system/llm]`, which
   Istio resolves against its own `networking.istio.io` `Gateway` kind, not
   the Gateway API `gateway.networking.k8s.io` `Gateway` this repository
   actually has under that name. The policy most likely never attached to
   anything.

ADR 0007's decision has landed in code, not only in the ADR:
`models/ornith-9b/overlays/local/retry-policy.yaml` is deleted, the
`ornith-9b-openai` `HTTPRoute` (renamed from `ornith-9b` on 2026-08-19, so it
cannot collide with the one KServe generates under that name) carries only the
primary backend (no `weight`, no second `backendRef`), and `tests/smoke/08-availability.bats`'s "the endpoint
still answers when the primary has no replicas" test is `skip`ped with ADR
0007 named as the reason - not deleted, not left failing. The
`fallback-small` `InferenceService` is kept (it is independently useful, and
Task 13's CI overlay reuses its model pin); it is simply no longer wired to
the gateway as a fallback. `docs/runbooks/node-drain.md` explains how to
reach it directly (by port-forward) instead of through a route that does not
exist.

There is nothing left to settle here. Genuine cross-backend failover would
need an Envoy-native construct outside Gateway API (an aggregate cluster via
`EnvoyFilter`), which is a real future project, not a pending measurement on
the current one.

## Known engine-contract gap: llama.cpp emits no traces

Not a doubt, and not unmeasured - a documented, accepted gap in what phase 1
delivers. The engine contract (design spec, section 7) requires an OTLP
traces endpoint as its fourth item. llama.cpp's own server documentation
contains no mention of OTLP or OpenTelemetry (checked 2026-08-19: see
`docs/adr/0005-two-runtimes-one-control-plane.md` and
`docs/adr/0006-metric-normalisation.md`). The OTel Collector
(`platform/30-observability/otel-collector.yaml`) is deployed and configured
regardless, with an `otlp` receiver that has no producer feeding it in phase
1 - `docs/adr/0005`'s own text: "Phase 1 therefore runs with a trace pipeline
that no engine feeds." Consequence: time-to-first-token cannot be derived
from spans and is measured instead by the client-side prober
(`platform/30-observability/ttft-prober-cronjob.yaml`). This is accepted, not
owed; there is nothing to "settle" here short of adding vLLM in phase 2,
which does emit traces.

## Unverified by construction: the nine phase 1 acceptance criteria

Design spec, section 15. None has been executed, because no cluster exists.
Settle all nine at once: `bats tests/` against a live cluster, then record
the result and the date in `README.md`.

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

## Unproven: every dated measurement still owed

Every dated `> **Unmeasured` marker elsewhere in this repository, reconciled
by

```
grep -rn "Unmeasured (" . --exclude-dir=.git \
  | grep -v docs/UNVERIFIED.md \
  | grep -v docs/superpowers/specs/ \
  | grep -v CLAUDE.md \
  | wc -l
```

which printed **14** when it was last run, on 2026-08-19, matching the 14 rows
below (the same 14 file:line pairs).

Three exclusions, each for its own reason, all of them checked on 2026-08-19:

- **This file.** Its own references to the marker text in prose would inflate
  the number every time it mentions the pattern it is counting.
- **`docs/superpowers/specs/`.** A design document records markers about a
  plan, not claims this repository makes about itself.
  `2026-08-19-first-run-measurement-design.md` carries three, and it is
  superseded, so none of the three is owed.
- **`CLAUDE.md`.** Its line 146 is the rule that defines the marker
  (`> **Unmeasured (<date>):**`), not a marker. Without this exclusion the
  command counts the instruction as one of the things it instructs about.

Each row below
names the file it lives in and the command that would settle it; most share
the same root
cause (no cluster exists in this authoring pass), so it is not repeated in
every row.

| Where | What is owed | Settle it |
|---|---|---|
| `bench/results/README.md:12` | The first full four-scenario benchmark on `ornith-9b`/llama.cpp | `task bench` |
| `docs/02-why-kserve.md:32` | Cold-start wall-clock time, `cost-saving` overlay, replica count 0 to first response | `kustomize build models/ornith-9b/overlays/cost-saving \| kubectl apply -f -`, then time a request per the file's own script |
| `docs/03-why-istio.md:44` | Resident memory of `istiod` and `ztunnel` | `kubectl -n istio-system top pod --no-headers` |
| `docs/03-why-istio.md:57` | An operating-experience observation, not a number - written from running the installer, not from its manifests | Run `platform/10-istio/install.sh` against a real cluster and write what surprised |
| `docs/04-why-kuadrant.md:53` | `usage.total_tokens` for two requests identical except `max_tokens` | Both `curl` commands quoted in the file, against a live `ornith-9b` and a token |
| `docs/05-why-keycloak.md:39` | Resident memory of the Keycloak pod | `kubectl -n llm top pod -l app=keycloak` |
| `docs/05-why-keycloak.md:50` | Whether the realm survives a pod restart | `kubectl -n llm rollout restart deploy/keycloak && kubectl -n llm rollout status deploy/keycloak --timeout=5m && bats tests/smoke/03-identity.bats` |
| `docs/06-why-otel.md:63` | Predictor CPU usage while saturated, next to queue depth at the same moment | `kubectl -n llm top pod -l serving.kserve.io/inferenceservice=ornith-9b` alongside a `llmstack:requests_waiting` Prometheus query, under sustained load |
| `docs/07-why-gitops.md:38` | Combined memory footprint of the Argo CD components | `kubectl -n argocd top pod --no-headers` |
| `docs/07-why-gitops.md:78` | Wall-clock time of a full `task local:down && task local:up` rebuild, proving reproducibility (Task 12 step 6) | `task local:down && task local:up && bats tests/` |
| `docs/08-why-llm-d.md:26` | Throughput/TTFT difference between the shared-prefix and short-prompt scenarios, single replica | `task bench` (scenarios `03-shared-prefix.json`, `01-short.json`) |
| `docs/adr/0006-metric-normalisation.md:120` | Whether the `llamacpp:*` metric names are actually present, unrenamed, on a live `/metrics` endpoint | `kubectl -n llm exec <predictor pod> -c kserve-container -- wget -qO- http://127.0.0.1:8080/metrics \| grep -E '^# (HELP\|TYPE)' \| sort` |
| `docs/runbooks/node-drain.md:75` | Memory footprint of two `ornith-9b-predictor` replicas resident together | `kubectl -n llm top pod -l serving.kserve.io/inferenceservice=ornith-9b` |
| `docs/runbooks/recovery-drill.md:31` | The recovery drill's own time-to-first-token number. The script measures the arrival of the first streamed `data:` chunk (fixed 2026-08-19; it previously timed a `GET /v1/models` poll and recorded it under that name) | `task drill:recovery` (runs `bench/recovery-drill.sh`) |

## CI coverage, changed 2026-08-19, and still unobserved

`.github/workflows/ci.yml` gained a fourth job and two more suites on
2026-08-19. See `docs/superpowers/specs/2026-08-19-ci-coverage-design.md`.

**None of it has run yet.** The workflow was edited, `actionlint` reports it
clean, and no push has exercised it. A clean `actionlint` says the YAML is
well formed. It says nothing about whether the jobs pass.

Where each suite runs after the change:

| Suite | Runs in | Before 2026-08-19 |
|---|---|---|
| `00-cluster` | `smoke` | nowhere |
| `01-wave0`, `02-gateway`, `03-identity`, `04-kserve`, `06-auth-quota` | `smoke` | `smoke` |
| `11-policy` | `smoke` | nowhere |
| `05-observability` | `observability` | nowhere |
| `tests/contract/` | `smoke` and `observability` | `smoke` |
| `07-autoscaling`, `08-availability`, `09-bench`, `12-recovery`, `10-gitops` | nowhere | nowhere |

Four things this change introduces that no cluster has tested:

1. **Whether the CI model overlay survives live admission.** Kyverno is now
   installed before the model deploys, so `policy/`'s three rules guard a real
   namespace for the first time. Settle it by reading the `smoke` job's
   Install platform and Deploy the CI model steps.
2. **Whether `kubectl wait --for=condition=Ready clusterpolicy` is the right
   wait.** `platform/12-kyverno/install.sh` uses it. The CRD in chart 3.8.2
   has `status.conditions`, confirmed by reading the rendered chart, but the
   condition's type string was not read at any source. If it is wrong the
   install times out, which is the correct failure.
3. **Whether the `observability` job fits a `ubuntu-24.04-arm` runner.**
   `.github/workflows/ci.yml` records that kube-prometheus-stack plus KEDA
   plus two replicas of the 0.5B model did not. This job has one replica and
   no KEDA.
4. **Whether llama.cpp exposes its counters before its first request.**
   `tests/smoke/05-observability.bats` asserts three `llamacpp:*` series
   exist. The job runs `tests/contract/` first to generate traffic, but
   whether that is necessary or sufficient is unobserved.

## Predicted defect: `tests/smoke/10-gitops.bats` and `root-app`

Found by reading, on 2026-08-19. Not fixed, and not worked around.

`tests/smoke/10-gitops.bats` second test compares two counts. It counts
Applications carrying an `argocd.argoproj.io/sync-wave` annotation, and it
counts all Applications in namespace `argocd`, and asserts the two are equal.

All 15 files in `clusters/local-kind/apps/` carry a sync wave, confirmed with
`yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"'` over the
directory on 2026-08-19. `clusters/local-kind/root-app.yaml` does not, and
`task local:up` applies it into namespace `argocd`, where it is a sixteenth
Application.

So the test is predicted to compare 15 against 16 and fail. It has never run
anywhere, so nobody has seen it.

> **Untried (2026-08-19):** the prediction itself. Settle it with `bats
> tests/smoke/10-gitops.bats` against a cluster built by `task local:up`.

Two ways to resolve it once someone can run it, and the choice is a real one,
not a formality. Either `root-app` gains a sync wave, which is harmless but
meaningless because nothing orders `root-app` against anything. Or the test
narrows to the Applications that `root-app` manages. This document records the
finding; it does not pick.

The new lint check, `clusters/local-kind/check-sync-waves.sh`, deliberately
covers `apps/` only, and its own comments say so. It is not a fix for this. It
checks a different thing: the files in git, rather than the objects in a
cluster.

## What is proven, and the sharp limit on it

Nothing that requires a cluster. What holds without one:

- Every `helm install --dry-run=client` and `helm template` this repository's
  install scripts and Argo CD Applications were checked against **renders
  without error**.
- Every `kustomize build` across every overlay renders without error.
- Every CRD field this repository's manifests use was confirmed against the
  pinned chart's own rendered schema, not memory.
- The real `kyverno` CLI confirms the three admission policies reject exactly
  what `tests/smoke/11-policy.bats` asserts they reject (`policy/tests/`), and
  the fixtures there were mutation-checked: reverting the policy under test
  makes the corresponding case fail.
- Every shell script parses under bash 3.2.57 (`/bin/bash -n`, the version
  macOS ships, which `shellcheck` alone does not stand in for).
- `actionlint` reports the CI workflow clean.
- **Every pinned image digest resolves to a `linux/arm64` image, and every tag
  written beside it belongs to that digest.** Checked 2026-08-19 against
  ghcr.io, quay.io, and Docker Hub over HTTPS, with no Docker daemon: for each
  entry the tag's index was fetched and the pinned digest confirmed as one of
  its children, then the digest's own config blob was read for its `os` and
  `architecture`. All five report `linux/arm64`.

  This is the substance of `tests/contract/03-images.bats`'s first test, which
  itself still cannot run here because `require_arm64` calls `docker buildx
  imagetools inspect`. The registry answered the same question by a different
  route. It is not the same as having run that test.

**A passing dry-run does not prove the rendered values are the intended ones.**
It proves the chart rendered. This is not a hypothetical distinction; it is how
two defects survived several rounds of review on this branch, both found only
on 2026-08-19 by reading rendered output instead of source:

- `platform/20-kserve/values-kserve.yaml` set the chart's `gateway` key while
  KServe reads `kserveGateway`. Every dry-run passed. The rendered ConfigMap
  carried `kserveIngressGateway: kserve/kserve-ingress-gateway`, a Gateway this
  repository never creates.
- `clusters/local-kind/apps/30-observability.yaml` let Argo CD default the Helm
  release name to the Application name. Every dry-run passed. The rendered
  Service was `observability-kube-prometh-prometheus`, not the
  `kube-prometheus-stack-prometheus` four consumers in this repository name.

The rule that follows: a values change is checked by rendering the chart and
reading the value out of the output, not by reading the values file back. None
of this is a substitute for the table above.
