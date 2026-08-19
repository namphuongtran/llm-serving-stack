setup() {
  load '../lib/helpers'
  # Every negative assertion in this file is `[ "$status" -ne 0 ]`, which any
  # kubectl failure satisfies. With Docker down on 2026-08-20, three of them
  # passed with no cluster at all. This guard makes that impossible; each of the
  # three also now asserts its own cause. See require_cluster in ../lib/helpers.
  require_cluster
}

@test "KServe CRDs exist" {
  for crd in inferenceservices.serving.kserve.io servingruntimes.serving.kserve.io clusterservingruntimes.serving.kserve.io; do
    run k get crd "$crd"
    [ "$status" -eq 0 ]
  done
}

@test "controller is available" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get deploy -n kserve -o jsonpath='{.items[*].status.availableReplicas}'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [1-9] ]]
}

@test "Knative is NOT installed" {
  run k get crd services.serving.knative.dev
  [ "$status" -ne 0 ]
  # Assert it is ABSENT, not merely that the command failed. A wrong context, an
  # RBAC denial, or an unreachable API server all satisfy `-ne 0`; only NotFound
  # means Knative is actually not installed. Confirmed 2026-08-20 that this test
  # passed against a dead cluster before the check was added.
  [[ "$output" == *NotFound* || "$output" == *"not found"* ]] \
    || fail "not a NotFound, so this proves nothing about Knative: $output"
}

@test "default deployment mode is RawDeployment" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get cm -n kserve inferenceservice-config -o jsonpath='{.data.deploy}' | jq -r .defaultDeploymentMode"
  [ "$output" = "RawDeployment" ]
}

@test "Gateway API is enabled, not left at the default false" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get cm -n kserve inferenceservice-config -o jsonpath='{.data.ingress}' | jq -r .enableGatewayApi"
  [ "$output" = "true" ]
}

# Asserts the VALUE, not that the key exists. With enableGatewayApi: true,
# kserveIngressGateway is the key KServe reads to decide which Gateway its
# generated HTTPRoute attaches to, and it is a separate chart key from
# `gateway`/ingressGateway. Setting only the latter leaves this one at the
# chart default kserve/kserve-ingress-gateway - a Gateway this repository
# never creates - and the failure is silent: helm renders fine, the install
# succeeds, and the only symptom is InferenceService IngressReady that never
# turns true, which tests/contract/02-readiness.bats then waits 900s for.
@test "kserveIngressGateway points at the Gateway this repository creates" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get cm -n kserve inferenceservice-config -o jsonpath='{.data.ingress}' | jq -r .kserveIngressGateway"
  [ "$status" -eq 0 ]
  [ "$output" = "istio-system/llm" ]
}

# KServe must not generate its own HTTPRoutes. Theirs carry the hostname
# `<isvc>-<ns>.<ingressDomain>`, which the single listener on
# platform/10-istio/gateway.yaml does not match, and they would carry neither
# the Kuadrant policies nor the 600s streaming timeouts. With this true KServe
# marks IngressReady true directly, and the route in
# models/ornith-9b/overlays/local/httproute.yaml is the only one.
@test "KServe does not generate its own ingress routes" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get cm -n kserve inferenceservice-config -o jsonpath='{.data.ingress}' | jq -r .disableIngressCreation"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "no KServe-generated HTTPRoute exists for the model" {
  # Same reasoning as "Knative is NOT installed" above: NotFound is the only
  # failure that means what this test claims. Both names are checked, and both
  # must be absent for the reason stated rather than for any reason.
  for name in ornith-9b ornith-9b-predictor; do
    run k -n llm get httproute "$name"
    [ "$status" -ne 0 ] || fail "KServe generated an HTTPRoute named $name, which disableIngressCreation should have prevented"
    [[ "$output" == *NotFound* || "$output" == *"not found"* ]] \
      || fail "httproute/$name lookup failed for a reason other than absence: $output"
  done
}

@test "the admission webhook rejects an invalid InferenceService" {
  run k apply -f - <<'YAML'
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata: { name: invalid-on-purpose, namespace: llm }
spec:
  predictor: {}
YAML
  [ "$status" -ne 0 ]
  # The whole point of this test is that a WEBHOOK rejected it. Before
  # 2026-08-20 it asserted only that apply failed, so it reported success with no
  # webhook, no CRD, and no cluster - the single most misleading pass in the
  # suite. The message must name the admission webhook.
  [[ "$output" == *"admission webhook"* ]] \
    || fail "apply failed, but not at admission, so the webhook is unproven: $output"
}
