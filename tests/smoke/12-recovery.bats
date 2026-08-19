setup() { load '../lib/helpers'; }

@test "recovery drill records a time to first token" {
  run bash -c "./bench/recovery-drill.sh"
  [ "$status" -eq 0 ]
  latest=$(ls -1dt bench/results/*-recovery/ | head -1)
  run bash -c "jq -r .seconds_to_first_token '${latest}result.json'"
  [ "$output" -gt 0 ]
}
