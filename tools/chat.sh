#!/usr/bin/env bash
# What `task chat` runs. Sends one streaming chat completion through the public
# gateway and prints the answer as each chunk arrives.
#
# This is the only human-facing way to talk to the model in this repository.
# Everything else that exercises the API is a bats suite
# (tests/contract/01-openai-api.bats) or the benchmark harness, and neither
# lets a person watch a sentence being written.
#
# It goes through the gateway, not to the pod, on purpose. The same request
# therefore passes the Istio Gateway, the ornith-9b-openai HTTPRoute, the
# Kuadrant AuthPolicy, and the TokenRateLimitPolicy. A 401 or a 429 here is
# the real policy path answering, not a mock.
#
# Same reason as tools/token.sh for being a script rather than a Taskfile
# command - see the comment there about go-task and `Authorization: Bearer`.
set -euo pipefail
cd "$(dirname "$0")/.."

PROMPT="${*:-Say hello in one short sentence.}"
CLIENT="${CLIENT:-llm-tier-pro}"
MODEL="${MODEL:-ornith-9b}"
BASE="${BASE_URL:-http://llm.localtest.me}"

# llm-tier-pro by default, not llm-tier-free. The free client exists to be cut
# off: tests/smoke/06-auth-quota.bats spends its budget on purpose to assert
# the 429. Run `CLIENT=llm-tier-free task chat` to see that happen.
TOKEN="$(./tools/token.sh "$CLIENT")"

# Path from models/ornith-9b/overlays/local/httproute.yaml, whose only rule is
# a PathPrefix match on /v1. bench/harness.py posts to the same URL.
BODY="$(jq -n --arg m "$MODEL" --arg p "$PROMPT" \
  '{model:$m, stream:true, messages:[{role:"user", content:$p}]}')"

echo "> $PROMPT" >&2
echo "  (client $CLIENT, model $MODEL, via $BASE)" >&2
echo >&2

# -N disables curl's output buffering, without which the whole answer arrives
# at once and there is nothing to watch. No -f: on a 401 or a 429 the body is
# the useful part, and -f throws it away.
#
# Anything that is not an SSE data line goes to stderr rather than being
# dropped, so an auth failure or a Kuadrant rate-limit body is visible instead
# of the command simply printing nothing.
curl -sN -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
| while IFS= read -r line; do
    case "$line" in
      "")
        continue
        ;;
      "data: [DONE]")
        printf '\n'
        break
        ;;
      "data: "*)
        # -j so chunks join into one flowing answer instead of one line each.
        # `// empty` because a chunk may carry only a role or a finish_reason.
        printf '%s' "${line#data: }" | jq -j '.choices[0].delta.content // empty'
        ;;
      *)
        printf '%s\n' "$line" >&2
        ;;
    esac
  done
