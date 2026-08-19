setup() { load '../lib/helpers'; }

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
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get httproute ornith-9b"
  [ "$status" -ne 0 ]
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get httproute ornith-9b-predictor"
  [ "$status" -ne 0 ]
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
}
