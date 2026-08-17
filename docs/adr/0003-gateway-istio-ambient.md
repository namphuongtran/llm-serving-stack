# ADR 0003: Istio in ambient mode as the gateway

- Date: 2026-08-17
- Status: accepted

## Context

The gateway choice looked like "Envoy versus Istio versus Traefik". That framing
is wrong: **Istio's data plane is Envoy**. A sidecar is Envoy. An Istio ingress
gateway is Envoy. So the real comparison is between a gateway that manages Envoy
for north-south traffic only (Envoy Gateway), a mesh that manages Envoy for both
directions (Istio), and a different proxy entirely (Traefik).

What decides the question for LLM serving is one filter. The Gateway API
Inference Extension works through Envoy's external processing filter,
`ext_proc`, and the endpoint picker that performs cache-aware routing is an
`ext_proc` server. Any gateway without `ext_proc` cannot participate in that
decision.

Why that decision matters: the endpoint picker scores candidate pods with a
prefix cache scorer at weight 2.0, a load-aware scorer at weight 1.0, and a queue
scorer. Cache affinity is weighted twice as heavily as spare capacity, because
sending a request to a pod that already holds the matching KV cache blocks avoids
recomputing the prefill.

## Options

| Option | `ext_proc` | East-west mTLS | Note |
|---|---|---|---|
| Envoy Gateway | yes | no | KServe's documented default gateway provider |
| Istio | yes, it is Envoy | yes | Heavier; also a mesh |
| Traefik | no evidence found | no | 100% Gateway API conformance, but its extension mechanism is its own Middleware CRD, not `ext_proc` |

On Traefik, the honest statement is that no evidence of `ext_proc` support was
found. That is not the same as proof of absence. Traefik is not built on Envoy,
so the assumption for planning is that cache-aware routing would not be
available.

## Decision

Use Istio, in ambient mode.

Ambient rather than sidecars: one ztunnel per node instead of one proxy per pod,
which matters on a 32 GB laptop that runs the whole stack at once.

## Cost accepted

1. Istio's inference extension support is alpha, not beta. Its own task page uses
   `inference.networking.x-k8s.io/v1alpha1`, requires experimental pilot flags,
   and demonstrates sidecar mode rather than ambient. KServe by contrast
   documents Envoy Gateway as the default provider. This cost falls entirely in
   phase 3; phases 1 and 2 do not use the inference extension.
2. Envoy AI Gateway cannot be used, because it requires Envoy Gateway as its
   base. This is resolved in ADR 0004 by using Kuadrant instead.
3. More resident memory and more moving parts than a plain gateway.
4. CRD conflicts are a real installation hazard. Gateway API CRDs must be
   installed before Istio, and llm-d states that a pre-existing Istio install
   conflicts with its own gateway, which must be re-checked before phase 3.

## Reversibility

The gateway is confined to `platform/10-istio/`, and the policy layer chosen in
ADR 0004 runs on either gateway. So this decision can be revisited at the start
of phase 3 without rewriting policies or models.

## Evidence

- Gateway API Inference Extension site, read 2026-08-17: the extension leverages
  Envoy's external processing to "extend any gateway that supports both ext-proc
  and Gateway API into an inference gateway".
- KServe control-plane architecture page, read 2026-08-17: the gateway is managed
  by a provider such as Envoy Gateway or Istio; `gatewayClassName: eg` is the
  default; the scheduler tracks KV cache blocks via ZMQ events from vLLM pods;
  scorer weights are prefix cache 2.0 and load-aware 1.0.
- Istio Gateway API Inference Extension task, read 2026-08-17: `v1alpha1` CRDs,
  `SUPPORT_GATEWAY_API_INFERENCE_EXTENSION` and
  `ENABLE_GATEWAY_API_INFERENCE_EXTENSION` pilot flags, sidecar profile example.
- Traefik Gateway API documentation, read 2026-08-17: full Gateway API
  conformance; `ExtensionRef` filters map to Traefik Middleware CRDs.
- Istio ambient footprint figures circulating in blogs (ztunnel roughly 0.06 vCPU
  and 12 MB per node against a sidecar roughly 0.20 vCPU and 60 MB per pod at
  1000 rps) are **not verified**. They will be measured on this machine and the
  result committed under `bench/results/`.
