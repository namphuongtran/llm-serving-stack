# Runbook: what production Keycloak needs that this repository does not build

`platform/15-keycloak/keycloak.yaml` runs Keycloak with `start-dev
--import-realm`: development mode, one replica, the realm imported from a
file committed to git (`realm-export.json`). That is the right choice for
phase 1 and the wrong one for anything a real user depends on. This runbook
states plainly what changes and why, so nobody mistakes the dev-mode
convenience for a production plan.

## Dev mode loses all state on restart

`start-dev` runs against Keycloak's own embedded, dev-only database (H2),
which Keycloak's documentation states plainly is not for production use and
does not support clustering. This repository's Deployment
(`platform/15-keycloak/keycloak.yaml`) mounts no persistent volume for it, so
whatever that database holds lives on the pod's ephemeral filesystem: a pod
restart - a rollout, an OOMKill, a node drain, this repository's own recovery
drill - returns to exactly the state `realm-export.json` describes and
nothing more. Any change made through the Keycloak admin console (a new
client, a rotated secret, a user added by hand) is gone the moment the pod
restarts.

**This is what makes dev mode acceptable here and nowhere else.** Because the
realm is fully described in a file this repository commits, "state is lost on
restart" and "state is reproducible from git" are the same fact seen from two
directions - Task 12's whole GitOps argument
(`docs/07-why-gitops.md`) rests on exactly that property. The moment a real
user's own data (a client only they registered, a session only they hold)
needs to survive a restart, this stops being true, and dev mode stops being
acceptable.

## What production Keycloak requires instead

| Requirement | Why dev mode does not have it |
|---|---|
| **An external database** | `start-dev` runs against Keycloak's embedded H2 database, which Keycloak's own documentation says is for development only and not viable under real concurrency; this repository adds no persistent volume for it either, so state survives only as long as the pod does. Production needs a real external database (PostgreSQL, in practice) so state survives the pod, not just the file that seeded it. |
| **Clustering** | This repository runs `replicas: 1`. A second replica of dev-mode Keycloak would not share any state with the first - there is nothing to share it through. Production Keycloak clusters via its distributed cache (Infinispan) layered over the shared database, which requires the database above and `start` (not `start-dev`) plus explicit cache configuration. |
| **Backup and restore of the realm** | `realm-export.json` backs up the *seed*, not live state: a client added through the admin console after startup is in nobody's git history. Production needs a real backup of the database itself (the mechanism Keycloak's own admin CLI and database-level tooling provide), on a schedule, tested by restoring it. |
| **Secrets from `external-secrets`, not a committed dev secret** | `KC_BOOTSTRAP_ADMIN_PASSWORD: admin` and every client secret in `realm-export.json` (`devsecret`) are committed in plain text to this git history. That is only defensible because this repository targets a local `kind` cluster nobody else can reach. Production must source these from a real secret store (this repository's own architecture already names `external-secrets` as the mechanism to project them into the cluster) and never from a file `git log` can show a stranger. |

## What does not change

Everything above Keycloak in this stack - the Gateway, the AuthPolicy, the
TokenRateLimitPolicy, the OpenAI-compatible API surface - only ever talks to
Keycloak through its OIDC issuer and JWKS endpoints. None of the four
requirements above touch that contract. Moving to production Keycloak is a
change to `platform/15-keycloak/` alone, not a redesign of anything that
depends on it.
