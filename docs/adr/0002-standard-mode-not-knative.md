# ADR 0002: KServe Standard mode, not Knative

- Date: 2026-08-17
- Status: accepted

## Context

KServe supports three shapes: `InferenceService` in Standard mode,
`InferenceService` in Knative serverless mode, and `LLMInferenceService`.

Knative mode adds scale to zero through its own autoscaler and activator. Scale
to zero sounds like an unambiguous win and is often presented that way.

## Decision

Use Standard mode. Do not install Knative.

Use `InferenceService` for phases 1 and 2, and move to `LLMInferenceService` in
phase 3, where multi-node inference and cache-aware routing require it.

## Reasons

1. KServe's own admin guide says to start with `InferenceService`, and that it
   works for both predictive and standard LLM workloads.
2. Scale to zero and availability are in direct conflict for this workload. Model
   weights are tens to hundreds of gigabytes. A pod starting from zero must
   download or load them before it can answer, which is minutes rather than
   seconds. The tutorial framing treats scale to zero as a free feature and does
   not mention this cost.
3. Knative is another control plane to install, secure, upgrade, and debug, on a
   laptop that also has to run Istio, Kuadrant, Keycloak, Prometheus, Grafana,
   KEDA, and a model.

Autoscaling still happens: KEDA scales on queue depth, which is the signal that
matters, rather than on CPU, which is misleading when a GPU is the bottleneck.

## Cost accepted

No scale to zero by default. A separate `cost-saving` overlay will demonstrate it
and measure the cold start, so the trade-off is a number in this repository
rather than an opinion.

## Evidence

- KServe admin guide overview, read 2026-08-17: "Start with InferenceService — it
  works for all workloads, both ML and standard LLM."
- KServe documentation on `LLMInferenceService`, read 2026-08-17: prefill/decode
  separation, multi-node orchestration, and intelligent scheduling are not
  available through `InferenceService`.
