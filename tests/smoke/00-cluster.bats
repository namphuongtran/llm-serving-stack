setup() {
  load '../lib/helpers'
  # Every assertion below is about cluster state, so a suite that cannot reach the
  # API server must fail rather than report anything. Added across the suites on
  # 2026-08-20: with Docker down, five files gave 4 passes and 22 failures, and
  # three of those four passes were bare `[ "$status" -ne 0 ]` assertions
  # satisfied by kubectl failing to connect. See require_cluster in ../lib/helpers.
  require_cluster
}

@test "cluster exists with three nodes" {
  run k get nodes --no-headers
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

# `kubectl ... | grep -vc ' Ready '` prints 0 on empty input, so the old
# version of this test passed when kubectl failed outright - no cluster, wrong
# context, expired credentials all read as "zero nodes are not Ready". The
# kubectl call is asserted on its own first, and the output is required to be
# non-empty, before anything is counted.
@test "all nodes are Ready" {
  run k get nodes --no-headers
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  not_ready="$(printf '%s\n' "$output" | grep -vc ' Ready ' || true)"
  [ "$not_ready" -eq 0 ]
}

@test "versions.yaml has no empty pins" {
  run bash -c "yq -r '.. | select(type == \"!!str\") | select(. == \"\")' versions.yaml | wc -l | tr -d ' '"
  [ "$output" -eq 0 ]
}
