# 50 Kuadrant

Sync wave 2, alongside KServe.

The policy layer: authentication (Authorino) and rate limiting (Limitador).

Chosen over Envoy AI Gateway for two reasons. Envoy AI Gateway requires Envoy
Gateway as its base, and we run Istio. Kuadrant installs on either gateway, so
the gateway decision stays reversible. See
`docs/adr/0004-policy-layer-kuadrant.md`.

The policies themselves live in `security/oidc/`, not here. This directory
installs the operator.
