# Why JWT, not an API key table

Status: written 2026-09-04. The design reasoning below never needed a cluster.
The operating sections did, and a cluster has existed since 2026-08-19. One
restart test is still owed and is marked as such. The policy layer this identity
feeds is [ADR 0004](adr/0004-policy-layer-kuadrant.md).

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
`tier` claim that chooses the quota and the `azp` claim the quota counts, travel
inside the token itself. As ADR 0004 states it: "JWT verification happens at the
gateway using public keys. No datastore is queried on the request path. The
inference path stays stateless, which is what allows it to scale and to be
replaced pod by pod." State still exists, but it lives in Keycloak, which issues
and signs tokens, not in the request path that serves them.

## What the realm actually contains, and why that matters downstream

`platform/15-keycloak/realm-export.json` declares realm `llm`, **zero users**,
and two clients, `llm-tier-free` and `llm-tier-pro`, both with service accounts
enabled. `platform/15-keycloak/keycloak.yaml:29` runs
`args: ["start-dev", "--import-realm"]`, with the realm mounted from a ConfigMap
at `/opt/keycloak/data/import`.

Three consequences follow, and one of them decided a design question two layers
away.

1. **The realm is re-imported on every start**, so it is defined in git rather
   than kept in a database somebody has to back up.
2. **`start-dev` persists nothing.** There is no database. Whatever Keycloak
   holds at runtime is gone when the pod is.
3. **Because the realm declares no users, Keycloak mints a fresh service-account
   UUID at every import.** That is why the token quota is keyed on
   `auth.identity.azp`, the client_id, and not on `sub`: a `sub`-keyed counter
   would reset whenever the Keycloak pod restarted
   (`docs/sad/11-risks-and-debt.md`, R13).

Point 3 is the price of point 1, and it is worth naming as a price. Keeping the
issuer stateless keeps the realm reproducible from git, and it also means the
only stable identity in the system is the client_id.

## What breaks if this layer is removed

There would be no issuer for the JWTs Kuadrant's `AuthPolicy` verifies, so every
request would either go unauthenticated or fail the JWKS lookup, and the `tier`
and `azp` claims that the token quota depends on would not exist.

The measured version of that is sharper, and it runs the other way: **Keycloak's
availability is already a runtime dependency of the reject path**, not only of
the accept path.

`security/oidc/authpolicy.yaml:30` sets
`issuerUrl: http://llm.localtest.me/realms/llm`, and
`platform/15-keycloak/httproute.yaml:13` puts `/realms` behind the same Gateway
that serves `/v1/*`. Confirmed on a live cluster on 2026-08-20: in-cluster DNS
resolves `llm.localtest.me` to the gateway Service, not to Keycloak's own
(R11). So Authorino performs OIDC discovery through the gateway it is filtering.

Two measured consequences:

| Event | Effect on identity | Source |
|---|---|---|
| Sustained load on the gateway, 2026-08-20 | Authorino logged `failed to discovery openid connect configuration` and returned gRPC 14 `UNAVAILABLE`. Requests carrying **no token at all** got HTTP 500 instead of 401 | `docs/STATUS.md`, finding 2 |
| The gateway's Wasm shim failed closed, 2026-08-20 13:36Z | Every request returned 503, **token issuance included**, because Keycloak sits behind the same gateway | R19 |

Neither is a security hole: the path fails closed and never returns 200 without a
token. Both say the same thing about topology. Putting the issuer behind the
gateway it authorises makes identity and inference share a failure domain, and
this repository measured that twice before writing it down.

## What it costs to run

Measured 2026-08-19: the `keycloak` step took **58 seconds** and moved the
cluster from 2816 MiB to 3378 MiB, a **562 MiB** jump
(`docs/deployment-log.tsv`). That is a whole-cluster delta and includes anything
else that moved in the same window.

> **Unmeasured (2026-08-19):** the resident memory of the Keycloak pod on its
> own. **The reason has changed and the number has not.** This marker originally
> said no cluster existed; one has existed since 2026-08-19 and the per-pod
> reading was never taken. Run `kubectl -n llm top pod -l app=keycloak` once a
> cluster is up. kind installs no metrics-server, so `docker stats` on the node
> containers is the fallback the rest of this repository uses.

A second cost is not measured in megabytes. `start-dev` is a development mode.
It is honest for a laptop and it is not what a real deployment runs, which is why
`docs/runbooks/keycloak-for-real.md` exists as a separate document rather than as
a footnote here.

A third cost lands on every benchmark this repository runs.
`accessTokenLifespan` is **900 seconds** (`realm-export.json`), and
`bench/run.sh:24` fetches one token for a whole run. At the engine's measured
0.210 output tokens per second, every scenario in `bench/scenarios/` takes longer
than that, so the token expires mid-run: 19 of 40 requests in the first completed
benchmark returned HTTP 401 (R10). The identity layer is correct and the harness
is wrong, and the shape of that mistake is worth keeping: a short-lived
credential is a good default that quietly assumes short-lived work.

## The one thing that surprised me while building it

**How far the stateless property actually reaches, and where it stops.**

The claim this document opens with held. No datastore is queried on the request
path, and verifying a signature against a JWKS key is all the gateway does.

What was not obvious is that the same choice reaches two layers down and decides
something that looks unrelated. Because the issuer keeps no state, the realm is
re-imported from git on every start. Because it is re-imported, service-account
identities are re-minted. Because they are re-minted, the token quota in
[`04-why-kuadrant.md`](04-why-kuadrant.md) cannot be keyed on the subject and is
keyed on the client_id instead. A decision about where state lives turned into a
constraint on what a rate limiter is allowed to count.

Where it stops is the topology. The inference path is stateless; the *identity*
path is not independent, because the issuer is reachable only through the gateway
that the identity decision protects. That loop is measured, it degrades the
reject path under load, and cutting it means letting Authorino reach Keycloak's
Service directly, so that the token's `iss` and the discovery URL stop being one
string. That change is open, and it is R11's designed response.

> **Unmeasured (2026-08-19):** whether the realm survives a pod restart. The
> mechanism above is read from `keycloak.yaml` and `realm-export.json`, not
> observed. **The reason has changed and the test has not been run.** Settle it
> with `kubectl -n llm rollout restart deploy/keycloak && kubectl -n llm rollout
> status deploy/keycloak --timeout=5m && bats tests/smoke/03-identity.bats`, and
> record whether all six tests still pass. (That suite held four tests when this
> marker was first written and holds six today, read 2026-09-04 with
> `grep -c '^@test' tests/smoke/03-identity.bats`.) Check one thing beyond pass or fail:
> whether the service-account `sub` in a fresh token changed across the restart,
> because that is the claim R13 relies on.
