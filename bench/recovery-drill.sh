#!/usr/bin/env bash
# Destroys the workload namespace and measures how long Argo CD needs to get
# back to a first answered token. That number, not the time to Ready, is the
# recovery time objective for an LLM service.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="bench/results/$(date +%Y-%m-%d)-recovery"
mkdir -p "$OUT"

start=$SECONDS
kubectl delete namespace llm --wait=true

# Argo CD rebuilds without human help. If it does not, the drill has found a
# manual step and that is the finding.
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  applications.argoproj.io --all --timeout=40m

TOKEN="$(source tests/lib/helpers.bash && get_token llm-tier-pro)"
until curl -sf http://llm.localtest.me/v1/models -H "authorization: Bearer $TOKEN" >/dev/null; do
  sleep 5
done
elapsed=$((SECONDS - start))

jq -n --arg s "$elapsed" \
  --arg model "$(yq -r '.model.local.hf_file' models/ornith-9b/base/model.yaml)" \
  --arg machine "$(uname -m)" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{seconds_to_first_token: ($s|tonumber), model: $model, machine: $machine, date: $date}' \
  > "$OUT/result.json"

printf 'recovery: %s seconds to first token\n' "$elapsed" | tee "$OUT/summary.md"
