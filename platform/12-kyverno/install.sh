#!/usr/bin/env bash
# Sync wave 1, ahead of KServe (wave 2) and the model overlay (wave 4): the
# policy engine has to be admission-live before anything it governs exists.
# The wave number matches its declarative twin,
# clusters/local-kind/apps/12-kyverno.yaml.
#
# Why this file was missing until 2026-08-19, and why that mattered: CLAUDE.md
# states that every platform layer exists twice, once here and once as an Argo
# CD Application. Kyverno had only the Application. So the imperative path -
# the one CI and a human use - could not install Kyverno at all, which is why
# tests/smoke/11-policy.bats ran nowhere and why the three policies in policy/
# had never guarded a live namespace. `task policy` evaluates fixtures
# (policy/tests), which is a different claim from "admission rejects this".
set -euo pipefail
cd "$(dirname "$0")/../.."

# Chart 3.8.2 is appVersion v1.18.2, read 2026-08-19 with
# `helm show chart kyverno/kyverno --version 3.8.2`. That is the same version
# as versions.yaml tools.kyverno_cli, so the CLI that runs `kyverno test
# policy/tests` and the engine that admits pods are one version.
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version "$(yq -r '.charts.kyverno' versions.yaml)" --wait --timeout 10m

# `helm --wait` returns when the Deployments report Available. The admission
# webhook is registered by the controller after that, so a ClusterPolicy
# applied in the same instant can be refused while the endpoint is still
# coming up. Deployment name read from the rendered chart on 2026-08-19:
# `helm template kyverno kyverno/kyverno --version 3.8.2` emits four
# Deployments, of which kyverno-admission-controller is the one that serves
# admission.
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=5m

# One file at a time, never `kubectl apply -f policy/`. The directory also
# holds README.md and the tests/ subdirectory, and kubectl fails on the
# README. .github/workflows/ci.yml records the same trap for the Kyverno CLI,
# which silently loads zero rules from the directory form instead of failing.
for p in policy/*.yaml; do
  kubectl apply -f "$p"
done

# Applying a ClusterPolicy is not the same as enforcing it. Kyverno reports
# readiness on the policy once its rules are wired into the webhook. Waiting
# here is what makes "installed before the model" mean "enforcing before the
# model", which is the whole reason this layer is wave 1.
#
# `status.conditions` exists on clusterpolicies.kyverno.io/v1 in chart 3.8.2,
# confirmed by reading the CRD out of the rendered chart on 2026-08-19.
# `status.ready` also exists but its own description says "Deprecated in favor
# of Conditions".
#
# Untried (2026-08-19): that the condition type is spelled `Ready`. No cluster
# has run this. If it is wrong, this line times out and the install fails
# loudly, which is the correct failure - it never silently proceeds with the
# policies not yet enforcing.
kubectl wait --for=condition=Ready clusterpolicy --all --timeout=2m
