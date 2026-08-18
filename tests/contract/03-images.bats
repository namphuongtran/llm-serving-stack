setup() { load '../lib/helpers'; }

@test "every pinned image has a linux/arm64 manifest" {
  while read -r ref; do
    [ -n "$ref" ] || continue
    run require_arm64 "$ref"
    [ "$status" -eq 0 ] || { echo "not arm64: $ref" >&2; false; }
  done < <(yq -r '.images | to_entries[] | .value' versions.yaml)
}

@test "the KServe HuggingFace runtime is still amd64 only, as ADR 0005 states" {
  # If this ever fails, the constraint behind ADR 0005 has changed and the ADR
  # needs a successor. A test is how a dated fact stays honest.
  run require_arm64 "kserve/huggingfaceserver:v0.20.0"
  [ "$status" -ne 0 ]
}
