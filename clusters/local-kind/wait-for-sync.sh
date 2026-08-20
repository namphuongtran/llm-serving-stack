#!/usr/bin/env bash
# The last command of `task local:up`. It replaced a one-line
# `kubectl wait --for=jsonpath='{.status.health.status}'=Healthy ... --all`
# which, on 2026-08-20, exited 0 in one second on a cluster where the pull path
# had deployed nothing: an Application that never compared anything reports
# Healthy, because it has no resource to call unhealthy. The full account is in
# docs/deployment-walkthrough.md, "The pull-based path".
set -euo pipefail
cd "$(dirname "$0")/../.."

# For k() and KUBECTL_CONTEXT; bare kubectl would use whatever context is
# current, which on this machine has been docker-desktop.
# shellcheck source=tests/lib/helpers.bash
source tests/lib/helpers.bash
require_cluster

TIMEOUT="${1:-30m}"

# Sync status, not health status. It is the field that discriminates.
printf 'waiting for root-app to sync (timeout %s)\n' "$TIMEOUT"
k -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/root-app --timeout="$TIMEOUT" || {
  printf '\nroot-app did not sync. Its conditions say why -\n' >&2
  k -n argocd get application root-app \
    -o jsonpath='{range .status.conditions[*]}{.type}{" - "}{.message}{"\n"}{end}' >&2
  exit 1
}

# Count from disk, so the wait below cannot pass over a subset. `--all` does
# fail on an empty set (`no matching resources found`), but not on a partial
# one, and root-app syncing only proves Argo CD read the path.
want=$(( $(grep -h '^kind: Application' clusters/local-kind/apps/*.yaml | wc -l) + 1 ))
got=$(k -n argocd get applications.argoproj.io --no-headers | wc -l)
[ "$got" -eq "$want" ] || {
  printf 'expected %s Applications (%s in clusters/local-kind/apps/ plus root-app), found %s\n' \
    "$want" "$((want - 1))" "$got" >&2
  k -n argocd get applications.argoproj.io >&2
  exit 1
}
printf 'root-app synced and created all %s child Applications\n' "$((want - 1))"

# Sync before health: a child that has not synced has nothing deployed to be
# unhealthy about, so it would pass a health check for the reason above.
#
# NO `kubectl wait --all` past this point, and that is a deliberate removal.
# Two of them were here until 2026-08-20, one on sync status and one on health.
# Three things were wrong with them:
#
#   - They report per-object. On run 2 one wait printed 7 `condition met` lines
#     and 9 `timed out` lines, so a reader cannot tell whether the run was close
#     or nowhere near.
#   - They give no progress for the whole timeout, then fail all at once.
#   - Run 2 took 63 minutes wall clock (23:58:35Z to 01:01:35Z) against a 30m
#     timeout, and the log does not say where the extra time went. That is
#     reason enough not to build the acceptance check on them.
#
# The loop below replaces both. It asserts what the criterion actually needs -
# every Application Synced AND Healthy at the SAME MOMENT, three samples running
# - and it prints what is still wrong on the way, so a failed run says why.
# Simultaneity is not pedantry here: these Applications flap OutOfSync while
# their neighbours sync, so "each was green once" is a weaker claim than it looks.
need=3
streak=0
deadline=$(( $(date +%s) + $(printf '%s' "$TIMEOUT" | awk '
  /h$/ {print substr($0,1,length($0)-1) * 3600; next}
  /m$/ {print substr($0,1,length($0)-1) * 60;   next}
  /s$/ {print substr($0,1,length($0)-1);        next}
  {print $0}') ))
last=""
while [ "$streak" -lt "$need" ]; do
  # kubectl and grep are separated on purpose. `grep -v` exits 1 when it prints
  # nothing, which here is the success case, so it needs `|| true` - and a
  # single pipeline would let `|| true` swallow a kubectl failure too, leaving
  # `bad` empty and this loop counting a dead cluster as all-green.
  all=$(k -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}') || {
    printf 'cannot read Applications from %s\n' "$KUBECTL_CONTEXT" >&2
    exit 1
  }
  [ -n "$all" ] || { printf 'no Applications found at all\n' >&2; exit 1; }
  bad=$(printf '%s\n' "$all" | grep -v '=Synced/Healthy$' || true)
  if [ -z "$bad" ]; then
    streak=$((streak + 1))
    printf 'all Applications Synced and Healthy (%s of %s consecutive samples)\n' \
      "$streak" "$need"
  else
    streak=0
    # Print only when the set of laggards changes, so a long wait leaves a
    # readable trail instead of one line every ten seconds.
    if [ "$bad" != "$last" ]; then
      printf '%s waiting on %s -\n%s\n' "$(date -u +%H:%M:%SZ)" \
        "$(printf '%s\n' "$bad" | wc -l | tr -d ' ')" "$bad"
      last="$bad"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || {
      printf '\ntimed out after %s. Still not Synced/Healthy together -\n%s\n' \
        "$TIMEOUT" "$bad" >&2
      exit 1
    }
  fi
  sleep 10
done

k -n argocd get applications.argoproj.io
