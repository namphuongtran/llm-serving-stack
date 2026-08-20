# 9. Architecture decisions

> **Part of:** the [Software Architecture Document](README.md). arc42 section 9.

The ADRs in [`docs/adr/`](../adr/) are the authority. This page is the reverse
index: what each one decided, and which views depend on it.

**ADRs are append-only.** A changed decision gets a new ADR that supersedes the
old one, and the old one stays. That is [ADR 0001](../adr/0001-record-architecture-decisions.md)'s
own decision.

## The register

| ADR | Decision | Date | Status | Cited by |
|---|---|---|---|---|
| [0001](../adr/0001-record-architecture-decisions.md) | Record architecture decisions, append-only | 2026-08-17 | accepted | [02](02-constraints.md), this page |
| [0002](../adr/0002-standard-mode-not-knative.md) | KServe Standard mode, not Knative. No scale to zero by default | 2026-08-17 | accepted | [01](01-introduction-and-goals.md), [04](04-solution-strategy.md), [06](06-runtime-view.md) |
| [0003](../adr/0003-gateway-istio-ambient.md) | Istio in ambient mode as the gateway | 2026-08-17 | accepted | [02](02-constraints.md), [04](04-solution-strategy.md), [05](05-building-blocks.md) |
| [0004](../adr/0004-policy-layer-kuadrant.md) | Kuadrant for both authentication and token quota | 2026-08-17 | accepted | [03](03-context-and-scope.md), [04](04-solution-strategy.md), [06](06-runtime-view.md) |
| [0005](../adr/0005-two-runtimes-one-control-plane.md) | Two engines, one control plane. llama.cpp on arm64, vLLM on GPU | 2026-08-17 | accepted | [01](01-introduction-and-goals.md), [02](02-constraints.md), [04](04-solution-strategy.md), [07](07-deployment-view.md) |
| [0006](../adr/0006-metric-normalisation.md) | Normalise engine metrics into an `llmstack:` namespace | 2026-08-19 | accepted, **documentation-derived**: not yet observed on a running engine | [01](01-introduction-and-goals.md), [04](04-solution-strategy.md), [08](08-crosscutting-concepts.md) |
| [0007](../adr/0007-failover-not-expressible-in-gateway-api.md) | Cross-backend failover is not expressible in core Gateway API. Withdrawn from phase 1 | 2026-08-19 | accepted, supersedes the design spec's failover row | [01](01-introduction-and-goals.md), [11](11-risks-and-debt.md) |

Note ADR 0006's status. It is accepted, and its metric mapping was derived from
llama.cpp's own documentation pinned to the exact commit the running image was
built from, not from a live `/metrics` endpoint. That distinction is the ADR's
own wording and is preserved here.

## What each ADR cost

An ADR that records only the benefit is half a record. Each one here names the
cost it accepted.

| ADR | Cost accepted |
|---|---|
| 0002 | No scale to zero by default. The `cost-saving` overlay demonstrates it opt-in, with its cold start to be measured rather than asserted |
| 0003 | Istio's inference-extension support is alpha, not beta; Envoy AI Gateway becomes unavailable; more resident memory than a plain gateway; and Gateway API CRDs must be installed before Istio |
| 0004 | Two more components to run and upgrade, Authorino and Limitador |
| 0005 | Two engines to keep working, and everything above them must stay engine independent. Also: llama.cpp emits no traces at all, found while implementing and not anticipated when the decision was taken |
| 0006 | Three dashboard panels cannot be filled by this engine, and the time-to-first-token panel is filled by a client-side prober rather than by the engine |
| 0007 | Phase 1 has no automatic fallback. When the engine is unavailable, callers get an error, and the spec no longer claims otherwise |

**One correction is recorded rather than quietly applied.** ADR 0004 originally
named "a Redis for distributed counters" among its accepted costs. Phase 1
deploys no Redis: `platform/25-kuadrant/` applies a `Kuadrant` CR with
`spec: {}`, which leaves Limitador on its own default storage. Corrected in the
ADR on 2026-08-19, with the design spec's matching error corrected too.

## Decisions that are not ADRs

Three choices shape the repository and live in code comments or `CLAUDE.md`
rather than in an ADR, because they are conventions rather than architecture:

| Convention | Where it is recorded |
|---|---|
| Scripts must parse under bash 3.2.57 | [`CLAUDE.md`](../../CLAUDE.md) |
| Images pinned by digest, enforced at admission | `policy/disallow-floating-tags.yaml` |
| Overrides go under `model:`, and our volume is mounted at `/models` | `models/ornith-9b/overlays/local/patch-resources.yaml`, with the KServe v0.20.0 source lines |

If one of these ever changes behaviour that another view depends on, it needs an
ADR, not a comment.

## How to add one

1. Copy the shape of an existing ADR: context, options, decision, reasons, cost
   accepted, reversibility, evidence.
2. Give every external claim a source and the date it was read.
3. Never edit an accepted ADR to change its decision. Write a new one that
   supersedes it.
4. Add a row to the register above, and to the `Cited by` column of whichever
   views depend on it.

## Sources

Every row in this page was read from the ADR file it names, on 2026-08-20. The
`Cited by` column was built from the links written in the view files listed, not
from a search.

---

[Prev: Cross-cutting concepts](08-crosscutting-concepts.md) · [Index](README.md) · Next: [Quality requirements](10-quality-requirements.md)
