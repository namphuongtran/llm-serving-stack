setup() {
  load '../lib/helpers'
  # Every assertion below is about cluster state, so a suite that cannot reach the
  # API server must fail rather than report anything. Added across the suites on
  # 2026-08-20: with Docker down, five files gave 4 passes and 22 failures, and
  # three of those four passes were bare `[ "$status" -ne 0 ]` assertions
  # satisfied by kubectl failing to connect. See require_cluster in ../lib/helpers.
  require_cluster
  BASE="http://llm.localtest.me"
  SELECTOR="serving.kserve.io/inferenceservice=ornith-9b"

  # A token is fetched and sent even where nothing checks it, which is what
  # tests/contract/01-openai-api.bats already does. This suite runs in two CI
  # jobs with different platforms installed: `smoke` applies
  # security/oidc/authpolicy.yaml, and `observability` does not install Kuadrant
  # at all. Sending an empty bearer where there is no AuthPolicy is harmless;
  # sending none where there is one is a 401.
  #
  # Not sending it is what broke this suite on 2026-08-20. `readiness becomes
  # true and the model answers` passed in the observability job and failed in the
  # smoke job on the same commit, from one unauthenticated curl.
  TOKEN="$(get_token llm-tier-pro 2>/dev/null || true)"
  AUTH="authorization: Bearer $TOKEN"
}

# pod_names — the current predictor pod names, space separated.
pod_names() {
  k -n llm get pod -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}'
}

# container_ready <pod> — prints `true`, `false`, or nothing when the container
# has no status yet.
container_ready() {
  k -n llm get pod "$1" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="kserve-container")].ready}'
}

# REWRITTEN 2026-08-20, after this test failed in both CI cluster jobs on the
# first two CI runs this repository ever had.
#
# The old form deleted the predictor pods, slept 5 seconds, then read
# `.items[0].status.containerStatuses[...].ready` and asserted it was not `true`.
# Two defects, and they pull in opposite directions:
#
#   - `.items[0]` is whichever pod the API server lists first. After a delete
#     with `--wait=false` the OLD pod is still Terminating and still reports
#     `ready: true`, and the local overlay runs two replicas so an untouched one
#     is there too. That is the failure CI hit - `[ "$output" != "true" ]` with
#     output `true`.
#   - When the replacement pod exists but its container has not started, there is
#     no `containerStatuses` entry at all, so the query prints nothing, and an
#     empty string is not `true`. The old assertion PASSED on that, having
#     observed nothing whatsoever. A test that can pass by measuring nothing is
#     the defect class this whole suite exists to catch.
#
# This form names the pod it is talking about, and waits for a readiness value to
# exist before judging it.
@test "readiness is false while weights are still loading" {
  local old new deadline ready
  old=" $(pod_names) "
  [ "$old" != "  " ] || fail "no predictor pod to restart; the InferenceService is not running"

  k -n llm delete pod -l "$SELECTOR" --wait=false

  # A pod whose name is not one of the old ones. Name identity, not a sleep.
  new=""
  deadline=$((SECONDS + 180))
  while [ -z "$new" ] && [ "$SECONDS" -lt "$deadline" ]; do
    for p in $(pod_names); do
      case "$old" in *" $p "*) ;; *) new="$p"; break ;; esac
    done
    [ -n "$new" ] || sleep 2
  done
  [ -n "$new" ] || fail "no replacement predictor pod appeared within 180s. Old pods were:$old"

  # Wait for a readiness value to EXIST, so an absent containerStatuses cannot
  # be read as "not ready".
  ready=""
  deadline=$((SECONDS + 180))
  while [ -z "$ready" ] && [ "$SECONDS" -lt "$deadline" ]; do
    ready="$(container_ready "$new")"
    [ -n "$ready" ] || sleep 2
  done
  [ -n "$ready" ] || fail "pod $new never reported a kserve-container readiness value within 180s, so nothing was observed"

  [ "$ready" = "false" ] \
    || fail "replacement pod $new reported ready=[$ready] on its first readiness value. Expected false while weights load. If this engine really does load fast enough to be ready before its first status update, the contract this test asserts needs restating rather than retiming."
}

@test "readiness becomes true and the model answers" {
  run wait_for 900 "predictor to become ready after reload" bash -c \
    "kubectl --context $KUBECTL_CONTEXT -n llm get inferenceservice ornith-9b \
      -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
  [ "$status" -eq 0 ]
  run bash -c "curl -sf --max-time 60 $BASE/v1/models -H \"$AUTH\" | jq -e '.data | length > 0'"
  [ "$status" -eq 0 ] || fail "the model reported Ready but /v1/models did not list a model. Output: $output"
}
