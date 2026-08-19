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

# The kind node image is the one image reference in this repository that
# `.images` does not cover, so the test above never looked at it. It lives
# under `.kubernetes.kind_node` instead, and until 2026-08-19 nothing read
# it at all: prereqs/kind-cluster.yaml set no node `image:` and Taskfile.yml
# passes no --image, so the cluster took whatever the local kind binary
# defaulted to. Both halves are checked here: the pin resolves to a real
# arm64 manifest, and every node in the cluster config actually uses it.
@test "the kind node image is pinned and has a linux/arm64 manifest" {
  ref="$(yq -r '.kubernetes.kind_node' versions.yaml)"
  [ -n "$ref" ]
  [ "$ref" != "null" ]
  case "$ref" in *@sha256:*) ;; *) echo "kind_node is not digest-pinned: $ref" >&2; false ;; esac
  run require_arm64 "$ref"
  [ "$status" -eq 0 ]
}

@test "every kind node uses the pinned node image" {
  ref="$(yq -r '.kubernetes.kind_node' versions.yaml)"
  run bash -c "yq -r '.nodes[].image' prereqs/kind-cluster.yaml"
  [ "$status" -eq 0 ]
  node_count="$(yq -r '.nodes | length' prereqs/kind-cluster.yaml)"
  # Every line must equal the pin, and there must be one line per node - so a
  # node with no image: (which yq prints as "null") fails here rather than
  # silently taking the kind binary's default.
  matching="$(printf '%s\n' "$output" | grep -cx -- "$ref" || true)"
  [ "$matching" -eq "$node_count" ]
}
