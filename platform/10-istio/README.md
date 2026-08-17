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
