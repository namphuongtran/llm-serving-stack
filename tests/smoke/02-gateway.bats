setup() { load '../lib/helpers'; }

@test "ztunnel runs on every node" {
  run k get daemonset -n istio-system ztunnel -o jsonpath='{.status.numberReady}'
  [ "$status" -eq 0 ]
  [ "$output" -eq 3 ]
}

@test "no sidecar injection is configured on the workload namespace" {
  run k get ns llm -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}'
  [ "$output" = "ambient" ]
  run k get ns llm -o jsonpath='{.metadata.labels.istio-injection}'
  [ -z "$output" ]
}

@test "Gateway llm is Programmed" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get gateway -n istio-system llm -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}'"
  [ "$output" = "True" ]
}

@test "traffic reaches a backend through llm.localtest.me" {
  k -n llm create deployment echo --image=ealen/echo-server --port=80 2>/dev/null || true
  k -n llm expose deployment echo --port=80 --name=echo 2>/dev/null || true
  k apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: echo, namespace: llm }
spec:
  parentRefs: [{ name: llm, namespace: istio-system }]
  hostnames: ["llm.localtest.me"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /echo } }]
      backendRefs: [{ name: echo, port: 80 }]
YAML
  run wait_for 120 "echo to answer through the gateway" \
    bash -c "curl -sf -o /dev/null http://llm.localtest.me/echo"
  [ "$status" -eq 0 ]
}
