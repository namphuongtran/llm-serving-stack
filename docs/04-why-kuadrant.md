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
counts `usage.total_tokens` rather than requests. Kuadrant extracts that field
from an OpenAI-compatible response without extra configuration, which is why the
field name appears nowhere in the file (ADR 0004, evidence).

The counter is keyed on `auth.identity.azp`, the client_id, and the *limit* is
chosen by the `tier` claim (`security/oidc/tokenratelimitpolicy.yaml:44` and
`:52`). That split took two attempts and is explained under "Three ways this
layer failed" below.

## The measurement that settles it, and the day it was written off

**Measured 2026-08-20 06:55Z**, free tier, a roughly 500-token prompt with
`max_tokens: 1`:

```
request 1  ->  HTTP 200   usage.total_tokens=552
request 2  ->  HTTP 429
```

Two requests settle criterion 4. Read the second sentence of that finding before
taking anything else from it.

For one day this repository, in four separate files, said criterion 4 was
untestable on this engine. The reasoning was that the 500-token budget can only
be spent if the stack **generates** more than 500 tokens inside 60 seconds, and
llama.cpp generates 0.55 tokens per second, which is 33 tokens per window. Every
number in that sentence is correct and dated. The conclusion is wrong, because
`usage.total_tokens` is prompt tokens **plus** completion tokens. Generation
rate is one way to spend the budget, not the only one
(`docs/STATUS.md`, "The first load test", finding 4).

**The lesson is not about tokens.** A measured, dated, correct number was used to
support a claim, and nobody measured the claim, because the arithmetic looked
conclusive. This repository's rule about numbers did not catch it, because the
number was never the problem.

## Three ways this layer failed, and what each one is about

Counting tokens is the right idea. Every defect below is about the gap between
that idea and a counter that actually runs.

**1. The counter was keyed on the wrong thing (R13, fixed 2026-08-20).** Both
limits read `counters: - expression: auth.identity.tier`, so two clients on one
tier would have shared one budget. It was invisible, because
`platform/15-keycloak/realm-export.json` defines exactly one client per tier, so
tier and caller were the same string. Keying on `sub` was rejected for a reason
that belongs to [`05-why-keycloak.md`](05-why-keycloak.md): the realm declares no
users, so Keycloak mints a fresh service-account UUID at every import and
`start-dev` persists nothing, which would reset every counter whenever the pod
restarts.

**2. The fix failed open, and only a live test found it (R25, fixed
2026-08-21).** The counter moved to `auth.identity.azp`, and `azp` is in the
token. The same budget test that returned 429 at 23:02Z returned **200** at
23:51Z, and a third request also 200. The gateway said why on every request:

```
CelError::Resolve { NoSuchKey("azp") }
```

Only what `security/oidc/authpolicy.yaml`'s `response.success.filters` exports is
visible to the CEL expression in the rate-limit policy. Being in the token is
not enough. Two things to keep from this: **a rate-limit expression that cannot
resolve fails open, not closed**, and the window between a push and a CI verdict
is a window in which the quota was not enforced. CI caught it without being
asked to, on run `32429474915`, with forty consecutive 200s in 16 seconds.

**3. The quota is opt-in by the caller (R21, half fixed 2026-08-21).** This is
the deepest one, and it is not fixed.

Measured 2026-08-21, same tier, same 711-token prompt against a 500-token
budget, with only `stream_options.include_usage` differing:

| Request | Result | Next request |
|---|---|---|
| Streamed **with** `include_usage` | HTTP 200 in 2.6s | **429** |
| Streamed **without** it | HTTP 200 | 200, and a third 200 |

The gateway's own log says why, once per streamed request:
`kuadrant_wasm_shim: Missing json property: /usage/total_tokens`, then
`Task failed: Some("4")`. A streamed response that does not ask for usage
reports none, so Kuadrant counts zero, so the whole cost-control layer is
bypassed by a default client.

`tests/smoke/06-auth-quota.bats` passes because its helper does not stream. So
criterion 4 is verified on a path that no interactive client in this repository
was using.

