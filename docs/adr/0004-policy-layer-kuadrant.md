# ADR 0004: Kuadrant as the policy layer

- Date: 2026-08-17
- Status: accepted

## Context

Rate limiting by request count is meaningless for LLM traffic. One request can
cost a hundred tokens or a hundred thousand, so the cost of a request is not
known until it has been answered. Quota therefore has to be counted in tokens,
which requires reading the response.

The obvious candidate was Envoy AI Gateway, which does exactly this. Its
prerequisites page states plainly: "Envoy AI Gateway is built on top of Envoy
Gateway", with Envoy Gateway 1.8.1 or higher required. ADR 0003 chose Istio, so
Envoy AI Gateway is unavailable.

Leaving the gap open was not acceptable. Without token accounting there is no
quota, and without quota the identity layer has nothing to enforce.

## Decision

Use Kuadrant for both authentication and rate limiting:

- `AuthPolicy` (Authorino) verifies the JWT issued by Keycloak against its JWKS
  endpoint.
- `TokenRateLimitPolicy` (Limitador) counts tokens and enforces per-identity
  quota.

## Reasons

1. `TokenRateLimitPolicy` extracts `usage.total_tokens` from the response without
   extra configuration, and the documentation names OpenAI-compatible backends
   including vLLM, KServe, and Ollama. That is exactly this stack.
2. It installs on **either** Istio or Envoy Gateway. This is the more valuable
   property than any single feature: it makes ADR 0003 reversible. If phase 3
   forces a gateway change, the policy layer survives untouched.
3. `AuthPolicy` and `TokenRateLimitPolicy` compose, so identity and cost are
   joined: the quota key is a JWT claim.
4. The core Kuadrant policies have reached v1.

## Design property worth naming

JWT verification happens at the gateway using public keys. No datastore is
queried on the request path. The inference path stays stateless, which is what
allows it to scale and to be replaced pod by pod. State exists in the platform,
never in the request path.

## Cost accepted

Two more components to run and upgrade, Authorino and Limitador, plus a Redis for
distributed counters. On a 32 GB laptop this is a real cost, tracked as risk R4
in the design spec.

## Evidence

- Envoy AI Gateway prerequisites, read 2026-08-17: "Envoy AI Gateway is built on
  top of Envoy Gateway"; Envoy Gateway 1.8.1+; Kubernetes 1.32+; no mention of
  Istio support.
- Kuadrant token rate limiting documentation, read 2026-08-17:
  `TokenRateLimitPolicy` extracts `usage.total_tokens` from OpenAI-compatible
  backends including vLLM and KServe, and works together with `AuthPolicy`.
- Kuadrant v1 announcement, read 2026-08-17: `AuthPolicy`, `RateLimitPolicy`,
  `DNSPolicy`, and `TLSPolicy` CRDs at v1; installation offers a choice between
  Istio and Envoy Gateway.
- Red Hat Developer article on `TokenRateLimitPolicy` for AI workloads, dated
  2026-02-18.
