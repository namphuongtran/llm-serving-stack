# Documentation

Four kinds of document, with different jobs.

## Why each layer exists

`01-why-*.md` through `08-why-*.md`. One short document per layer, each answering
the same question: **what breaks if this layer is removed?**

They are written while the layer is built, not before. A document written in
advance describes what was expected; one written during the work describes what
happened.

| File | Question it answers |
|---|---|
| `01-why-vllm.md` | Why an inference engine, and not plain transformers |
| `02-why-kserve.md` | Why a control plane, and not hand-written Deployments |
| `03-why-istio.md` | Why a mesh-capable gateway, and what `ext_proc` has to do with it |
| `04-why-kuadrant.md` | Why quota is counted in tokens, and why that needs a policy layer |
| `05-why-keycloak.md` | Why JWT verification keeps the inference path stateless |
| `06-why-otel.md` | Why TTFT and queue depth, and not CPU and average latency |
| `07-why-gitops.md` | Why delivery is pull based, not pushed from CI |
| `08-why-llm-d.md` | Why round-robin load balancing is wrong for LLM traffic |

## Decisions

[`adr/`](adr/) holds one file per decision: the context, the options, the choice,
the cost, and the evidence. ADRs are append-only. When a decision changes, a new
ADR supersedes the old one and the old one stays.

## Runbooks

[`runbooks/`](runbooks/) is for failure, written before it happens.

## The spec

[`superpowers/specs/`](superpowers/specs/) holds the design this repository
implements, including the evidence log with the date each fact was verified.

## What has not run yet

[`UNVERIFIED.md`](UNVERIFIED.md) is the one place that states plainly what is
unproven, what is unverified by construction, and what is doubted on
technical grounds rather than merely unmeasured. Every other document above
can name a gap in its own layer; this one is the reconciled account across
all of them.