The repository's own clients now set the field: `tools/chat.sh`,
`platform/30-observability/ttft-prober-cronjob.yaml`, `bench/recovery-drill.sh`,
and `tests/smoke/08-availability.bats`; `bench/harness.py` already did. **That
fixes this repository's clients and not the risk.** A caller who omits the field
still pays nothing, and a caller who wants free tokens will omit it. A quota is
only a quota when the counting does not depend on the request.

A side effect worth knowing before trusting any latency number taken through the
gateway (R22): when `usage` is absent, the shim holds the streamed response open
long after the body is complete. Measured 2026-08-21 on identical small
requests, `include_usage` the only difference: **without** it `ttfb=2.38s
total=40.93s`; **with** it `ttfb=1.92s total=1.92s`.

## What breaks if this layer is removed

Without it, `/v1/*` is either open to anyone with network access (no
`AuthPolicy`) or, with authentication but no quota, open to any authenticated
caller to spend unlimited tokens at unlimited rate. Either way the free tier
and the pro tier become indistinguishable in cost terms even though
`security/oidc/tokenratelimitpolicy.yaml` gives them a 200x difference in
budget (500 tokens/minute versus 100,000).

Two limits on that protection, both measured, both about scope rather than
mechanism:

- **The policies attach to one named route.** Both target `HTTPRoute
  ornith-9b-openai`, and nothing attaches to the Gateway, so a second model with
  a second route carries neither policy unless somebody writes them (R15). The
  default is open, not closed.
- **Nothing enforces anything inside the cluster.** Both policies sit on an
  `HTTPRoute`, so they see gateway traffic only. Any pod could call the
  predictor directly. See [`03-why-istio.md`](03-why-istio.md) for the attempt to
  close that and what it broke.

## What it costs to run

Two more components to run and upgrade, Authorino and Limitador. Measured
2026-08-19: the `kuadrant` step took **111 seconds**, the second-slowest layer,
and moved the cluster from 3835 MiB to 4389 MiB, a **554 MiB** jump
(`docs/deployment-log.tsv`). Tracked as risk R4 and recorded as a cost accepted
in ADR 0004.

**Not a distributed counter store.** ADR 0004's cost section named "a Redis for
distributed counters" until 2026-08-19, and it was wrong: phase 1 deploys no
Redis. `platform/25-kuadrant/` applies a `Kuadrant` CR with `spec: {}`, which
leaves Limitador on its own default storage. Distributed counters across
Limitador replicas would need that datastore, and that is a phase 2 question
rather than a cost already being paid.

Two operational costs came out of running it, and both are recorded in
[`03-why-istio.md`](03-why-istio.md) because they belong to the gateway that
hosts the policies: the operator caches the Gateway API CRDs at startup and
refuses every policy until restarted by hand (R2), and Envoy fetches the
Kuadrant Wasm shim once, fails closed, and never retries (R19).

## The one thing that surprised me while building it

That the argument in this document is correct and was not the hard part.

Counting tokens instead of requests is a design decision, and it survived
contact with a real cluster on the first try: 552 tokens, then 429. Everything
that went wrong afterwards was about *what the counter can see*. It could not
see a claim that was in the token but not exported. It cannot see the usage of a
response whose caller chose not to ask for it. Both failures were silent, both
returned HTTP 200, and both would look like a working quota to anybody watching
the status codes.

So the sentence to carry out of this layer is not "count tokens, not requests".
It is that a quota built on a field in the response body inherits every
condition under which that field is absent, and the caller controls one of them.
That is a property of the design, not a bug in Kuadrant, and it is why R21 is
recorded as half fixed rather than closed.

> **Unmeasured (2026-08-19):** the `usage.total_tokens` values for two requests
> identical in every HTTP-visible respect except `max_tokens`. **This is an
> illustration, not the criterion**, and the criterion is settled above by a
> different pair of requests. This marker originally said no cluster existed;
> one has existed since 2026-08-19 and this exact pair has never been sent. Run
> both once a cluster is up:
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
> At 0.210 output tokens per second the second call is slow, so give it room.
> Neither request streams, so neither is affected by R21.
