# 60 Keycloak

Sync wave 1.

Issues the JWTs that the gateway verifies.

The `tier` claim is what the token quota is keyed on, and it comes from a
per-client hardcoded claim mapper, not from a group. Corrected 2026-08-19: this
line used to read "Group claims map to quota tiers", which was false. The realm
has no groups and no users at all. `realm-export.json` defines two clients,
`llm-tier-free` and `llm-tier-pro`, both service accounts with
`standardFlowEnabled: false`, and each carries an
`oidc-hardcoded-claim-mapper` that stamps its own tier onto the access token.

So a tier is a property of an API client, not of a person. There is no
interactive login in this realm. Giving different people different quotas would
need users, groups, a group-to-claim mapper, and a client with the standard
flow enabled - none of which phase 1 has.

Dev mode: state is in memory and is lost on restart. So the realm is defined by a
`realm-export.json` file in git and imported at startup. Changing configuration
through the Keycloak web UI is not supported here, because it cannot be
reproduced.

Production Keycloak needs an external database, clustering, and backups. That is
deliberately out of scope; see `docs/runbooks/` instead.
