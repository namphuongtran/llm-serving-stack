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
