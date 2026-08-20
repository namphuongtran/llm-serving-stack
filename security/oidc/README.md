# Security policies

Both Kuadrant policies attach to **one** `HTTPRoute`, `ornith-9b-openai`
(`models/ornith-9b/overlays/local/httproute.yaml`). Neither attaches to the
Gateway. So a second route on the same Gateway carries no auth and no quota
unless it is given its own policies: the default is open, not closed.

- `AuthPolicy`: verifies the JWT against the Keycloak JWKS endpoint. No database
  lookup happens on the request path, which keeps the inference path stateless.
- `TokenRateLimitPolicy`: counts tokens, not requests. One request can cost a
  hundred tokens or a hundred thousand, so request counting is meaningless here.
- `AuthorizationPolicy`: closes the hole neither of the two above can see. Both
  filter traffic arriving at the Gateway, so neither applies to a Pod inside the
  cluster calling `ornith-9b-predictor` directly. Measured 2026-08-20 from a Pod
  in this namespace carrying no token: HTTP 200 on `/v1/models`, and HTTP 200 on
  `/v1/chat/completions`, a real inference charged to nobody. R12 in
  [`docs/sad/11-risks-and-debt.md`](../../docs/sad/11-risks-and-debt.md).
  **Written and not yet applied to any cluster.**

The quota counter is keyed on `azp`, the client_id, so each client has its own
budget and the tier only chooses how large that budget is. It was keyed on `tier`
until 2026-08-20, which gave every client sharing a tier one shared budget.

It is deliberately not keyed on `sub`. `platform/15-keycloak/realm-export.json`
declares no users and its clients carry no `id`, so Keycloak mints the
service-account UUID at every import, and `start-dev` persists nothing across a
restart. A counter keyed on `sub` would reset whenever the Keycloak Pod
restarted. Read off a live token 2026-08-20: `sub` was
`a4b7760d-f348-4a8f-848c-679d80032a73` and `azp` was `llm-tier-pro`.
