# Security policies

Both Kuadrant policies attach to **one** `HTTPRoute`, `ornith-9b-openai`
(`models/ornith-9b/overlays/local/httproute.yaml`). Neither attaches to the
Gateway. So a second route on the same Gateway carries no auth and no quota
unless it is given its own policies: the default is open, not closed.

- `AuthPolicy`: verifies the JWT against the Keycloak JWKS endpoint. No database
  lookup happens on the request path, which keeps the inference path stateless.
- `TokenRateLimitPolicy`: counts tokens, not requests. One request can cost a
  hundred tokens or a hundred thousand, so request counting is meaningless here.

The quota counter is keyed on the `tier` claim, not on the caller. Today that is
the same thing, because `platform/15-keycloak/realm-export.json` defines exactly
one client per tier. A second client on one tier would share that tier's budget.
