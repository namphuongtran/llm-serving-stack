setup() {
  load '../lib/helpers'
  # This suite was the ONE that never got require_cluster when the other eleven
  # did on 2026-08-20. Its assertions are all about a live gateway.
  require_cluster
  BASE="http://llm.localtest.me"
}

# chat <token> <max_tokens>
#
# --max-time is not optional here, and its absence was a real defect. On the
# first CI run this repository ever had (2026-08-20) this suite failed at
# `a valid token is accepted` and then produced NO further output for 39
# minutes, until the job's own `timeout-minutes: 45` killed it. The cause is
# below in the 429 test: an unbounded loop of unbounded requests. Timings from
# that run - test 28 finished at 00:03:50Z, the job was cancelled at 00:43:18Z.
#
# It ALWAYS exits 0, and prints either the HTTP code or `curl-exit-N`.
#
# The first version of this fix did not, and that was its own defect. curl exits
# 28 on `--max-time`, so `code="$(chat "$token" 64)"` aborted the whole test on
# the first slow request - observed 2026-08-20, the 429 test died at line 88 with
# status 28. Recording what happened and carrying on is the entire point of the
# loop below; a helper that aborts it defeats that.
#
# 240s, and the number comes from measurement rather than taste. llama.cpp
# reports 0.55 tokens per second on this machine (see the 429 test below for the
# log line), so a 64-token completion needs about 116 seconds of eval before
# prompt processing. The first version of this fix used 120s, which would fire on
# a healthy stack. 240s is roughly double the expected time; the HTTPRoute itself
# allows 600s.
#
# One measurement that looks worse than this and should not be read that way:
# a curl for a 64-token completion returned HTTP 000 after `--max-time 300` on
# 2026-08-20. The two requests after it returned HTTP 500 in under a second, so
# the server was already saturated by a concurrent bats run. That number is
# contention, not latency, and it is not what 240 is derived from.
chat() {
  local out rc
  out="$(curl -s --max-time 240 -o /dev/null -w '%{http_code}' "$BASE/v1/chat/completions" \
    -H "authorization: Bearer $1" -H 'content-type: application/json' \
    -d "{\"model\":\"ornith-9b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":$2}")"
  rc=$?
  if [ "$rc" -ne 0 ]; then printf 'curl-exit-%s' "$rc"; else printf '%s' "$out"; fi
  return 0
}

# require_serving — block until the model answers, or fail saying it never did.
#
# The tests below assert HTTP 200 from a model that has to load weights first.
# Nothing in this suite waited for that, so on the CI run above
# `a valid token is accepted` was asked at 00:03:50Z, seconds after the platform
# finished installing. The observability job on the same commit needed 53
# seconds just to reach "readiness becomes true and the model answers".
require_serving() {
  local token="$1"
  wait_for 600 "the predictor to answer /v1/models with a valid token" \
    curl -sf --max-time 30 -o /dev/null "$BASE/v1/models" \
      -H "authorization: Bearer $token"
}

# require_token <client> — get a token, or fail naming the client.
#
# `get_token` prints `null` when Keycloak refuses, and `null` sent as a bearer
# token produces a 401, so without this check a broken client secret would look
# like an AuthPolicy that works.
require_token() {
  local t
  t="$(get_token "$1")"
  [ -n "$t" ] && [ "$t" != "null" ] || fail "Keycloak returned no token for client $1"
  printf '%s' "$t"
}

@test "no token is rejected with 401" {
  run bash -c "curl -s --max-time 30 -o /dev/null -w '%{http_code}' $BASE/v1/models"
  [ "$output" = "401" ]
}

@test "a forged token is rejected with 401" {
  run bash -c "curl -s --max-time 30 -o /dev/null -w '%{http_code}' -H 'authorization: Bearer not.a.jwt' $BASE/v1/models"
  [ "$output" = "401" ]
}

@test "a valid token is accepted" {
  token="$(require_token llm-tier-pro)"
  require_serving "$token"
  run chat "$token" 16
  [ "$output" = "200" ] || fail "a valid pro-tier token got $output, not 200"
}

# Acceptance criterion 4. Two bounds, not one.
#
# The old form was `for i in $(seq 1 40)` with no deadline and no timeout on the
# request, and it is what hung CI for 39 minutes. A count alone is not a bound
# when each iteration can take arbitrarily long.
#
# It also reports the codes it saw. The old form asserted `[ "$code" = "429" ]`
# on the last code only, so a run where every request returned 500 was
# indistinguishable from one where the quota simply never ran out.
@test "the free tier is cut off with 429 once its token budget is spent" {
  token="$(require_token llm-tier-free)"
  require_serving "$token"

  local started=$SECONDS
  local deadline=$((SECONDS + 900))
  local attempts=0
  local code=""
  local seen=""
  while [ "$attempts" -lt 40 ] && [ "$SECONDS" -lt "$deadline" ]; do
    code="$(chat "$token" 64)"
    attempts=$((attempts + 1))
    seen="$seen $code"
    [ "$code" = "429" ] && break
  done

  # The failure message carries the arithmetic, because two very different
  # causes look identical from a red test: a quota that does not work, and a
  # stack too slow to spend the quota inside its own window.
  #
  # security/oidc/tokenratelimitpolicy.yaml gives the free tier 500 tokens per
  # 60s window, and the counter only advances once a response reports its usage.
  # So the budget can only be exceeded if the stack generates more than 500
  # tokens in 60 seconds. It does not come close. llama.cpp's own timing log on
  # the local kind cluster, 2026-08-20:
  #   eval time = 12633.52 ms / 8 tokens (1804.79 ms per token,
  #                                       0.55 tokens per second)
  # 0.55 tokens per second is 33 tokens in a 60 second window, against a 500
  # token budget. The window resets about fifteen times before the budget could
  # be spent, so no number of requests trips it. A curl for one 64-token
  # completion the same day returned HTTP 000 after `--max-time 300`, which says
  # the same thing from the client side.
  #
  # This is a limits question, not a test bug. Settling criterion 4 locally needs
  # either a free-tier budget in reach of this engine, or a faster engine.
  [ "$code" = "429" ] \
    || fail "the free tier never returned 429 after $attempts requests in $((SECONDS - started))s. Codes seen:$seen -- if these are all 200, compare the tokens this stack can generate in the policy's 60s window against its 500-token budget before treating it as a quota bug."
}

@test "the pro tier still works after the free tier is limited" {
  token="$(require_token llm-tier-pro)"
  require_serving "$token"
  run chat "$token" 16
  [ "$output" = "200" ] || fail "a pro-tier token got $output after the free tier was limited, not 200"
}
