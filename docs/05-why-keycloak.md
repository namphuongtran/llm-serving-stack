# Why JWT, not an API key table

Status: half written. The design reasoning below does not need a cluster to
state. The restart observation does, and no cluster exists on this machine
yet (see docs/adr/0004 for the policy layer this identity feeds).

## The question this answers

Why does verifying identity at the gateway keep the inference path stateless?

An API key table needs a lookup on every request: the gateway (or the
backend) has to query a datastore to find out who the key belongs to and
whether it is still valid. That lookup is state on the request path, and
state on the request path is exactly what makes a service hard to scale
and hard to replace pod by pod, because every replica now depends on that
same datastore being reachable and fast.

A JWT changes what the gateway needs to check. Keycloak signs the token
once, at issue time, with a private key. The gateway (Kuadrant's
`AuthPolicy`, backed by Authorino) verifies the signature against
Keycloak's public keys, published at the JWKS endpoint
(`/realms/llm/protocol/openid-connect/certs`). Verifying a signature
against a public key needs no datastore at all: the claims, including the
`tier` claim the token quota reads, travel inside the token itself. As ADR
0004 states it: "JWT verification happens at the gateway using public
keys. No datastore is queried on the request path. The inference path
stays stateless, which is what allows it to scale and to be replaced pod
by pod." State still exists, but it lives in Keycloak, which issues and
signs tokens, not in the request path that serves them.

## Notes to fill in

- **What breaks if this layer is removed.** There would be no issuer for
  the JWTs Kuadrant's `AuthPolicy` verifies, so every request would either
  go unauthenticated or fail the JWKS lookup, and the `tier` claim the
  token quota is keyed on would not exist.
- **What it costs to run.**

  > **Unmeasured (2026-08-19):** the resident memory of the Keycloak pod on
  > this machine, run `kubectl -n llm top pod -l app=keycloak` (or
  > `kubectl -n llm get pod -l app=keycloak` if metrics-server is not
  > installed) once a cluster exists.
- **The one thing that surprised me while building it.**

  This document's design claim, that the realm survives a restart because
  it is defined in `platform/15-keycloak/realm-export.json` and re-imported
  on every start rather than kept in Keycloak's in-memory dev-mode state,
  has not actually been tested against a running pod yet.

  > **Unmeasured (2026-08-19):** whether the realm survives a pod restart,
  > run `kubectl -n llm rollout restart deploy/keycloak && kubectl -n llm
  > rollout status deploy/keycloak --timeout=5m && bats
  > tests/smoke/03-identity.bats` once a cluster exists, and record whether
  > all four tests still pass afterward.
