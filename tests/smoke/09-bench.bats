setup() { load '../lib/helpers'; }

@test "bench run produces a dated result directory with an environment record" {
  run bash -c "SCENARIOS=bench/scenarios/01-short.json ./bench/run.sh"
  [ "$status" -eq 0 ]
  latest=$(ls -1dt bench/results/*/ | head -1)
  [ -f "${latest}env.json" ]
  [ -f "${latest}summary.md" ]
  run bash -c "jq -r '.date, .machine, .engine_image' '${latest}env.json' | grep -c ."
  [ "$output" -eq 3 ]
}
