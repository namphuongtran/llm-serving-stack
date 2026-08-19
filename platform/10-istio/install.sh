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
