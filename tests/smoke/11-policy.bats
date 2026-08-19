setup() { load '../lib/helpers'; }

# The image is DIGEST-pinned, and that is the point of this test rather than
# an incidental detail. The earlier version used busybox:1.36, which
# disallow-floating-tags rejects as well (its pattern is `*@sha256:*`, so any
# tag fails it) - so this test passed whether or not
# require-resource-limits.yaml existed at all. Deleting that policy entirely
# left it green. With a digest-pinned image and no `resources` block, the
# limits policy is the only one of the three that can reject this pod.
#
# The digest is images.curl from versions.yaml, reused rather than adding a
# new pin. The pod is rejected at admission and never runs, so nothing in the
# image is executed.
@test "a pod without resource limits is rejected" {
  run k -n llm run nolimits \
    --image=curlimages/curl:8.21.0@sha256:56bc0130aabaada5c04bb18d8d7f75e7a78fbcaa38ad44e1811c8c7720606d84 \
    --restart=Never --command -- sleep 1
  [ "$status" -ne 0 ]
  # Assert WHO rejected it, not merely that something failed. `status -ne 0`
  # alone is satisfied by a missing namespace, an expired credential, an RBAC
  # denial, or a typo - so this test used to pass on a cluster with no Kyverno
  # installed at all.
  #
  # The two strings below are copied from the real rejection, observed on a live
  # kind cluster on 2026-08-19 after platform/12-kyverno/install.sh:
  #   Error from server: admission webhook "validate.kyverno.svc-fail" denied
  #   the request: resource Pod/llm/probe-nolimits was blocked due to the
  #   following policies  require-resource-limits:  check-limits: 'validation
  #   error: cpu and memory limits are required on every container, ...
  [[ "$output" == *"validate.kyverno.svc"* ]] || fail "not rejected by Kyverno: $output"
  [[ "$output" == *"require-resource-limits"* ]] || fail "wrong policy rejected it: $output"
}

@test "a floating image tag is rejected" {
  run k -n llm run floating --image=busybox:latest --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:latest","resources":{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}}]}}' \
    --command -- sleep 1
  [ "$status" -ne 0 ]
  # Same reasoning as the test above. Message observed on a live cluster,
  # 2026-08-19: `disallow-floating-tags: require-digest-or-fixed-tag:
  # 'validation error: every image must be pinned by digest, not a floating
  # tag - init containers included.'`
  [[ "$output" == *"validate.kyverno.svc"* ]] || fail "not rejected by Kyverno: $output"
  [[ "$output" == *"disallow-floating-tags"* ]] || fail "wrong policy rejected it: $output"
}

@test "every overlay in the repository builds" {
  for o in models/*/overlays/*; do
    run kustomize build "$o"
    [ "$status" -eq 0 ]
  done
}
