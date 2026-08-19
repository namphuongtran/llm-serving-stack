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

# Sourced at TOP LEVEL, not inside a command substitution, and that placement
# is the whole point. This script deletes a namespace. Until 2026-08-19 the
# helpers were sourced only inside the `TOKEN=` substitution below, so
# KUBECTL_CONTEXT and k() did not exist at the `delete namespace` line, and
# that line ran bare `kubectl` against whatever context happened to be
# current. On the machine where this was found, `kubectl config
# current-context` was `docker-desktop`.
#
# That is not a silent failure, it is a silent success against the wrong
# cluster, which is worse. bench/run.sh:7-13 already carried the written
# warning against exactly this; this file now follows it.
# shellcheck source=tests/lib/helpers.bash
source tests/lib/helpers.bash

BASE="http://llm.localtest.me"
OUT="bench/results/$(date +%Y-%m-%d)-recovery"
mkdir -p "$OUT"

# Refuse to run at all unless the kind cluster actually answers. A drill whose
# whole first act is `delete namespace` does not get to guess.
#
# `k version` and not `k config current-context`. The latter was here until
# 2026-08-20 and was a no-op: `kubectl config current-context` reads the
# kubeconfig file, never contacts a cluster, and ignores `--context` entirely.
# Confirmed by running it with the daemon down:
#   kubectl --context does-not-exist config current-context
#   -> kind-llm-serving-stack, exit 0
# So the guard could only fail when kubeconfig had no current-context at all, and
# its message ("is not reachable") was false. Routing through k() does fix the
# wrong-cluster risk; this line is what makes the reachability claim true.
k version --request-timeout=10s >/dev/null 2>&1 || {
  printf 'recovery-drill: context %s does not answer, refusing to delete anything\n' \
    "$KUBECTL_CONTEXT" >&2
  exit 1
}

start_epoch=$(date +%s)
k delete namespace llm --wait=true

# Argo CD rebuilds without human help. If it does not, the drill has found a
# manual step and that is the finding.
k -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  applications.argoproj.io --all --timeout=40m

TOKEN="$(get_token llm-tier-pro)"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || {
  printf 'recovery-drill: get_token returned no usable token\n' >&2
  exit 1
}

# Readiness gate, kept: it is the cheapest way to know the endpoint exists
# before opening a stream against it. It is recorded separately and is NOT
# the headline number.
# Bounded, using the helper the rest of the repository already uses. This was
# a bare `until ... sleep 5` loop with no deadline until 2026-08-19: if the
# endpoint never came back, `task drill:recovery` hung with no output and the
# recovery time objective was neither produced nor refuted. 40m matches the
# Argo CD wait above it.
wait_for 2400 "the gateway to answer /v1/models after the namespace rebuild" \
  curl -sf "$BASE/v1/models" -H "authorization: Bearer $TOKEN"
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
