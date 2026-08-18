setup() { load '../lib/helpers'; }

@test "cert-manager is at least v1.17.0" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get deploy -n cert-manager cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}'"
  [ "$status" -eq 0 ]
  version="${output##*:}"
  major="$(echo "${version#v}" | cut -d. -f1)"
  minor="$(echo "${version#v}" | cut -d. -f2)"
  [ "$major" -gt 1 ] || [ "$minor" -ge 17 ]
}

@test "cert-manager webhook is available" {
  run k get deploy -n cert-manager cert-manager-webhook -o jsonpath='{.status.availableReplicas}'
  [ "$output" -ge 1 ]
}

@test "cert-manager can actually issue a certificate" {
  k apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: selftest, namespace: default }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: selftest, namespace: default }
spec:
  secretName: selftest-tls
  dnsNames: ["selftest.local"]
  issuerRef: { name: selftest, kind: Issuer }
YAML
  run wait_for 90 "certificate selftest to be Ready" \
    bash -c "kubectl --context $KUBECTL_CONTEXT get certificate selftest -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
  k delete certificate selftest issuer selftest --ignore-not-found
  [ "$status" -eq 0 ]
}

@test "Gateway API v1 CRDs are installed" {
  for crd in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io referencegrants.gateway.networking.k8s.io; do
    run k get crd "$crd" -o jsonpath='{.spec.versions[?(@.name=="v1")].name}'
    [ "$output" = "v1" ]
  done
}
