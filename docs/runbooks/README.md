# Runbooks

What to do when something breaks, written before it breaks.

Planned:
- Recovery drill: delete the namespace, let Argo CD rebuild, measure time to the
  first successful token. That number is the real recovery time objective.
- Cold start is slow: where the time goes and which cache is missing.
- Quota rejections (429) in normal traffic: tier misconfigured, or a real abuse.
- Running Keycloak for real: database, clustering, and backups, which this
  repository deliberately does not build.
