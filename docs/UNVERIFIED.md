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
`ornith-9b` `HTTPRoute` carries only the primary backend (no `weight`, no
second `backendRef`), and `tests/smoke/08-availability.bats`'s "the endpoint
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
| 6 | Under load, KEDA scales the predictor from 1 to 2 replicas, with evidence | `bats tests/smoke/07-autoscaling.bats` |
| 7 | Draining a node keeps the service available, PDB holding | `bats tests/smoke/08-availability.bats` |
| 8 | The recovery drill runs and its recovery time is committed | `task drill:recovery` |
| 9 | CI is green on an arm64 runner | push this branch, read `.github/workflows/ci.yml`'s result |

## Unproven: every dated measurement still owed

Every dated `> **Unmeasured` marker elsewhere in this repository, reconciled
by `grep -rn "Unmeasured (" . | grep -v docs/UNVERIFIED.md | wc -l` (14,
2026-08-19; this document's own references to that marker text in prose are
excluded from the count on purpose - otherwise this table would inflate the
number every time it mentions the pattern it is counting). Each row below
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
| `docs/runbooks/node-drain.md:70` | Memory footprint of two `ornith-9b-predictor` replicas resident together | `kubectl -n llm top pod -l serving.kserve.io/inferenceservice=ornith-9b` |
| `docs/runbooks/recovery-drill.md:19` | The recovery drill's own time-to-first-token number | `task drill:recovery` (runs `bench/recovery-drill.sh`) |

## What is proven

Nothing that requires a cluster. What holds without one: every `helm install
--dry-run=client` this repository's install scripts and Argo CD Applications
were checked against succeeds; every `kustomize build` across every overlay
succeeds; every CRD field this repository's manifests use was confirmed
against the pinned chart's own rendered schema, not memory; the real
`kyverno` CLI confirms the three admission policies reject exactly what
`tests/smoke/11-policy.bats` asserts they reject (`policy/tests/`); every
shell script parses under bash 3.2.57; `actionlint` reports the CI workflow
clean. None of this is a substitute for the table above.
