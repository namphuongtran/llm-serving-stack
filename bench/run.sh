#!/usr/bin/env bash
# Measures through the public endpoint only, so the same harness works against
# llama.cpp locally and vLLM on GPU nodes.
set -euo pipefail
cd "$(dirname "$0")/.."

DATE="$(date +%Y-%m-%d)"
MACHINE="$(uname -m)-$(sysctl -n machdep.cpu.brand_string 2>/dev/null | tr ' ' '-' | tr -d '()' || echo unknown)"
ENGINE_IMAGE="$(kubectl -n llm get pod -l serving.kserve.io/inferenceservice=ornith-9b \
  -o jsonpath='{.items[0].spec.containers[?(@.name=="kserve-container")].image}')"
ENGINE_NAME="$(basename "${ENGINE_IMAGE%%@*}" | cut -d: -f1)"
OUT="bench/results/${DATE}-${MACHINE}-${ENGINE_NAME}"
mkdir -p "$OUT"

TOKEN="$(source tests/lib/helpers.bash && get_token llm-tier-pro)"

jq -n \
  --arg date "$DATE" --arg machine "$MACHINE" --arg engine_image "$ENGINE_IMAGE" \
  --arg model "$(yq -r '.model.local.hf_file' models/ornith-9b/base/model.yaml)" \
  --arg replicas "$(kubectl -n llm get deploy ornith-9b-predictor -o jsonpath='{.spec.replicas}')" \
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
