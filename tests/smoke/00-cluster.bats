setup() { load '../lib/helpers'; }

@test "cluster exists with three nodes" {
  run k get nodes --no-headers
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "all nodes are Ready" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get nodes --no-headers | grep -vc ' Ready '"
  [ "$output" -eq 0 ]
}

@test "versions.yaml has no empty pins" {
  run bash -c "yq -r '.. | select(type == \"!!str\") | select(. == \"\")' versions.yaml | wc -l | tr -d ' '"
  [ "$output" -eq 0 ]
}
