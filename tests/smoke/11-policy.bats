setup() { load '../lib/helpers'; }

@test "a pod without resource limits is rejected" {
  run k -n llm run nolimits --image=busybox:1.36 --restart=Never --command -- sleep 1
  [ "$status" -ne 0 ]
}

@test "a floating image tag is rejected" {
  run k -n llm run floating --image=busybox:latest --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:latest","resources":{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}}]}}' \
    --command -- sleep 1
  [ "$status" -ne 0 ]
}

@test "every overlay in the repository builds" {
  for o in models/*/overlays/*; do
    run kustomize build "$o"
    [ "$status" -eq 0 ]
  done
}
