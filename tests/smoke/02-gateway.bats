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

# The fixture below is written as a full manifest, not as
# `kubectl create deployment ... || true`, because namespace llm enforces all
# three policies in policy/ (validationFailureAction: Enforce). A bare
# `create deployment` fails require-labels (no app.kubernetes.io/part-of),
# disallow-floating-tags (an untagged image resolves to :latest), and
# require-resource-limits (no limits) - and `|| true` swallowed all three, so
# the suite died 120 seconds later in the curl loop with no stated cause.
#
# The image is the digest pinned as images.echo_server in versions.yaml. It
# is written in literally rather than read with yq so this test needs no yq
# and no working directory assumption; tests/contract/03-images.bats checks
# every pin in that file has a linux/arm64 manifest, and the digest here is
# the same string `yq -r '.images.echo_server' versions.yaml` prints.
@test "traffic reaches a backend through llm.localtest.me" {
  run k apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: llm
  labels:
    app.kubernetes.io/part-of: llm-serving-stack
spec:
  replicas: 1
  selector: { matchLabels: { app: echo } }
  template:
    metadata:
      labels:
        app: echo
        app.kubernetes.io/part-of: llm-serving-stack
    spec:
      containers:
        - name: echo
          image: ealen/echo-server:0.9.2@sha256:74afa5ffd1f0cd81bea9a3ef2f27341dc7e93ed221f2817a2119c230c25cc8a2
          ports: [{ containerPort: 80 }]
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { cpu: 100m, memory: 64Mi }
---
apiVersion: v1
kind: Service
metadata: { name: echo, namespace: llm }
spec:
  selector: { app: echo }
  ports: [{ name: http, port: 80, targetPort: 80 }]
YAML
  # Not `|| true`. If an admission policy rejects this fixture, that is the
  # finding, and it must surface here rather than as an unexplained timeout
  # in the curl loop 120 seconds further down.
  [ "$status" -eq 0 ]
  run k -n llm rollout status deploy/echo --timeout=120s
  [ "$status" -eq 0 ]
  run k apply -f - <<'YAML'
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
  [ "$status" -eq 0 ]
  run wait_for 120 "echo to answer through the gateway" \
    bash -c "curl -sf -o /dev/null http://llm.localtest.me/echo"
  [ "$status" -eq 0 ]
}
