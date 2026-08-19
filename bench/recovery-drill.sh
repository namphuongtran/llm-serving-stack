#!/usr/bin/env bash
# Destroys the workload namespace and measures how long Argo CD needs to get
# back to a first answered token. That number, not the time to Ready, is the
# recovery time objective for an LLM service.
#
# The measured number is the arrival of the first `data:` chunk of a streamed
# chat completion. An earlier version of this script polled `GET /v1/models`
# and recorded that elapsed time under the name `seconds_to_first_token`,
# which measured no token at all: `/v1/models` answers as soon as the server
# is listening, before any weight has been through a forward pass. Both
# numbers are now recorded, under names that say what each one is.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="http://llm.localtest.me"
OUT="bench/results/$(date +%Y-%m-%d)-recovery"
mkdir -p "$OUT"

start_epoch=$(date +%s)
kubectl delete namespace llm --wait=true

# Argo CD rebuilds without human help. If it does not, the drill has found a
# manual step and that is the finding.
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  applications.argoproj.io --all --timeout=40m

TOKEN="$(source tests/lib/helpers.bash && get_token llm-tier-pro)"

# Readiness gate, kept: it is the cheapest way to know the endpoint exists
# before opening a stream against it. It is recorded separately and is NOT
# the headline number.
until curl -sf "$BASE/v1/models" -H "authorization: Bearer $TOKEN" >/dev/null; do
  sleep 5
done
models_epoch=$(date +%s)

# The real measurement: one streaming chat completion, timed to the arrival
# of its first `data:` chunk.
#
# The stream is written to a file by a background curl and polled here rather
# than piped into a reader, on purpose. Under `set -o pipefail` a reader that
# breaks out on the first match makes curl exit on SIGPIPE, and the whole
# script would die at the moment it succeeded.
stream_log="$OUT/first-stream.txt"
: > "$stream_log"

curl -sN --no-buffer --max-time 900 "$BASE/v1/chat/completions" \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"model":"ornith-9b","messages":[{"role":"user","content":"Say hello."}],"max_tokens":16,"stream":true}' \
  > "$stream_log" 2>/dev/null &
stream_pid=$!

first_token_epoch=""
while [ -z "$first_token_epoch" ]; do
  if grep -q '^data: ' "$stream_log" 2>/dev/null; then
    first_token_epoch=$(date +%s)
    break
  fi
  # curl exited without ever writing a data: line - the request failed, or
  # the answer was not a stream. Stop waiting and report it.
  kill -0 "$stream_pid" 2>/dev/null || break
  sleep 1
done

kill "$stream_pid" 2>/dev/null || true
wait "$stream_pid" 2>/dev/null || true

if [ -z "$first_token_epoch" ]; then
  echo "recovery drill: the streamed completion produced no 'data:' chunk" >&2
  echo "see $stream_log for what came back instead" >&2
  exit 1
fi

elapsed=$((first_token_epoch - start_epoch))
models_elapsed=$((models_epoch - start_epoch))

jq -n --arg s "$elapsed" \
  --arg m "$models_elapsed" \
  --arg model "$(yq -r '.model.local.hf_file' models/ornith-9b/base/model.yaml)" \
  --arg machine "$(uname -m)" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{seconds_to_first_token: ($s|tonumber),
    seconds_to_models_endpoint: ($m|tonumber),
    measured_as: "elapsed from namespace delete to the first data: chunk of a streamed POST /v1/chat/completions",
    model: $model, machine: $machine, date: $date}' \
  > "$OUT/result.json"

printf 'recovery: %s seconds to the first streamed token (%s seconds to /v1/models)\n' \
  "$elapsed" "$models_elapsed" | tee "$OUT/summary.md"
