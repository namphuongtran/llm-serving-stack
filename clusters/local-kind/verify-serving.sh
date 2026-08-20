#!/usr/bin/env bash
# The last command of `task local:up`, after wait-for-sync.sh.
#
# WHY IT EXISTS. On 2026-08-20 run 3 of the pull path exited 0 with all sixteen
# Applications Synced and Healthy, and the gateway served `/v1/models` to an
# unauthenticated caller. Every object had been applied. Nothing was enforcing.
#
# Applications being green says the manifests reached the cluster. It does not
# say the request path works, and acceptance criterion 1 asks for a ready
# service. This script is the difference between those two claims.
#
# It changes nothing. It reports, and on failure it prints the two diagnoses
# that actually explained the failure that day, so a red run is actionable
# rather than a mystery.
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=tests/lib/helpers.bash
source tests/lib/helpers.bash
require_cluster

BASE="http://${API_HOST}"
# Budget in seconds, argument 1. Default 600. It is an argument so the failure
# path can be exercised in seconds rather than ten minutes; see the mutation
# check recorded in docs/deployment-walkthrough.md.
BUDGET="${1:-600}"
DEADLINE=$(( $(date +%s) + BUDGET ))

# Prints the HTTP code, or `curl-exit-N` when curl itself failed. The `||`
# form this replaced printed BOTH - curl writes `000` on a connection failure
# and then the `||` appended its own word, so a mutation run on 2026-08-20
# reported `returned 000curl-exit`. Same defect as the one fixed in
# tests/smoke/06-auth-quota.bats's chat(): capture the output and the code
# separately.
code() {
  local out rc
  out="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$@")"
  rc=$?
  if [ "$rc" -ne 0 ]; then printf 'curl-exit-%s' "$rc"; else printf '%s' "$out"; fi
}

diagnose() {
  printf '\n--- AuthPolicy conditions ---\n' >&2
  k -n llm get authpolicy llm-jwt \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {.message}{"\n"}{end}' >&2 || true
  printf -- '--- gateway wasm errors, if any ---\n' >&2
  k -n istio-system logs -l gateway.networking.k8s.io/gateway-name=llm --tail=200 2>/dev/null \
    | grep -iE 'wasm|failed to load' | tail -5 >&2 || true
  cat >&2 <<'HINT'
--- what these two mean ---
Accepted=False with reason MissingDependency: the Kuadrant operator started
before the Gateway API CRDs existed and caches that. It does not recover on its
own. Kubernetes restart backoff does not apply, because nothing crashed.
  kubectl -n kuadrant-system rollout restart deploy/kuadrant-operator-controller-manager

"Plugin kuadrant-wasm-shim failed to load" with "configured to fail closed":
the gateway could not fetch the Wasm module and is rejecting everything with
503. A restart makes it fetch again.
  kubectl -n istio-system rollout restart deploy/llm-istio

Both were needed by hand after run 3, which is why criterion 1 was not settled
by that run. See docs/deployment-walkthrough.md, "The pull-based path".
HINT
}

# 1. Unauthenticated must be REJECTED. This is the assertion run 3 would have
#    failed, and the reason this script exists. 503 is not a pass: it means the
#    gateway is rejecting everything, including valid tokens.
printf 'waiting for the gateway to reject an unauthenticated request\n'
got=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  got="$(code "$BASE/v1/models")"
  [ "$got" = "401" ] && break
  sleep 10
done
[ "$got" = "401" ] || {
  printf 'unauthenticated GET /v1/models returned %s, expected 401.\n' "$got" >&2
  printf 'A 200 means no policy is enforcing. A 503 means the gateway is failing closed.\n' >&2
  diagnose
  exit 1
}
printf 'unauthenticated request rejected with 401\n'

# 2. A real token must be ACCEPTED, and the model must be listed. Step 1 alone
#    would pass on a gateway that rejects everything.
token="$(get_token llm-tier-pro)"
[ -n "$token" ] && [ "$token" != "null" ] || {
  printf 'Keycloak returned no token for llm-tier-pro\n' >&2
  exit 1
}

printf 'waiting for the model to answer with a valid token\n'
got=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  got="$(code "$BASE/v1/models" -H "authorization: Bearer $token")"
  [ "$got" = "200" ] && break
  sleep 10
done
[ "$got" = "200" ] || {
  printf 'GET /v1/models with a valid JWT returned %s, expected 200\n' "$got" >&2
  diagnose
  exit 1
}

served="$(curl -s --max-time 60 "$BASE/v1/models" -H "authorization: Bearer $token" | jq -r '.data[].id' | tr '\n' ' ')"
printf 'the gateway serves: %s\n' "$served"
[ -n "$served" ] || { printf '/v1/models returned 200 with no model listed\n' >&2; exit 1; }
