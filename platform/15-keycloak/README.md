# 60 Keycloak

Sync wave 1.

Issues the JWTs that the gateway verifies. Group claims map to quota tiers.

Dev mode: state is in memory and is lost on restart. So the realm is defined by a
`realm-export.json` file in git and imported at startup. Changing configuration
through the Keycloak web UI is not supported here, because it cannot be
reproduced.

Production Keycloak needs an external database, clustering, and backups. That is
deliberately out of scope; see `docs/runbooks/` instead.
