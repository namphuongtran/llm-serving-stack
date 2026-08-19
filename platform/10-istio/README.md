# 10 Istio (ambient mode)

Sync wave 1.

The entry point for outside traffic, and mTLS between pods inside the cluster.

Why Istio and not Envoy Gateway: see `docs/adr/0003-gateway-istio-ambient.md`.
The short version is that Istio uses Envoy as its data plane, so the Envoy
`ext_proc` filter is still available, and it adds east-west security that a plain
gateway does not.

Ambient mode, not sidecars: one ztunnel per node instead of one proxy per pod.

Install order matters. Gateway API CRDs go in before Istio (risk R6 in the
design spec).

## Tracing, added 2026-08-19

This layer is where the trace pipeline gets its producer. Two files:

- `helm/values-istiod.yaml` puts an `opentelemetry` `extensionProvider` named
  `otel-tracing` into the MeshConfig, pointing at
  `otel-collector.observability:4317`.
- `telemetry.yaml` is a `Telemetry` selecting the gateway and enabling that
  provider at 100 percent sampling.

The engine cannot do this. llama.cpp emits no spans at all
(`docs/adr/0005-two-runtimes-one-control-plane.md`), so the gateway's Envoy is
the only span source in phase 1. That yields one span per request for the
gateway hop, and nothing about the inside of the model.

**`helm/values-istiod.yaml` must stay in that subdirectory.**
`clusters/local-kind/apps/10-istio-gateway.yaml` sources this directory as an
Argo CD directory source with `recurse: false`, so every `*.yaml` sitting
directly here is applied to the cluster as a manifest. A Helm values file is not
a Kubernetes object. The subdirectory is what keeps it out of that Application's
reach.

Its declarative twin is the `helm.valuesObject` block in
`clusters/local-kind/apps/10-istiod.yaml`. Changing one means changing both.

One ordering fact worth knowing: this layer is wave 1 and observability is wave
3, so on a first boot the gateway is configured to export spans to a Service
that does not exist yet. Envoy drops spans it cannot deliver rather than failing
requests, so that window costs traces, not availability.
