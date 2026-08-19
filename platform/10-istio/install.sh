#!/usr/bin/env bash
# Sync wave 1. Istio in ambient mode: ztunnel per node, no sidecars.
# Chosen over Envoy Gateway in docs/adr/0003-gateway-istio-ambient.md.
set -euo pipefail
cd "$(dirname "$0")/../.."

v() { yq -r ".charts.$1" versions.yaml; }
for k in istio_base istio_istiod istio_cni istio_ztunnel; do
  [ "$(v "$k")" != "null" ] && [ -n "$(v "$k")" ] || { echo "charts.$k not pinned" >&2; exit 1; }
done

kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install istio-base istio/base -n istio-system --version "$(v istio_base)" --wait
# -f rather than --set profile=ambient, as of 2026-08-19. The values file also
# carries meshConfig.extensionProviders for trace export, which is a list of
# objects and would be unreadable as --set expressions. It lives in a
# subdirectory on purpose; its own header says why.
helm upgrade --install istiod istio/istiod -n istio-system --version "$(v istio_istiod)" \
  -f platform/10-istio/helm/values-istiod.yaml --wait
helm upgrade --install istio-cni istio/cni -n istio-system --version "$(v istio_cni)" \
  --set profile=ambient --wait
helm upgrade --install ztunnel istio/ztunnel -n istio-system --version "$(v istio_ztunnel)" --wait

# Workload namespace joins the mesh at L4 without any sidecar.
kubectl create namespace llm --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace llm istio.io/dataplane-mode=ambient --overwrite

kubectl apply -f platform/10-istio/gateway.yaml
kubectl wait --for=condition=Programmed gateway/llm -n istio-system --timeout=5m

# After the Gateway is Programmed, so the workload the Telemetry selects
# already exists. Applying it earlier is harmless but produces no configured
# proxy to look at, which makes a failure here harder to read.
kubectl apply -f platform/10-istio/telemetry.yaml

# Bind the generated gateway Service to the NodePort kind maps to host port 80.
kubectl -n istio-system patch svc llm-istio --type=merge -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":80,"nodePort":30080}]}}'

# In-cluster DNS for llm.localtest.me. Applied last, after the Gateway exists, so
# the name it points at is already resolvable. See coredns-rewrite.yaml's header
# for why this is needed: without it Authorino cannot fetch the OIDC issuer's
# discovery document and every authenticated request returns 401.
kubectl apply -f platform/10-istio/coredns-rewrite.yaml

# Wait for the NAME TO RESOLVE, not for a rollout. Two reasons, both measured on
# 2026-08-19 rather than assumed:
#
#   - No pod restarts. kind's Corefile ends with `reload`, so CoreDNS rereads the
#     ConfigMap in place. `kubectl rollout status deploy/coredns` therefore
#     returns immediately and proves nothing at all - it was in this script for
#     one revision and was the wrong check.
#   - Pickup is not instant. Reverting the ConfigMap and reapplying it, the
#     end-to-end path went from 401 back to 200 after about 80 seconds: CoreDNS's
#     reload interval plus Authorino's own retry. So a short timeout would fail a
#     working install.
#
# A throwaway pod is the only honest probe, because the question is what a POD
# resolves, not what this machine resolves. 180s covers the 80s observed with
# room to spare.
echo "waiting for llm.localtest.me to resolve inside the cluster"
deadline=$((SECONDS + 180))
# Assert WHICH address, not merely that the name resolves. This loop tested only
# `getent hosts llm.localtest.me` until 2026-08-20, which is the same weak check
# that tests/smoke/03-identity.bats had already been corrected away from IN THE
# SAME COMMIT: without the rewrite the name still resolves, via the upstream
# forwarder, to 127.0.0.1. So the 180 second wait would have been satisfied in
# about ten seconds by the wrong answer, and a no-op ConfigMap apply or a Corefile
# CoreDNS refused to reload would have printed success here and surfaced far
# downstream as 401 on every request.
#
# The earlier comment claimed this was "verified both directions". It was
# verified for a name that does not resolve at all, which is not the failure mode
# that matters.
# `|| true` so the guard below can actually run. Without it, `set -e` aborts on
# the assignment whenever kubectl fails, and the message on the next line never
# prints - so the common case (namespace or Service missing) bypassed the guard
# entirely and the operator got kubectl's raw NotFound. Confirmed 2026-08-20 by
# running it against a context with no istio-system namespace.
gw="$(kubectl -n istio-system get svc llm-istio -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
[ -n "$gw" ] || {
  echo "gateway Service llm-istio has no ClusterIP - is the Gateway programmed?" >&2
  kubectl -n istio-system get svc llm-istio >&2 2>&1 || true
  exit 1
}

# --attach is not optional. Without it `kubectl run --rm` refuses outright with
# "error: --rm should only be used for attached containers", so this loop would
# never succeed and would time out after 180s on a perfectly healthy install.
# Found by running it, 2026-08-19.
until kubectl -n kube-system run coredns-probe-$$ --rm --attach --restart=Never --quiet \
        --image=curlimages/curl:8.21.0@sha256:56bc0130aabaada5c04bb18d8d7f75e7a78fbcaa38ad44e1811c8c7720606d84 \
        --command -- sh -c "getent hosts llm.localtest.me | grep -q '^${gw} '" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "llm.localtest.me does not resolve to the gateway ($gw) in-cluster after 180s." >&2
    echo "Without it Authorino returns 401 for every valid token." >&2
    kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' >&2
    exit 1
  fi
  sleep 10
done
echo "llm.localtest.me resolves in-cluster"
