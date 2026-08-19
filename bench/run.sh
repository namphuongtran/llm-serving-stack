#!/usr/bin/env bash
# Measures through the public endpoint only, so the same harness works against
# llama.cpp locally and vLLM on GPU nodes.
set -euo pipefail
cd "$(dirname "$0")/.."

# Sourced at top level, not inside a command substitution: that is what
# makes KUBECTL_CONTEXT and the k() wrapper available to every kubectl call
# below, not just to get_token. Every other script and test in this
# repository queries the cluster through k() or an explicit --context; a
# bare `kubectl` here would silently target whatever context happens to be
# current on the machine running this, which is not necessarily
# kind-llm-serving-stack.
source tests/lib/helpers.bash

DATE="$(date +%Y-%m-%d)"
MACHINE="$(uname -m)-$(sysctl -n machdep.cpu.brand_string 2>/dev/null | tr ' ' '-' | tr -d '()' || echo unknown)"
ENGINE_IMAGE="$(k -n llm get pod -l serving.kserve.io/inferenceservice=ornith-9b \
  -o jsonpath='{.items[0].spec.containers[?(@.name=="kserve-container")].image}')"
ENGINE_NAME="$(basename "${ENGINE_IMAGE%%@*}" | cut -d: -f1)"
OUT="bench/results/${DATE}-${MACHINE}-${ENGINE_NAME}"
mkdir -p "$OUT"

TOKEN="$(get_token llm-tier-pro)"

jq -n \
  --arg date "$DATE" --arg machine "$MACHINE" --arg engine_image "$ENGINE_IMAGE" \
  --arg model "$(yq -r '.model.local.hf_file' models/ornith-9b/base/model.yaml)" \
  --arg replicas "$(k -n llm get deploy ornith-9b-predictor -o jsonpath='{.spec.replicas}')" \
  '{date:$date, machine:$machine, engine_image:$engine_image, model:$model, replicas:$replicas}' \
  > "$OUT/env.json"

for f in ${SCENARIOS:-bench/scenarios/*.json}; do
  name="$(jq -r .name "$f")"
  echo "== $name"
  python3 bench/harness.py --scenario "$f" --base-url "http://llm.localtest.me" \
    --token "$TOKEN" --model ornith-9b --out "$OUT/${name}.json"
done

python3 bench/summarise.py --dir "$OUT" > "$OUT/summary.md"
echo "wrote $OUT/summary.md"
