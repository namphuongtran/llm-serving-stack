# Why quota is counted in tokens

## The question this answers

Why is rate limiting by request count meaningless for LLM traffic?

## Answer

Two requests can carry an identical shape at the HTTP layer - same route, same
method, same client, same JSON structure - and cost wildly different amounts
of compute. `POST /v1/chat/completions` with `"max_tokens": 8` and the same
call with `"max_tokens": 8000` are indistinguishable to anything counting
requests: same path, same verb, same size class if the prompt is short in
both cases. Only the response's own `usage.total_tokens` field says which one
actually cost more, and that field is not known until the engine has finished
answering. A request-count limit protects against the wrong thing: it caps
*how often* someone can ask, not *how much* asking costs, and those two are
only loosely related for a generative model where the caller chooses
`max_tokens` and the length of their own prompt.

This is why `TokenRateLimitPolicy` (`security/oidc/tokenratelimitpolicy.yaml`)
counts `usage.total_tokens` rather than requests, and why the counter is keyed
on the `tier` claim (`security/oidc/authpolicy.yaml`'s
`response.success.filters.identity`) rather than on the route: the quota
belongs to an identity's token budget, not to a path that both tiers share.

## What breaks if this layer is removed

Without it, `/v1/*` is either open to anyone with network access (no
`AuthPolicy`) or, with authentication but no quota, open to any authenticated
caller to spend unlimited tokens at unlimited rate. Either way the free tier
and the pro tier become indistinguishable in cost terms even though
`security/oidc/tokenratelimitpolicy.yaml` gives them a 200x difference in
budget (500 tokens/minute versus 100,000).

## What it costs to run

Two more components to run and upgrade - Authorino and Limitador - plus a
distributed counter store, tracked as risk R4 in the design spec and recorded
as a cost accepted in ADR 0004.

## The one thing that surprised me while building it

Not something found while building, but something that could not be shown
the way the design originally intended: the measured token cost of two
requests that look identical in a request-count world was supposed to be
taken from a running engine's `usage` field. No cluster exists in phase 1
authoring (plan Ruling 9), so there is no `ornith-9b` predictor to send those
two requests to. The argument above is the same argument that measurement
would have illustrated; the pair of numbers is recorded below as still owed,
with the exact commands, rather than invented to fill the gap.

> **Unmeasured (2026-08-19):** the `usage.total_tokens` values for two
> requests identical in every HTTP-visible respect except `max_tokens`. Run
> both once a cluster exists and a token is available:
> ```
> TOKEN=$(source tests/lib/helpers.bash && get_token llm-tier-pro)
> curl -sf http://llm.localtest.me/v1/chat/completions -H "authorization: Bearer $TOKEN" \
>   -H 'content-type: application/json' \
>   -d '{"model":"ornith-9b","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' \
>   | jq '.usage.total_tokens'
> curl -sf http://llm.localtest.me/v1/chat/completions -H "authorization: Bearer $TOKEN" \
>   -H 'content-type: application/json' \
>   -d '{"model":"ornith-9b","messages":[{"role":"user","content":"hi"}],"max_tokens":800}' \
>   | jq '.usage.total_tokens'
> ```
