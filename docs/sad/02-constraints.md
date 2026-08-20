# 2. Constraints

> **Part of:** the [Software Architecture Document](README.md). arc42 section 2.

A constraint is a rule the architecture may not break. Each one below is
sourced, and each one changed a design decision somewhere downstream.

## Hardware and platform

| # | Constraint | Consequence | Source |
|---|---|---|---|
| H1 | The development machine is an Apple M4, arm64, 32 GB, with no GPU | Every image must have a `linux/arm64` variant | `versions.yaml`, `meta.machine` |
| H2 | `kserve/huggingfaceserver` publishes `linux/amd64` only | vLLM cannot be the local engine | [ADR 0005](../adr/0005-two-runtimes-one-control-plane.md) |
| H3 | Rosetta 2 implements no AVX, AVX2, or AVX512 | Emulating x86 vLLM ends in an illegal instruction, not in slow success | [ADR 0005](../adr/0005-two-runtimes-one-control-plane.md) |
| H4 | The whole stack shares one laptop with a 5.6 GB model | Istio runs in ambient mode, one ztunnel per node rather than one proxy per pod | [ADR 0003](../adr/0003-gateway-istio-ambient.md) |
| H5 | Docker Desktop must be given at least 8 CPUs and 20 GiB | `task preflight` fails with a specific message below that | `prereqs/preflight.sh` |

H2 and H3 together are the reason this repository has two engines and one
control plane. They are not a preference. Neither can be worked around without
building vLLM from source for arm64.

**Measured 2026-08-19**, on a 3-node `kind` cluster with Docker given 10 CPUs and
23.2 GiB: the platform layers, from an empty machine to Argo CD running, took
9 minutes 59 seconds and settled at 7.0 GiB, 29% of the allocation. With both models resident the cluster reached
17855 MiB, 75%. Re-measured 2026-08-20 after a Docker restart: 17576 MiB, 74%.
Source: [`docs/deployment-walkthrough.md`](../deployment-walkthrough.md) and
`docs/deployment-log.tsv`.

## Architecture

| # | Constraint | Consequence |
|---|---|---|
| A1 | Envoy AI Gateway requires Envoy Gateway as its base | With Istio chosen, Envoy AI Gateway is unavailable, and Kuadrant fills the gap ([ADR 0004](../adr/0004-policy-layer-kuadrant.md)) |
| A2 | Core Gateway API has no failover primitive | Cross-backend failover is withdrawn from phase 1, not deferred ([ADR 0007](../adr/0007-failover-not-expressible-in-gateway-api.md)) |
| A3 | Gateway API CRDs must exist before Istio installs | Sync wave 0 installs them; a `PreSync` hook enforces it for Kuadrant ([05-building-blocks](05-building-blocks.md)) |
| A4 | An Argo CD Application is one git object and cannot read a values file from this repository | Chart values and image digests are copied inline into each Application, so every value exists twice |

A4 is the most dangerous of the four, because nothing detects a half-applied
change. Changing a value or a digest means changing both copies, and the way to
check is to grep for the old string.

## Process

| # | Rule | Why | Check |
|---|---|---|---|
| P1 | Scripts must parse under bash 3.2.57 | That is the version macOS ships. No `mapfile`, no `readarray`, no `${v,,}` | `/bin/bash -n <script>` |
| P2 | Images are pinned by digest, never a tag | A floating tag makes a deploy unreproducible | `policy/disallow-floating-tags.yaml`, enforced at admission in namespace `llm` |
| P3 | Every version carries the date it was read | A version without a date cannot be re-checked | `versions.yaml` |
| P4 | No `: ` inside a `Taskfile.yml` command string | go-task 3.53.1 reads a colon plus space as command shorthand, even inside quotes, and breaks `task --list` for the whole file | `task --list` |
| P5 | ADRs are append-only | A changed decision gets a new ADR; the old one stays | [ADR 0001](../adr/0001-record-architecture-decisions.md) |
| P6 | A number without a measurement date is invalid | Quoting a number forward hides that it went stale | the `Unmeasured` marker |

P1 is not theoretical. On 2026-08-19 the KServe install script died on bash 3.2
locally, and CI could never have seen it: GitHub runners have bash 5.

## Two constraints that only running revealed

Both were found on the first real runs, and both now constrain new work.

| Constraint | What it forces |
|---|---|
| Argo CD applies **client-side** by default, writing each manifest into a 262144-byte annotation. Five of the fifteen charts here ship CRDs larger than that | `ServerSideApply=true` in `clusters/local-kind/root-app.yaml` |
| An Argo CD Application that fails to read its git path still reports `health.status: Healthy` | `.status.health.status` is not evidence. `clusters/local-kind/wait-for-sync.sh` reads sync status, counts children against the directory, and requires every Application green in one sample |

`helm install` never writes that annotation, which is why the imperative path
installs the same charts without complaint. Source:
[`docs/deployment-walkthrough.md`](../deployment-walkthrough.md), "The pull-based
path".

## Sources

- `versions.yaml` (the machine, the pinned versions, and the date each was read).
- ADR 0003, ADR 0004, ADR 0005, ADR 0007.
- [`docs/deployment-walkthrough.md`](../deployment-walkthrough.md) and
  `docs/deployment-log.tsv` for every measured number above.
- [`CLAUDE.md`](../../CLAUDE.md) for P1 to P6.

---

[Prev: Introduction and goals](01-introduction-and-goals.md) · [Index](README.md) · Next: [Context and scope](03-context-and-scope.md)
