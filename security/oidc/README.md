# Security policies

Kuadrant policies attached to the gateway and to routes.

- `AuthPolicy`: verifies the JWT against the Keycloak JWKS endpoint. No database
  lookup happens on the request path, which keeps the inference path stateless.
- `TokenRateLimitPolicy`: counts tokens, not requests. One request can cost a
  hundred tokens or a hundred thousand, so request counting is meaningless here.

The quota key comes from a JWT claim, which is how identity and cost are joined.
