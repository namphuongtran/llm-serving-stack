#!/usr/bin/env bash
# Sync wave 3. Scales on queue depth, not CPU: a busy GPU can look idle to CPU
# based autoscaling.
set -euo pipefail
cd "$(dirname "$0")/../.."

helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --version "$(yq -r '.charts.keda' versions.yaml)" \
  -f platform/40-keda/values.yaml --wait --timeout 5m
