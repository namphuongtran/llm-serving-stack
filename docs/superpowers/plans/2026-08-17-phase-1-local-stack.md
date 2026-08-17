# Phase 1: local stack on Apple Silicon — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve Ornith-1.0-9B on a local kind cluster through an authenticated, rate-limited, observed, autoscaling, OpenAI-compatible endpoint, with every layer verified by a test and every number dated.

**Architecture:** KServe in Standard mode owns the model lifecycle. Istio in ambient mode is the gateway. Kuadrant enforces JWT authentication and token quota. Keycloak issues the JWTs. The engine is `llama.cpp` behind a `ServingRuntime`, because the KServe HuggingFace image is amd64 only and Rosetta 2 has no AVX. Everything above the engine is engine independent, so phase 2 swaps one runtime reference.

**Tech Stack:** kind, Helm, Kustomize, Task (go-task), bats-core, cert-manager, Gateway API, Istio ambient, Keycloak, KServe, Kuadrant (Authorino + Limitador), Prometheus, Grafana, OpenTelemetry Collector, KEDA, Argo CD, Kyverno, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-17-llm-serving-stack-design.md`

## Global Constraints

- Local machine is Apple M4, arm64, 32 GB RAM, no GPU. Every image used locally must publish a `linux/arm64` manifest. Verify before use, do not assume.
- cert-manager **v1.17.0 or higher** is required by KServe for webhook certificates, in all deployment modes (KServe install dependencies page, read 2026-08-17).
- KServe runs in **Standard mode**. Knative is not installed. `enableGatewayApi` must be set to `true` explicitly, because KServe defaults it to `false`.
- Gateway is Istio with `gatewayClassName: istio`, ambient data plane.
- One hostname serves the API and Keycloak: **`llm.localtest.me`**, which resolves to 127.0.0.1 without editing any host file.
- Every image is pinned **by digest**. Floating tags are rejected by policy in Task 13.
- Every upstream version lives in `versions.yaml` with the date it was read. No version number is written from memory.
- Any measured number is committed with its date and hardware. Re-measure rather than quote an old number forward.
- Secrets never enter git. `HF_TOKEN` and Keycloak client secrets come from the environment.
- Namespace for the workload is `llm`. Platform components use their own conventional namespaces.

---

## File structure

Files this plan creates, and what each is responsible for.

| Path | Responsibility |
|---|---|
| `versions.yaml` | Every pinned upstream version and image digest, each with the date read |
| `Taskfile.yml` | The only entry point a human types. Delegates, contains no logic |
| `prereqs/preflight.sh` | Fails loudly when a tool or Docker memory is missing, before anything installs |
| `prereqs/kind-cluster.yaml` | Cluster shape: one control plane, two workers, port mappings for the gateway |
| `platform/*/install.sh` | One installer per layer. Idempotent. Reads versions from `versions.yaml` |
| `platform/10-istio/gateway.yaml` | The single `Gateway` all routes attach to |
| `platform/15-keycloak/realm-export.json` | The realm as data, so identity config is reproducible |
| `platform/30-observability/recording-rules.yaml` | Normalises engine metrics into the `llmstack:` namespace |
| `platform/30-observability/dashboards/llm-serving.json` | The four questions from the spec, and nothing else |
| `runtimes/llamacpp-arm64/servingruntime.yaml` | Engine as a plug-in: image, args, ports, probes |
| `models/ornith-9b/base/` | Environment-agnostic `InferenceService` plus the model identity |
| `models/ornith-9b/overlays/local/` | Laptop sizing, quantised weights, the route |
| `models/ornith-9b/overlays/ci/` | A 0.5B model so a 4 vCPU runner finishes |
| `security/oidc/authpolicy.yaml` | Who may call |
| `security/oidc/tokenratelimitpolicy.yaml` | How much they may use |
| `tests/lib/helpers.bash` | Shared assertions: wait for condition, get token, call the API |
| `tests/contract/*.bats` | The engine contract, so engines stay swappable |
| `tests/smoke/*.bats` | End to end, including the 401 and 429 paths |
| `bench/run.sh` | Runs a scenario and writes a dated result directory |
| `clusters/local-kind/` | Argo CD app-of-apps, sync waves, the reproducibility proof |
| `policy/*.yaml` | Kyverno policies, enforced in CI and in cluster |
| `.github/workflows/ci.yml` | arm64 CI: lint, policy, smoke |

Task order follows dependency, not the directory numbering. Each task ends with something that can be demonstrated and a commit.

---

## Task 1: Toolchain, version pinning, and a running cluster

**Files:**
- Create: `versions.yaml`
- Create: `prereqs/preflight.sh`
- Create: `prereqs/kind-cluster.yaml`
- Modify: `Taskfile.yml`
- Test: `tests/smoke/00-cluster.bats`, `tests/lib/helpers.bash`

**Interfaces:**
- Consumes: nothing.
- Produces: a kind cluster named `llm-serving-stack` with kube context `kind-llm-serving-stack`; `versions.yaml` keys read by every later `install.sh`; bats helper functions `wait_for`, `require_arm64`.

- [ ] **Step 1: Install the missing tools**

The machine has `kubectl` and `docker`. It does not have `helm`, `kind`, `task`, `yq`, `jq`, `bats`, or `kustomize`.

```bash
brew install helm kind go-task yq jq bats-core kustomize
```

Verify each one prints a version:

```bash
for t in kubectl helm kind task yq jq bats kustomize; do printf '%-10s ' "$t"; $t --version 2>&1 | head -1; done
```

- [ ] **Step 2: Give Docker Desktop enough memory**

Open Docker Desktop, Settings, Resources. Set memory to **20 GB** and CPUs to **8**. The stack runs Istio, Keycloak, KServe, Kuadrant, Prometheus, Grafana, KEDA, Redis, and a 6 GB model at the same time.

Confirm from the command line:

```bash
docker info --format '{{.NCPU}} cpus, {{div .MemTotal 1073741824}} GiB'
```

Expected: at least `8 cpus, 19 GiB`.

- [ ] **Step 3: Write the preflight check**

Create `prereqs/preflight.sh`:

```bash
#!/usr/bin/env bash
# Fails before anything is installed, with a message that says what to do.
set -euo pipefail

fail() { printf 'preflight: %s\n' "$1" >&2; exit 1; }

for t in kubectl helm kind task yq jq bats kustomize docker; do
  command -v "$t" >/dev/null || fail "missing tool: $t (brew install $t)"
done

docker info >/dev/null 2>&1 || fail "docker is not running"

cpus=$(docker info --format '{{.NCPU}}')
mem_gib=$(docker info --format '{{.MemTotal}}')
mem_gib=$((mem_gib / 1073741824))
[ "$cpus" -ge 8 ] || fail "docker has $cpus cpus, need 8 (Docker Desktop > Settings > Resources)"
[ "$mem_gib" -ge 19 ] || fail "docker has ${mem_gib}GiB, need 20 (Docker Desktop > Settings > Resources)"

arch=$(uname -m)
[ "$arch" = "arm64" ] || printf 'preflight: warning: arch is %s, this plan assumes arm64\n' "$arch"

printf 'preflight: ok (%s cpus, %sGiB, %s)\n' "$cpus" "$mem_gib" "$arch"
```

```bash
chmod +x prereqs/preflight.sh && ./prereqs/preflight.sh
```

- [ ] **Step 4: Record pinned versions, with the date read**

Discover current versions rather than guessing them:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo add kedacore https://kedacore.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add kyverno https://kyverno.github.io/kyverno
helm repo update

helm search repo jetstack/cert-manager --versions | head -3
helm search repo istio/istiod --versions | head -3
helm search repo kedacore/keda --versions | head -3
helm search repo prometheus-community/kube-prometheus-stack --versions | head -3
helm search repo open-telemetry/opentelemetry-collector --versions | head -3
helm search repo argo/argo-cd --versions | head -3
helm search repo kyverno/kyverno --versions | head -3
kubectl version --client -o json | jq -r .clientVersion.gitVersion
```

Create `versions.yaml` with the values those commands printed. The `read` field is not decoration; it is what makes a stale pin obvious later.

```yaml
# Every version here was read from an upstream source on the date shown.
# Never edit a version without updating its `read` date.
meta:
  read: "2026-08-17"
  machine: "Apple M4, arm64, 32 GB"

kubernetes:
  kind_node: ""          # e.g. kindest/node:v1.33.1 — pin by digest in step 6
  min_server: "1.32"     # floor named by Envoy AI Gateway prerequisites; we exceed it

charts:
  cert_manager: ""       # jetstack/cert-manager, must be >= v1.17.0 (KServe requirement)
  istio_base: ""
  istio_istiod: ""
  istio_cni: ""
  istio_ztunnel: ""
  keda: ""
  kube_prometheus_stack: ""
  otel_collector: ""
  argo_cd: ""
  kyverno: ""

crds:
  gateway_api: ""        # target v1.5.1, the version KServe v0.20.0 upgraded to

kserve:
  version: "v0.20.0"     # released 2026-08-06, from kserve/kserve releases page
  charts: []             # v0.17 split the chart into 10; fill in from step 5

kuadrant:
  operator_chart: ""     # fill in from step 5

images:
  llamacpp_server: ""    # ghcr.io/ggml-org/llama.cpp:server, pin by digest
  keycloak: ""           # quay.io/keycloak/keycloak, pin by digest
```

- [ ] **Step 5: Discover the chart names this plan cannot assume**

KServe restructured its Helm charts in v0.17 into ten charts, and the exact names must be read, not guessed. Kuadrant's chart location likewise.

```bash
# KServe: list the charts published for the pinned version
helm show chart oci://ghcr.io/kserve/charts/kserve --version v0.20.0 2>&1 | head -20
# If that path is wrong, read the install page for the exact OCI references:
#   https://kserve.github.io/website/docs/admin-guide/overview
```

```bash
# Kuadrant
helm repo add kuadrant https://kuadrant.io/helm-charts 2>/dev/null || true
helm repo update kuadrant && helm search repo kuadrant --versions | head -5
```

Write what the commands returned into `versions.yaml` under `kserve.charts` and `kuadrant.operator_chart`. If a command fails, record the working reference from the upstream install page in the same field and note the page in the commit message. Do not leave the field empty.

- [ ] **Step 6: Pin the two container images by digest, and prove they are arm64**

```bash
for ref in ghcr.io/ggml-org/llama.cpp:server quay.io/keycloak/keycloak:latest; do
  echo "== $ref"
  docker buildx imagetools inspect "$ref" | grep -E 'Name|Platform'
done
```

Expected: `linux/arm64` appears for both. Copy the digest of each arm64 manifest into `versions.yaml` under `images`.

- [ ] **Step 7: Write the cluster definition**

Create `prereqs/kind-cluster.yaml`. Two workers exist so that Task 11 can drain one and watch the PodDisruptionBudget hold. Port 80 is mapped so `llm.localtest.me` works without a tunnel.

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: llm-serving-stack
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 30080
        hostPort: 80
        protocol: TCP
      - containerPort: 30443
        hostPort: 443
        protocol: TCP
  - role: worker
  - role: worker
```

- [ ] **Step 8: Write the failing test**

Create `tests/lib/helpers.bash`:

```bash
# Shared assertions for every bats suite.
export KUBECTL_CONTEXT="kind-llm-serving-stack"
export API_HOST="llm.localtest.me"

k() { kubectl --context "$KUBECTL_CONTEXT" "$@"; }

# wait_for <seconds> <description> <command...>
wait_for() {
  local timeout="$1"; local what="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "timed out after ${timeout}s waiting for: $what" >&2
      return 1
    fi
    sleep 3
  done
}

# require_arm64 <image ref> — fails when no linux/arm64 manifest exists
require_arm64() {
  docker buildx imagetools inspect "$1" 2>/dev/null | grep -q 'linux/arm64'
}
```

Create `tests/smoke/00-cluster.bats`:

```bash
setup() { load '../lib/helpers'; }

@test "cluster exists with three nodes" {
  run k get nodes --no-headers
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "all nodes are Ready" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT get nodes --no-headers | grep -vc ' Ready '"
  [ "$output" -eq 0 ]
}

@test "versions.yaml has no empty pins" {
  run bash -c "yq -r '.. | select(type == \"!!str\") | select(. == \"\")' versions.yaml | wc -l | tr -d ' '"
  [ "$output" -eq 0 ]
}
```

- [ ] **Step 9: Run the test and watch it fail**

```bash
bats tests/smoke/00-cluster.bats
```

Expected: all three tests fail. There is no cluster, and `versions.yaml` still has empty strings if step 5 was skipped.

- [ ] **Step 10: Create the cluster and fill remaining pins**

```bash
kind create cluster --config prereqs/kind-cluster.yaml
kubectl --context kind-llm-serving-stack get nodes
```

Record the node image kind actually used into `versions.yaml` under `kubernetes.kind_node`:

```bash
docker inspect llm-serving-stack-control-plane --format '{{.Config.Image}}'
```

- [ ] **Step 11: Run the test and watch it pass**

```bash
bats tests/smoke/00-cluster.bats
```

Expected: 3 tests, 3 passed.

- [ ] **Step 12: Wire the Taskfile entry points**

Replace the stub bodies for cluster lifecycle in `Taskfile.yml`:

```yaml
  preflight:
    desc: Check tools and Docker resources before installing anything
    cmds:
      - ./prereqs/preflight.sh

  local:cluster:
    desc: Create the kind cluster
    deps: [preflight]
    cmds:
      - kind create cluster --config prereqs/kind-cluster.yaml
    status:
      - kind get clusters | grep -qx {{.CLUSTER_NAME}}

  local:down:
    desc: Delete the local cluster
    cmds:
      - kind delete cluster --name {{.CLUSTER_NAME}}
```

Verify idempotency, which matters because `local:up` will call this repeatedly:

```bash
task local:cluster && task local:cluster
```

Expected: the second run reports the task is up to date and does not fail.

- [ ] **Step 13: Commit**

```bash
git add versions.yaml prereqs/ tests/ Taskfile.yml
git commit -m "feat(prereqs): pin versions, add preflight, create kind cluster

versions.yaml records every pin with the date it was read. preflight fails
before installing when Docker has less than 8 cpus or 20 GiB. Cluster has two
workers so the drain drill in a later task has somewhere to drain to."
```

---

## Task 2: cert-manager and Gateway API CRDs (wave 0)

**Files:**
- Create: `platform/00-cert-manager/install.sh`
- Create: `platform/10-istio/gateway-api-crds.sh`
- Modify: `Taskfile.yml`, `versions.yaml`
- Test: `tests/smoke/01-wave0.bats`

**Interfaces:**
- Consumes: `versions.yaml` keys `charts.cert_manager`, `crds.gateway_api`.
- Produces: cert-manager webhook serving in namespace `cert-manager`; Gateway API CRDs `gateways.gateway.networking.k8s.io`, `httproutes.gateway.networking.k8s.io`, `referencegrants.gateway.networking.k8s.io` at v1.

Gateway API CRDs go in before Istio. This is risk R6 in the spec: installing them in the wrong order produces CRD conflicts that are confusing to unpick.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/01-wave0.bats`:

```bash
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
```

Note the third test. Checking that a Deployment exists proves almost nothing. Issuing a real certificate proves the webhook path works, which is the reason cert-manager is here at all.

- [ ] **Step 2: Run the test and watch it fail**

```bash
bats tests/smoke/01-wave0.bats
```

Expected: 4 failures, the first reporting that the `cert-manager` deployment is not found.

- [ ] **Step 3: Write the Gateway API CRD installer**

Create `platform/10-istio/gateway-api-crds.sh`:

```bash
#!/usr/bin/env bash
# Gateway API CRDs. Installed BEFORE any gateway implementation, because
# implementations ship their own copies and conflict when they win the race.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.crds.gateway_api' versions.yaml)"
[ -n "$VERSION" ] && [ "$VERSION" != "null" ] || { echo "crds.gateway_api not pinned in versions.yaml" >&2; exit 1; }

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${VERSION}/standard-install.yaml"
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s
```

Pin the version first. Read the release list, then record it:

```bash
curl -s https://api.github.com/repos/kubernetes-sigs/gateway-api/releases | jq -r '.[0:5][] | .tag_name'
yq -i '.crds.gateway_api = "v1.5.1"' versions.yaml   # replace with the version chosen from that list
```

- [ ] **Step 4: Write the cert-manager installer**

Create `platform/00-cert-manager/install.sh`:

```bash
#!/usr/bin/env bash
# Sync wave 0. Required by KServe for webhook certificates, in every
# deployment mode (KServe install dependencies, read 2026-08-17).
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.charts.cert_manager' versions.yaml)"
[ -n "$VERSION" ] && [ "$VERSION" != "null" ] || { echo "charts.cert_manager not pinned in versions.yaml" >&2; exit 1; }

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "$VERSION" \
  --set crds.enabled=true \
  --wait --timeout 5m

kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=3m
```

- [ ] **Step 5: Install and run the test until it passes**

```bash
chmod +x platform/00-cert-manager/install.sh platform/10-istio/gateway-api-crds.sh
./platform/10-istio/gateway-api-crds.sh
./platform/00-cert-manager/install.sh
bats tests/smoke/01-wave0.bats
```

Expected: 4 tests, 4 passed. If the certificate test times out, the webhook is not reachable; check `kubectl -n cert-manager logs deploy/cert-manager-webhook`.

- [ ] **Step 6: Commit**

```bash
git add platform/00-cert-manager platform/10-istio/gateway-api-crds.sh tests/smoke/01-wave0.bats versions.yaml
git commit -m "feat(platform): cert-manager and Gateway API CRDs, wave 0

cert-manager is a hard KServe requirement at v1.17.0+. The test issues a real
self-signed certificate rather than checking that a Deployment exists, because
the webhook path is the part that breaks.

Gateway API CRDs are installed before any implementation to avoid the CRD
conflict recorded as risk R6 in the spec."
```

---

## Task 3: Istio ambient and one Gateway (wave 1)

**Files:**
- Create: `platform/10-istio/install.sh`
- Create: `platform/10-istio/gateway.yaml`
- Test: `tests/smoke/02-gateway.bats`
- Modify: `docs/03-why-istio.md`

**Interfaces:**
- Consumes: Gateway API CRDs from Task 2.
- Produces: `Gateway` named `llm` in namespace `istio-system`, listener `http` on port 80, `gatewayClassName: istio`, reachable at `http://llm.localtest.me/`; namespace `llm` labelled for ambient; `NodePort` 30080 bound to the gateway service.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/02-gateway.bats`. It deploys a throwaway echo service, so the gateway is proven to route before any model exists.

```bash
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
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
bats tests/smoke/02-gateway.bats
```

Expected: 4 failures, starting with the ztunnel DaemonSet not found.

- [ ] **Step 3: Write the installer**

Ambient mode needs four charts: `base`, `istiod` with the ambient profile, `cni`, and `ztunnel`. Sidecars are not used, which is the point of ambient: one ztunnel per node instead of one proxy per pod.

Create `platform/10-istio/install.sh`:

```bash
#!/usr/bin/env bash
# Sync wave 1. Istio in ambient mode: ztunnel per node, no sidecars.
# Chosen over Envoy Gateway in docs/adr/0003-gateway-istio-ambient.md.
set -euo pipefail
cd "$(dirname "$0")/../.."

v() { yq -r ".charts.$1" versions.yaml; }
for k in istio_base istio_istiod istio_cni istio_ztunnel; do
  [ "$(v $k)" != "null" ] && [ -n "$(v $k)" ] || { echo "charts.$k not pinned" >&2; exit 1; }
done

kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install istio-base istio/base -n istio-system --version "$(v istio_base)" --wait
helm upgrade --install istiod istio/istiod -n istio-system --version "$(v istio_istiod)" \
  --set profile=ambient --wait
helm upgrade --install istio-cni istio/cni -n istio-system --version "$(v istio_cni)" \
  --set profile=ambient --wait
helm upgrade --install ztunnel istio/ztunnel -n istio-system --version "$(v istio_ztunnel)" --wait

# Workload namespace joins the mesh at L4 without any sidecar.
kubectl create namespace llm --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace llm istio.io/dataplane-mode=ambient --overwrite

kubectl apply -f platform/10-istio/gateway.yaml
kubectl wait --for=condition=Programmed gateway/llm -n istio-system --timeout=5m

# Bind the generated gateway Service to the NodePort kind maps to host port 80.
kubectl -n istio-system patch svc llm-istio --type=merge -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":80,"nodePort":30080}]}}'
```

Create `platform/10-istio/gateway.yaml`:

```yaml
# One Gateway for everything: the inference API and Keycloak share a hostname,
# so the JWT issuer matches the URL used to fetch JWKS (risk R3 in the spec).
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llm
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "llm.localtest.me"
      allowedRoutes:
        namespaces:
          from: All
```

- [ ] **Step 4: Pin the Istio chart versions**

```bash
helm search repo istio/base --versions | head -3
for c in istio_base:base istio_istiod:istiod istio_cni:cni istio_ztunnel:ztunnel; do
  key="${c%%:*}"; chart="${c##*:}"
  ver=$(helm search repo "istio/$chart" --versions -o json | jq -r '.[0].version')
  yq -i ".charts.$key = \"$ver\"" versions.yaml
done
yq '.charts' versions.yaml
```

All four must be the same version. Mixing Istio component versions is a supportability problem, not a shortcut.

- [ ] **Step 5: Install and run the test until it passes**

```bash
chmod +x platform/10-istio/install.sh
./platform/10-istio/install.sh
bats tests/smoke/02-gateway.bats
```

Expected: 4 tests, 4 passed. If the last test times out, check `kubectl -n istio-system get svc llm-istio` shows nodePort 30080, then `curl -v http://llm.localtest.me/echo` and look at whether DNS resolved to 127.0.0.1.

- [ ] **Step 6: Remove the throwaway echo backend**

```bash
kubectl -n llm delete deployment echo svc echo httproute echo --ignore-not-found
```

- [ ] **Step 7: Write down what you learned**

Fill `docs/03-why-istio.md` now, while it is fresh. Required content: the observation that Istio's data plane is Envoy, so `ext_proc` is available; that the choice therefore hinges on that filter rather than on general gateway quality; and the measured resident memory of istiod plus ztunnel on this machine:

```bash
kubectl -n istio-system top pod --no-headers 2>/dev/null || kubectl -n istio-system get pods
```

Record the number with today's date. This is the first entry that tests the vendor blog figures quoted in ADR 0003.

- [ ] **Step 8: Commit**

```bash
git add platform/10-istio tests/smoke/02-gateway.bats docs/03-why-istio.md versions.yaml
git commit -m "feat(platform): Istio ambient with one shared Gateway

Ambient rather than sidecars: ztunnel per node. One Gateway on
llm.localtest.me serves both the API and Keycloak, so the JWT issuer matches
the JWKS URL.

The gateway test routes to a throwaway echo backend, proving the path before
any model exists. Measured istiod and ztunnel memory recorded in
docs/03-why-istio.md."
```

---

## Task 4: Keycloak with a realm from git (wave 1)

**Files:**
- Create: `platform/15-keycloak/keycloak.yaml`
- Create: `platform/15-keycloak/realm-export.json`
- Create: `platform/15-keycloak/httproute.yaml`
- Create: `platform/15-keycloak/install.sh`
- Test: `tests/smoke/03-identity.bats`
- Modify: `tests/lib/helpers.bash`, `docs/05-why-keycloak.md`

**Interfaces:**
- Consumes: the `llm` Gateway from Task 3.
- Produces: issuer `http://llm.localtest.me/realms/llm`; JWKS at `http://llm.localtest.me/realms/llm/protocol/openid-connect/certs`; two confidential clients, `llm-tier-free` and `llm-tier-pro`, each with a `tier` claim in its access token; helper function `get_token <client-id>` in `tests/lib/helpers.bash`.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/03-identity.bats`:

```bash
setup() { load '../lib/helpers'; }

@test "issuer is reachable and self-reports the shared hostname" {
  run bash -c "curl -sf http://llm.localtest.me/realms/llm | jq -r .issuer"
  [ "$status" -eq 0 ]
  [ "$output" = "http://llm.localtest.me/realms/llm" ]
}

@test "JWKS endpoint returns at least one signing key" {
  run bash -c "curl -sf http://llm.localtest.me/realms/llm/protocol/openid-connect/certs | jq '.keys | length'"
  [ "$output" -ge 1 ]
}

@test "free tier client gets a token carrying tier=free" {
  run bash -c "source tests/lib/helpers.bash && get_token llm-tier-free | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .tier"
  [ "$output" = "free" ]
}

@test "pro tier client gets a token carrying tier=pro" {
  run bash -c "source tests/lib/helpers.bash && get_token llm-tier-pro | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .tier"
  [ "$output" = "pro" ]
}
```

The `tier` claim matters: Task 8 uses it as the quota key. Without a claim in the token there is nothing to attach a limit to.

- [ ] **Step 2: Add the token helper**

Append to `tests/lib/helpers.bash`:

```bash
# get_token <client-id> — client credentials grant, prints the access token.
# The client secret is read from the environment, never from git.
get_token() {
  local client="$1"
  local secret_var="KC_SECRET_${client//-/_}"
  local secret="${!secret_var:-devsecret}"
  curl -sf -X POST "http://${API_HOST}/realms/llm/protocol/openid-connect/token" \
    -d grant_type=client_credentials \
    -d "client_id=${client}" \
    -d "client_secret=${secret}" | jq -r .access_token
}
```

- [ ] **Step 3: Run the test and watch it fail**

```bash
bats tests/smoke/03-identity.bats
```

Expected: 4 failures, the first because nothing answers on `/realms/llm`.

- [ ] **Step 4: Write the realm as data**

Create `platform/15-keycloak/realm-export.json`. Dev mode keeps state in memory, so this file is the only definition of identity that survives a restart. Clicking in the web UI is not a supported way to change it.

```json
{
  "realm": "llm",
  "enabled": true,
  "accessTokenLifespan": 900,
  "clients": [
    {
      "clientId": "llm-tier-free",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": false,
      "secret": "devsecret",
      "attributes": { "access.token.signed.response.alg": "RS256" },
      "protocolMappers": [
        {
          "name": "tier",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-hardcoded-claim-mapper",
          "config": {
            "claim.name": "tier",
            "claim.value": "free",
            "jsonType.label": "String",
            "access.token.claim": "true"
          }
        }
      ]
    },
    {
      "clientId": "llm-tier-pro",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": false,
      "secret": "devsecret",
      "attributes": { "access.token.signed.response.alg": "RS256" },
      "protocolMappers": [
        {
          "name": "tier",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-hardcoded-claim-mapper",
          "config": {
            "claim.name": "tier",
            "claim.value": "pro",
            "jsonType.label": "String",
            "access.token.claim": "true"
          }
        }
      ]
    }
  ]
}
```

The secret `devsecret` is a local development value and is why this realm file is safe to commit. Task 14 documents what changes for a real deployment: secrets from `external-secrets`, and a database instead of dev mode.

- [ ] **Step 5: Write the deployment**

Create `platform/15-keycloak/keycloak.yaml`. `KC_HOSTNAME` is what makes the issuer match the shared hostname; without it Keycloak advertises its internal service name and every token is rejected.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-realm
  namespace: llm
data:
  realm-export.json: PLACED_BY_INSTALL_SCRIPT
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: llm
  labels: { app: keycloak }
spec:
  replicas: 1
  selector: { matchLabels: { app: keycloak } }
  template:
    metadata:
      labels: { app: keycloak }
    spec:
      containers:
        - name: keycloak
          image: IMAGE_PLACED_BY_INSTALL_SCRIPT
          args: ["start-dev", "--import-realm"]
          env:
            - { name: KC_BOOTSTRAP_ADMIN_USERNAME, value: admin }
            - { name: KC_BOOTSTRAP_ADMIN_PASSWORD, value: admin }
            - { name: KC_HOSTNAME, value: "http://llm.localtest.me" }
            - { name: KC_HOSTNAME_STRICT, value: "false" }
            - { name: KC_HTTP_ENABLED, value: "true" }
            - { name: KC_PROXY_HEADERS, value: xforwarded }
            - { name: KC_HEALTH_ENABLED, value: "true" }
          ports:
            - { name: http, containerPort: 8080 }
          volumeMounts:
            - { name: realm, mountPath: /opt/keycloak/data/import, readOnly: true }
          readinessProbe:
            httpGet: { path: /realms/llm, port: 8080 }
            initialDelaySeconds: 20
            periodSeconds: 5
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits: { cpu: "1", memory: 1Gi }
      volumes:
        - name: realm
          configMap: { name: keycloak-realm }
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: llm
spec:
  selector: { app: keycloak }
  ports: [{ name: http, port: 8080, targetPort: 8080 }]
```

Create `platform/15-keycloak/httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak
  namespace: llm
spec:
  parentRefs: [{ name: llm, namespace: istio-system }]
  hostnames: ["llm.localtest.me"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /realms }
        - path: { type: PathPrefix, value: /resources }
      backendRefs: [{ name: keycloak, port: 8080 }]
```

- [ ] **Step 6: Write the installer**

Create `platform/15-keycloak/install.sh`:

```bash
#!/usr/bin/env bash
# Sync wave 1. Dev mode: state is in memory, so the realm comes from git.
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE="$(yq -r '.images.keycloak' versions.yaml)"
[ -n "$IMAGE" ] && [ "$IMAGE" != "null" ] || { echo "images.keycloak not pinned" >&2; exit 1; }
case "$IMAGE" in *@sha256:*) ;; *) echo "images.keycloak must be pinned by digest" >&2; exit 1;; esac

kubectl -n llm create configmap keycloak-realm \
  --from-file=realm-export.json=platform/15-keycloak/realm-export.json \
  --dry-run=client -o yaml | kubectl apply -f -

sed -e "s|IMAGE_PLACED_BY_INSTALL_SCRIPT|${IMAGE}|" \
    platform/15-keycloak/keycloak.yaml \
  | yq 'select(.kind != "ConfigMap")' \
  | kubectl apply -f -

kubectl apply -f platform/15-keycloak/httproute.yaml
kubectl -n llm rollout status deploy/keycloak --timeout=5m
```

- [ ] **Step 7: Install and run the test until it passes**

```bash
chmod +x platform/15-keycloak/install.sh
./platform/15-keycloak/install.sh
bats tests/smoke/03-identity.bats
```

Expected: 4 tests, 4 passed.

If the issuer test returns an internal name instead of `llm.localtest.me`, `KC_HOSTNAME` is not taking effect. Check `kubectl -n llm logs deploy/keycloak | grep -i hostname`.

- [ ] **Step 8: Prove the realm survives a restart**

This is the claim the design makes about reproducibility, so test it rather than trust it:

```bash
kubectl -n llm rollout restart deploy/keycloak
kubectl -n llm rollout status deploy/keycloak --timeout=5m
bats tests/smoke/03-identity.bats
```

Expected: still 4 passed. The realm is rebuilt from the ConfigMap, not remembered.

- [ ] **Step 9: Write `docs/05-why-keycloak.md`**

Required content: why JWT verification at the gateway means no datastore is touched on the request path, and therefore why the inference path stays stateless; and the restart observation from step 8.

- [ ] **Step 10: Commit**

```bash
git add platform/15-keycloak tests/smoke/03-identity.bats tests/lib/helpers.bash docs/05-why-keycloak.md
git commit -m "feat(platform): Keycloak in dev mode with the realm defined in git

Two clients carry a hardcoded tier claim, which is the key the token quota
attaches to in a later task. KC_HOSTNAME pins the issuer to the shared
hostname so it matches the JWKS URL the gateway uses.

Restarting the pod and re-running the suite proves the realm comes from git
rather than from memory."
```

---

## Task 5: KServe in Standard mode (wave 2)

**Files:**
- Create: `platform/20-kserve/install.sh`
- Create: `platform/20-kserve/values-kserve.yaml`
- Test: `tests/smoke/04-kserve.bats`
- Modify: `docs/02-why-kserve.md`

**Interfaces:**
- Consumes: cert-manager from Task 2.
- Produces: `inferenceservices.serving.kserve.io` and `servingruntimes.serving.kserve.io` CRDs; controller in `kserve` namespace; `inferenceservice-config` ConfigMap with `deploymentMode: RawDeployment` and Gateway API enabled.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/04-kserve.bats`:

```bash
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
```

The last two tests are the ones that matter. `enableGatewayApi` defaults to `false`, so a passing install with a missing flag would silently use the old ingress path. And a webhook that is installed but not reachable is a failure mode cert-manager exists to prevent.

- [ ] **Step 2: Run the test and watch it fail**

```bash
bats tests/smoke/04-kserve.bats
```

Expected: 5 failures. The Knative test passes already, since nothing installed it.

- [ ] **Step 3: Write the values file**

Create `platform/20-kserve/values-kserve.yaml`:

```yaml
# Standard mode. No Knative, no ModelMesh (its repository was archived
# 2026-04-14). Gateway API on, because KServe defaults it to false.
kserve:
  controller:
    deploymentMode: RawDeployment
    gateway:
      ingressGateway:
        enableGatewayApi: true
        className: istio
        gateway: istio-system/llm
```

Chart values change between KServe versions. Before applying, print the schema and correct the keys to match the pinned chart:

```bash
helm show values oci://ghcr.io/kserve/charts/kserve --version v0.20.0 | head -60
```

Adjust `values-kserve.yaml` to the real key names, and note in the commit message which keys the chart uses. Do not carry keys forward from an older blog post.

- [ ] **Step 4: Write the installer**

Create `platform/20-kserve/install.sh`:

```bash
#!/usr/bin/env bash
# Sync wave 2. KServe v0.17 split the chart; the exact chart references are
# pinned in versions.yaml under kserve.charts.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.kserve.version' versions.yaml)"
mapfile -t CHARTS < <(yq -r '.kserve.charts[]' versions.yaml)
[ "${#CHARTS[@]}" -gt 0 ] || { echo "kserve.charts is empty in versions.yaml" >&2; exit 1; }

for chart in "${CHARTS[@]}"; do
  name="$(basename "$chart")"
  extra=()
  [ "$name" = "kserve" ] && extra=(-f platform/20-kserve/values-kserve.yaml)
  helm upgrade --install "$name" "$chart" \
    --namespace kserve --create-namespace \
    --version "$VERSION" "${extra[@]}" \
    --wait --timeout 10m
done

kubectl wait --for=condition=Established crd/inferenceservices.serving.kserve.io --timeout=120s
kubectl -n kserve rollout status deploy --timeout=5m
```

- [ ] **Step 5: Install and run the test until it passes**

```bash
chmod +x platform/20-kserve/install.sh
./platform/20-kserve/install.sh
bats tests/smoke/04-kserve.bats
```

Expected: 6 tests, 6 passed. If the `enableGatewayApi` test fails, the values keys did not match the chart; re-read `helm show values` and fix `values-kserve.yaml` rather than patching the ConfigMap by hand, because a hand patch will not survive Task 12.

- [ ] **Step 6: Write `docs/02-why-kserve.md`**

Required content: count how many Kubernetes objects KServe created for the InferenceService that Task 6 will add, and state what writing those by hand for five models across three environments would cost. Get the count with:

```bash
kubectl -n llm get all,servingruntime,httproute -l serving.kserve.io/inferenceservice=ornith-9b
```

Fill this section after Task 6 completes, and note in that task's commit that the document was updated.

- [ ] **Step 7: Commit**

```bash
git add platform/20-kserve tests/smoke/04-kserve.bats versions.yaml
git commit -m "feat(platform): KServe in Standard mode with Gateway API enabled

Standard mode, no Knative. enableGatewayApi is set explicitly because KServe
defaults it to false, which would silently keep the legacy ingress path.

Tests assert the two settings that are easy to get wrong, and prove the
admission webhook actually rejects an invalid resource."
```

---

## Task 6: The engine — llama.cpp runtime serving Ornith-1.0-9B

**Files:**
- Create: `runtimes/llamacpp-arm64/servingruntime.yaml`
- Create: `models/ornith-9b/base/{model.yaml,inferenceservice.yaml,kustomization.yaml}`
- Create: `models/ornith-9b/overlays/local/{kustomization.yaml,patch-resources.yaml,httproute.yaml}`
- Test: `tests/contract/01-openai-api.bats`, `tests/contract/02-readiness.bats`
- Modify: `docs/01-why-vllm.md`, `docs/02-why-kserve.md`

**Interfaces:**
- Consumes: KServe CRDs from Task 5, the `llm` Gateway from Task 3.
- Produces: `ServingRuntime` named `llamacpp-arm64` in namespace `llm`; `InferenceService` named `ornith-9b`; a predictor Service answering the OpenAI API on port 8080; model served under the name `ornith-9b`.

This is the largest task. It is one task because the runtime, the model, and the route have no separate value: none of them is demonstrable alone.

- [ ] **Step 1: Choose and pin the quantised weights**

The model card lists 102 community quantisations. Pick one and pin it, rather than resolving a tag at deploy time.

```bash
# Find GGUF repositories for this model
curl -s "https://huggingface.co/api/models?search=Ornith-1.0-9B-GGUF&limit=20" | jq -r '.[].id'
```

Choose a `Q4_K_M` build, then record the exact repository, filename, and size:

```bash
REPO="<repo id chosen above>"
curl -s "https://huggingface.co/api/models/${REPO}" | jq -r '.siblings[].rfilename' | grep -i q4_k_m
```

Create `models/ornith-9b/base/model.yaml`:

```yaml
# The model is a variable. Changing models touches this file and nothing else.
model:
  name: ornith-9b
  license: MIT
  card: https://huggingface.co/deepreinforce-ai/Ornith-1.0-9B
  # bf16 is about 19 GB and needs a GPU; local runs the Q4_K_M quantisation.
  local:
    hf_repo: ""        # filled in step 1
    hf_file: ""        # filled in step 1, e.g. Ornith-1.0-9B-Q4_K_M.gguf
    sha256: ""         # filled in step 3, so a corrupt download is detectable
    approx_size_gb: 0  # filled in step 3
```

- [ ] **Step 2: Write the failing contract tests**

Create `tests/contract/01-openai-api.bats`. These tests define the engine contract from the spec, so phase 2 can swap vLLM in and run the identical suite.

```bash
setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

@test "GET /v1/models lists the served model by its friendly name" {
  run bash -c "curl -sf $BASE/v1/models | jq -r '.data[].id'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ornith-9b"* ]]
}

@test "POST /v1/chat/completions returns a non-empty message" {
  run bash -c "curl -sf $BASE/v1/chat/completions -H 'content-type: application/json' -d '{
      \"model\": \"ornith-9b\",
      \"messages\": [{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}],
      \"max_tokens\": 24
    }' | jq -r '.choices[0].message.content | length'"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "streaming returns more than one chunk and terminates with [DONE]" {
  run bash -c "curl -sfN $BASE/v1/chat/completions -H 'content-type: application/json' -d '{
      \"model\": \"ornith-9b\",
      \"messages\": [{\"role\":\"user\",\"content\":\"Count to five.\"}],
      \"max_tokens\": 48, \"stream\": true
    }' | grep -c '^data: '"
  [ "$status" -eq 0 ]
  [ "$output" -gt 1 ]
}

@test "response reports token usage, which the quota policy depends on" {
  run bash -c "curl -sf $BASE/v1/chat/completions -H 'content-type: application/json' -d '{
      \"model\": \"ornith-9b\",
      \"messages\": [{\"role\":\"user\",\"content\":\"hi\"}],
      \"max_tokens\": 8
    }' | jq -r '.usage.total_tokens'"
  [ "$output" -gt 0 ]
}

@test "/metrics exposes the minimum required series" {
  pod=$(kubectl --context "$KUBECTL_CONTEXT" -n llm get pod \
        -l serving.kserve.io/inferenceservice=ornith-9b -o name | head -1)
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm exec ${pod} -c kserve-container -- \
      wget -qO- http://127.0.0.1:8080/metrics | grep -cE 'requests|tokens'"
  [ "$output" -gt 0 ]
}
```

The fourth test is not cosmetic. `TokenRateLimitPolicy` reads `usage.total_tokens`, so an engine that omits it cannot be rate limited, and Task 8 would fail for a reason that looks unrelated.

Create `tests/contract/02-readiness.bats`:

```bash
setup() { load '../lib/helpers'; }

@test "readiness is false while weights are still loading" {
  # Recreate the predictor and observe that it does not report ready immediately.
  kubectl --context "$KUBECTL_CONTEXT" -n llm delete pod \
    -l serving.kserve.io/inferenceservice=ornith-9b --wait=false
  sleep 5
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get pod \
      -l serving.kserve.io/inferenceservice=ornith-9b \
      -o jsonpath='{.items[0].status.containerStatuses[?(@.name==\"kserve-container\")].ready}'"
  [ "$output" != "true" ]
}

@test "readiness becomes true and the model answers" {
  run wait_for 900 "predictor to become ready after reload" bash -c \
    "kubectl --context $KUBECTL_CONTEXT -n llm get inferenceservice ornith-9b \
      -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
  [ "$status" -eq 0 ]
  run bash -c "curl -sf http://llm.localtest.me/v1/models | jq -e '.data | length > 0'"
  [ "$status" -eq 0 ]
}
```

Create `tests/contract/03-images.bats`. Every image this stack runs locally must
publish an arm64 manifest, and the whole design exists because one of them does
not. Assert it rather than remember it.

```bash
setup() { load '../lib/helpers'; }

@test "every pinned image has a linux/arm64 manifest" {
  while read -r ref; do
    [ -n "$ref" ] || continue
    run require_arm64 "$ref"
    [ "$status" -eq 0 ] || { echo "not arm64: $ref" >&2; false; }
  done < <(yq -r '.images | to_entries[] | .value' versions.yaml)
}

@test "the KServe HuggingFace runtime is still amd64 only, as ADR 0005 states" {
  # If this ever fails, the constraint behind ADR 0005 has changed and the ADR
  # needs a successor. A test is how a dated fact stays honest.
  run require_arm64 "kserve/huggingfaceserver:v0.20.0"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Run the tests and watch them fail**

```bash
bats tests/contract/
```

Expected: every test fails, the first with a connection or 404 response because no route or model exists. The image tests may already pass, which is fine: they guard a constraint rather than drive a change.

- [ ] **Step 4: Write the ServingRuntime**

Create `runtimes/llamacpp-arm64/servingruntime.yaml`. The runtime downloads the single GGUF file itself with an init container, which sidesteps risk R1: KServe's storage initialiser is built around model repositories rather than one file inside one.

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: llamacpp-arm64
  namespace: llm
spec:
  supportedModelFormats:
    - name: gguf
      version: "1"
      autoSelect: false
  protocolVersions: ["v2"]
  containers:
    - name: kserve-container
      image: IMAGE_PLACED_BY_KUSTOMIZE
      args:
        - --model
        - /mnt/models/model.gguf
        - --alias
        - ornith-9b            # friendly name; without it the file path becomes the model id
        - --host
        - 0.0.0.0
        - --port
        - "8080"
        - --ctx-size
        - "4096"
        - --parallel
        - "2"
        - --metrics            # exposes /metrics in Prometheus format
      ports:
        # The name matters: the PodMonitor in Task 7 selects the port by name.
        - name: http
          containerPort: 8080
          protocol: TCP
      readinessProbe:
        # /health reports ready only once weights are loaded, which is the
        # contract requirement. A TCP check would lie here.
        httpGet: { path: /health, port: 8080 }
        initialDelaySeconds: 10
        periodSeconds: 5
        failureThreshold: 120
      livenessProbe:
        httpGet: { path: /health, port: 8080 }
        initialDelaySeconds: 120
        periodSeconds: 30
      volumeMounts:
        - { name: models, mountPath: /mnt/models }
      resources:
        requests: { cpu: "2", memory: 8Gi }
        limits: { cpu: "6", memory: 12Gi }
```

- [ ] **Step 5: Write the InferenceService and the local overlay**

Create `models/ornith-9b/base/inferenceservice.yaml`:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ornith-9b
  namespace: llm
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    minReplicas: 1          # never zero by default: cold start is minutes
    model:
      modelFormat: { name: gguf }
      runtime: llamacpp-arm64
      storageUri: ""        # set per overlay
```

Create `models/ornith-9b/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: llm
resources:
  - inferenceservice.yaml
```

Create `models/ornith-9b/overlays/local/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: llm
resources:
  - ../../base
  - ../../../../runtimes/llamacpp-arm64/servingruntime.yaml
  - httproute.yaml
patches:
  - path: patch-resources.yaml
```

Create `models/ornith-9b/overlays/local/patch-resources.yaml`. The init container fetches the pinned file and verifies its checksum, so a truncated download fails loudly rather than serving nonsense.

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ornith-9b
spec:
  predictor:
    containers:
      - name: kserve-container
        volumeMounts:
          - { name: models, mountPath: /mnt/models }
    initContainers:
      - name: fetch-weights
        image: curlimages/curl:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -eu
            if [ -f /mnt/models/model.gguf ]; then
              echo "weights already present"; exit 0
            fi
            curl -fL --retry 3 -o /mnt/models/model.gguf \
              "https://huggingface.co/${HF_REPO}/resolve/main/${HF_FILE}"
            echo "${SHA256}  /mnt/models/model.gguf" | sha256sum -c -
        env:
          - { name: HF_REPO, value: REPO_FROM_MODEL_YAML }
          - { name: HF_FILE, value: FILE_FROM_MODEL_YAML }
          - { name: SHA256, value: SHA_FROM_MODEL_YAML }
        volumeMounts:
          - { name: models, mountPath: /mnt/models }
    volumes:
      - name: models
        emptyDir: { sizeLimit: 12Gi }
```

Substitute the three values from `model.yaml`. Compute the checksum once, locally, and record it in `model.yaml`:

```bash
REPO=$(yq -r '.model.local.hf_repo' models/ornith-9b/base/model.yaml)
FILE=$(yq -r '.model.local.hf_file' models/ornith-9b/base/model.yaml)
curl -fL -o /tmp/model.gguf "https://huggingface.co/${REPO}/resolve/main/${FILE}"
shasum -a 256 /tmp/model.gguf
ls -lh /tmp/model.gguf
yq -i ".model.local.sha256 = \"<digest>\" | .model.local.approx_size_gb = <size>" models/ornith-9b/base/model.yaml
```

Create `models/ornith-9b/overlays/local/httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ornith-9b
  namespace: llm
spec:
  parentRefs: [{ name: llm, namespace: istio-system }]
  hostnames: ["llm.localtest.me"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /v1 }
      backendRefs:
        - name: ornith-9b-predictor
          port: 80
      timeouts:
        # Streaming answers run for tens of seconds. The default is far too
        # short and truncates responses mid-sentence.
        request: 600s
        backendRequest: 600s
```

- [ ] **Step 6: Substitute the image digest and apply**

```bash
IMG=$(yq -r '.images.llamacpp_server' versions.yaml)
sed -i '' "s|IMAGE_PLACED_BY_KUSTOMIZE|${IMG}|" runtimes/llamacpp-arm64/servingruntime.yaml
kustomize build models/ornith-9b/overlays/local | kubectl apply -f -
kubectl -n llm get inferenceservice ornith-9b -w
```

The first start downloads roughly 6 GB. Watch progress with:

```bash
kubectl -n llm logs -l serving.kserve.io/inferenceservice=ornith-9b -c fetch-weights -f
```

- [ ] **Step 7: Run the contract tests until they pass**

```bash
bats tests/contract/
```

Expected: 7 tests, 7 passed.

If `/v1/models` returns a file path instead of `ornith-9b`, the `--alias` argument did not take effect. If the streaming test returns exactly one chunk, the gateway is buffering; confirm the route timeouts applied.

If `ServingRuntime` argument passing turns out not to work as expected, this is risk R2: fall back to a fully custom predictor using `spec.predictor.containers` directly in the overlay, keeping the same contract tests unchanged. Record the fallback in a new ADR.

- [ ] **Step 8: Write the two documents this task earned**

Fill `docs/01-why-vllm.md` with a measured comparison rather than theory. Send four concurrent requests, then one at a time, and record both durations:

```bash
time (for i in 1 2 3 4; do curl -sf http://llm.localtest.me/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"ornith-9b","messages":[{"role":"user","content":"Write two sentences about rain."}],"max_tokens":64}' >/dev/null & done; wait)
```

Record the numbers with today's date, and state what continuous batching would change. Complete `docs/02-why-kserve.md` with the object count from Task 5, step 6.

- [ ] **Step 9: Commit**

```bash
git add runtimes/ models/ tests/contract/ docs/01-why-vllm.md docs/02-why-kserve.md versions.yaml
git commit -m "feat(model): serve Ornith-1.0-9B through a llama.cpp ServingRuntime

Weights are pinned by repository, filename, and sha256, and fetched by an init
container that verifies the checksum. This avoids relying on the KServe storage
initialiser for a single GGUF file (risk R1).

Contract tests assert the OpenAI surface, streaming, usage.total_tokens, the
metrics endpoint, and that readiness is false until weights load. They are
written to run unchanged against vLLM in phase 2."
```

---

## Task 7: Observability, with one dashboard for two engines

**Files:**
- Create: `platform/30-observability/{install.sh,values-prometheus.yaml,otel-collector.yaml,recording-rules.yaml}`
- Create: `platform/30-observability/dashboards/llm-serving.json`
- Create: `docs/adr/0006-metric-normalisation.md`
- Test: `tests/smoke/05-observability.bats`
- Modify: `docs/06-why-otel.md`

**Interfaces:**
- Consumes: a serving model from Task 6.
- Produces: Prometheus in namespace `observability` scraping the predictor; recording rules publishing `llmstack:requests_running`, `llmstack:requests_waiting`, `llmstack:tokens_out_total`; Grafana with a provisioned dashboard; an OpenTelemetry Collector accepting OTLP on 4317.

- [ ] **Step 1: Read the engine's real metric names**

The spec deliberately refuses to guess these. Read them from the running pod:

```bash
POD=$(kubectl -n llm get pod -l serving.kserve.io/inferenceservice=ornith-9b -o name | head -1)
kubectl -n llm exec "$POD" -c kserve-container -- wget -qO- http://127.0.0.1:8080/metrics \
  | grep -E '^# (HELP|TYPE)' | sort
```

- [ ] **Step 2: Record what you read in an ADR**

Create `docs/adr/0006-metric-normalisation.md` containing: the date, the engine image digest, the full list of metric names the engine exposes, and the mapping to `llmstack:` names. Include an explicit table of which spec panels cannot be filled by this engine and why. This ADR is what lets phase 2 add a vLLM column without re-deriving anything.

- [ ] **Step 3: Write the failing test**

Create `tests/smoke/05-observability.bats`:

```bash
setup() {
  load '../lib/helpers'
  PROM="http://127.0.0.1:9090"
}

teardown() { [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true; }

# The service name is the same one the KEDA trigger in Task 9 uses. Confirm it
# once with: kubectl -n observability get svc | grep prometheus
start_prom_portforward() {
  kubectl --context "$KUBECTL_CONTEXT" -n observability \
    port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
  PF_PID=$!
  wait_for 60 "prometheus port-forward" bash -c "curl -sf $PROM/-/ready"
}

@test "prometheus is scraping the predictor" {
  start_prom_portforward
  run bash -c "curl -sf --get $PROM/api/v1/query --data-urlencode 'query=up{namespace=\"llm\"}' | jq -r '.data.result | length'"
  [ "$output" -ge 1 ]
}

@test "normalised llmstack series exist" {
  start_prom_portforward
  for series in llmstack:requests_running llmstack:tokens_out_total; do
    run bash -c "curl -sf --get $PROM/api/v1/query --data-urlencode \"query=$series\" | jq -r '.data.result | length'"
    [ "$output" -ge 1 ]
  done
}

@test "dashboard is provisioned and reads only llmstack series" {
  run bash -c "grep -o 'llmstack:[a-z_]*' platform/30-observability/dashboards/llm-serving.json | sort -u | wc -l | tr -d ' '"
  [ "$output" -ge 3 ]
  run bash -c "grep -cE '\"expr\": \"(llamacpp|vllm):' platform/30-observability/dashboards/llm-serving.json || true"
  [ "$output" -eq 0 ]
}

@test "otel collector accepts OTLP" {
  run k get deploy -n observability otel-collector -o jsonpath='{.status.availableReplicas}'
  [ "$output" -ge 1 ]
}
```

The third test enforces the design rule mechanically: a dashboard that names an engine-specific series fails the build, so the abstraction cannot rot quietly.

- [ ] **Step 4: Run the test and watch it fail**

```bash
bats tests/smoke/05-observability.bats
```

Expected: 5 failures.

- [ ] **Step 5: Write the recording rules**

Create `platform/30-observability/recording-rules.yaml`, using the real metric names from step 1. Example shape, with the engine-side names replaced by what you actually read:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: llmstack-normalisation
  namespace: observability
  labels: { release: kube-prometheus-stack }
spec:
  groups:
    - name: llmstack.normalisation
      interval: 15s
      rules:
        # One rule per normalised name, per engine. Adding vLLM in phase 2 adds
        # a second expression here and changes no dashboard.
        - record: llmstack:requests_running
          expr: sum(llamacpp:requests_processing) or vector(0)
        - record: llmstack:requests_waiting
          expr: sum(llamacpp:requests_deferred) or vector(0)
        - record: llmstack:tokens_out_total
          expr: sum(llamacpp:tokens_predicted_total) or vector(0)
```

Verify each left-hand engine series exists before relying on it:

```bash
kubectl -n llm exec "$POD" -c kserve-container -- wget -qO- http://127.0.0.1:8080/metrics | grep -E '^llamacpp' | cut -d'{' -f1 | sort -u
```

Correct the rule expressions to match. A rule referencing a non-existent series produces silence, not an error, which is the worst failure mode in observability.

- [ ] **Step 6: Write the installer and remaining manifests**

Create `platform/30-observability/values-prometheus.yaml`:

```yaml
# Small on purpose: this runs beside a 6 GB model on a laptop.
prometheus:
  prometheusSpec:
    retention: 12h
    scrapeInterval: 15s
    resources:
      requests: { cpu: 100m, memory: 512Mi }
      limits: { cpu: "1", memory: 1500Mi }
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
grafana:
  adminPassword: admin
  sidecar:
    dashboards: { enabled: true, label: grafana_dashboard }
alertmanager:
  enabled: false
```

Create `platform/30-observability/otel-collector.yaml`. There is no trace backend in phase 1, so traces are logged. The point is that the pipeline exists and attribute names live in one place, because the GenAI semantic conventions were still experimental as of March 2026.

```yaml
mode: deployment
fullnameOverride: otel-collector
resources:
  requests: { cpu: 50m, memory: 128Mi }
  limits: { cpu: 500m, memory: 512Mi }
config:
  receivers:
    otlp:
      protocols:
        grpc: { endpoint: 0.0.0.0:4317 }
        http: { endpoint: 0.0.0.0:4318 }
  processors:
    batch: {}
    # GenAI attribute names are named here and nowhere else, so a rename in the
    # upstream conventions is a one-file change.
    attributes/genai:
      actions:
        - { key: gen_ai.system, value: llamacpp, action: upsert }
        - { key: gen_ai.request.model, value: ornith-9b, action: upsert }
  exporters:
    debug: { verbosity: basic }
  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [attributes/genai, batch]
        exporters: [debug]
```

Create `platform/30-observability/install.sh`:

```bash
#!/usr/bin/env bash
# Sync wave 3. Metrics via Prometheus scrape, traces via OTLP. Two paths.
set -euo pipefail
cd "$(dirname "$0")/../.."

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observability --create-namespace \
  --version "$(yq -r '.charts.kube_prometheus_stack' versions.yaml)" \
  -f platform/30-observability/values-prometheus.yaml --wait --timeout 10m

helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace observability \
  --version "$(yq -r '.charts.otel_collector' versions.yaml)" \
  -f platform/30-observability/otel-collector.yaml --wait

kubectl apply -f platform/30-observability/recording-rules.yaml

# Scrape the predictor. KServe pods expose the engine port directly.
kubectl apply -f - <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata: { name: llm-predictors, namespace: observability }
spec:
  namespaceSelector: { matchNames: [llm] }
  selector:
    matchExpressions: [{ key: serving.kserve.io/inferenceservice, operator: Exists }]
  podMetricsEndpoints: [{ port: http, path: /metrics, interval: 15s }]
YAML

kubectl -n observability create configmap llm-serving-dashboard \
  --from-file=platform/30-observability/dashboards/llm-serving.json \
  --dry-run=client -o yaml | \
  kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f -
```

- [ ] **Step 7: Decide where TTFT comes from, because the engine may not expose it**

Phase 1 acceptance criterion 5 in the spec requires Grafana to show TTFT p95. If step 1 showed no time-to-first-token histogram, that criterion cannot be met from engine metrics, and there are two honest routes. Pick one and record it in ADR 0006:

1. **Preferred:** derive it from traces. The engine emits a span per request through the OTLP pipeline; add a `spanmetrics` connector to the Collector so a latency histogram lands in Prometheus, then record it as `llmstack:ttft_seconds`.
2. **Fallback:** a small client-side prober CronJob that sends one streaming request each minute, measures the delay to the first `data:` chunk, and exposes it as a gauge. Label the panel "measured by prober, not by the engine", because a synthetic number must never look like a served one.

Do not skip this step and leave the panel empty. A missing signal that nobody decided about is how an observability stack becomes decoration.

- [ ] **Step 8: Build the dashboard with four panels and no more**

Create `platform/30-observability/dashboards/llm-serving.json`. Every `expr` uses an `llmstack:` series, which the test in step 3 enforces.

```json
{
  "title": "LLM serving",
  "uid": "llm-serving",
  "schemaVersion": 39,
  "refresh": "30s",
  "time": { "from": "now-30m", "to": "now" },
  "panels": [
    {
      "type": "timeseries",
      "title": "Do users experience it as slow? TTFT p50 and p95",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        { "expr": "llmstack:ttft_seconds{quantile=\"0.5\"}", "legendFormat": "p50" },
        { "expr": "llmstack:ttft_seconds{quantile=\"0.95\"}", "legendFormat": "p95" }
      ]
    },
    {
      "type": "timeseries",
      "title": "Are we about to saturate? requests waiting and running",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "targets": [
        { "expr": "llmstack:requests_waiting", "legendFormat": "waiting" },
        { "expr": "llmstack:requests_running", "legendFormat": "running" }
      ]
    },
    {
      "type": "timeseries",
      "title": "Throughput: output tokens per second",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [
        { "expr": "rate(llmstack:tokens_out_total[1m])", "legendFormat": "tokens/s" }
      ]
    },
    {
      "type": "text",
      "title": "Not available on this engine",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "options": {
        "mode": "markdown",
        "content": "**Prefix cache hit rate** and **KV cache utilisation** are vLLM metrics and arrive in phase 2. llama.cpp does not emit the KV cache events these depend on. See `docs/adr/0006-metric-normalisation.md`. This panel is deliberately text: an empty graph is indistinguishable from a broken one."
      }
    }
  ]
}
```

Adjust the TTFT expression to match whichever route step 7 chose.

- [ ] **Step 9: Install and run the test until it passes**

```bash
chmod +x platform/30-observability/install.sh
./platform/30-observability/install.sh
# generate a little traffic so the series are not empty
for i in $(seq 1 5); do curl -sf http://llm.localtest.me/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"ornith-9b","messages":[{"role":"user","content":"hello"}],"max_tokens":16}' >/dev/null; done
bats tests/smoke/05-observability.bats
```

Expected: 5 tests, 5 passed.

- [ ] **Step 10: Write `docs/06-why-otel.md`**

Required content: the CPU usage of the predictor while it was saturated, next to its queue depth, showing why CPU is the wrong autoscaling signal. Take both numbers now:

```bash
kubectl -n llm top pod -l serving.kserve.io/inferenceservice=ornith-9b
```

- [ ] **Step 11: Commit**

```bash
git add platform/30-observability docs/adr/0006-metric-normalisation.md docs/06-why-otel.md tests/smoke/05-observability.bats
git commit -m "feat(observability): normalised metrics, one dashboard for both engines

Recording rules map engine-specific series into an llmstack: namespace, and a
test fails the build if any dashboard expression names an engine directly. That
is what lets phase 2 add vLLM without touching a dashboard.

ADR 0006 records the metric names actually read from the running engine, with
the date and image digest, and which panels this engine cannot fill."
```

---

## Task 8: Kuadrant — authentication and token quota

**Files:**
- Create: `platform/25-kuadrant/install.sh`
- Create: `security/oidc/{authpolicy.yaml,tokenratelimitpolicy.yaml}`
- Test: `tests/smoke/06-auth-quota.bats`
- Modify: `docs/04-why-kuadrant.md`, `tests/contract/01-openai-api.bats`

**Interfaces:**
- Consumes: Keycloak issuer from Task 4, the `llm` Gateway from Task 3, a serving model from Task 6.
- Produces: unauthenticated requests to `/v1/*` rejected with 401; authenticated requests allowed; per-tier token quota enforced with 429; `tier` claim used as the quota key.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/06-auth-quota.bats`:

```bash
setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

chat() { # chat <token> <max_tokens>
  curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/chat/completions" \
    -H "authorization: Bearer $1" -H 'content-type: application/json' \
    -d "{\"model\":\"ornith-9b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":$2}"
}

@test "no token is rejected with 401" {
  run bash -c "curl -s -o /dev/null -w '%{http_code}' $BASE/v1/models"
  [ "$output" = "401" ]
}

@test "a forged token is rejected with 401" {
  run bash -c "curl -s -o /dev/null -w '%{http_code}' -H 'authorization: Bearer not.a.jwt' $BASE/v1/models"
  [ "$output" = "401" ]
}

@test "a valid token is accepted" {
  token=$(get_token llm-tier-pro)
  run chat "$token" 16
  [ "$output" = "200" ]
}

@test "the free tier is cut off with 429 once its token budget is spent" {
  token=$(get_token llm-tier-free)
  code=200
  for i in $(seq 1 40); do
    code=$(chat "$token" 64)
    [ "$code" = "429" ] && break
  done
  [ "$code" = "429" ]
}

@test "the pro tier still works after the free tier is limited" {
  token=$(get_token llm-tier-pro)
  run chat "$token" 16
  [ "$output" = "200" ]
}
```

The last test is the one that proves the quota key is the claim and not the whole route. If both tiers were limited together, the identity link would be missing and the design would be wrong in a way a single-tier test cannot see.

- [ ] **Step 2: Run the test and watch it fail**

```bash
bats tests/smoke/06-auth-quota.bats
```

Expected: the 401 tests fail with `200`, because the endpoint is currently open. That failure is the point: it documents that Task 6 shipped an unauthenticated endpoint.

- [ ] **Step 3: Install Kuadrant**

Create `platform/25-kuadrant/install.sh`:

```bash
#!/usr/bin/env bash
# Sync wave 2. Chosen over Envoy AI Gateway, which requires Envoy Gateway as
# its base. See docs/adr/0004-policy-layer-kuadrant.md.
set -euo pipefail
cd "$(dirname "$0")/../.."

CHART="$(yq -r '.kuadrant.operator_chart' versions.yaml)"
[ -n "$CHART" ] && [ "$CHART" != "null" ] || { echo "kuadrant.operator_chart not pinned" >&2; exit 1; }

helm upgrade --install kuadrant-operator "$CHART" \
  --namespace kuadrant-system --create-namespace --wait --timeout 10m

# The Kuadrant CR turns the operator on and deploys Authorino and Limitador.
kubectl apply -f - <<'YAML'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata: { name: kuadrant, namespace: kuadrant-system }
spec: {}
YAML

kubectl wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=5m
```

Confirm the CR's apiVersion against the installed CRD before applying, because it changes between releases:

```bash
kubectl get crd kuadrants.kuadrant.io -o jsonpath='{.spec.versions[*].name}'; echo
```

- [ ] **Step 4: Write the policies**

Create `security/oidc/authpolicy.yaml`:

```yaml
# Verification happens at the gateway using the issuer's public keys.
# No datastore is consulted on the request path, which keeps inference stateless.
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: llm-jwt
  namespace: llm
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ornith-9b
  rules:
    authentication:
      keycloak:
        jwt:
          issuerUrl: http://llm.localtest.me/realms/llm
        credentials:
          authorizationHeader: { prefix: Bearer }
    response:
      success:
        filters:
          identity:
            json:
              properties:
                tier: { selector: auth.identity.tier }
```

Create `security/oidc/tokenratelimitpolicy.yaml`. Limits are deliberately small so the test finishes quickly, and the comment says so, because an unexplained small number looks like a mistake.

```yaml
# Counts tokens, not requests: one request can cost 10 or 100,000 tokens.
# Limits are small on purpose so the smoke test reaches 429 in seconds.
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata:
  name: llm-token-quota
  namespace: llm
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ornith-9b
  limits:
    free:
      rates:
        - limit: 500
          window: 60s
      when:
        - predicate: 'auth.identity.tier == "free"'
      counters:
        - expression: auth.identity.tier
    pro:
      rates:
        - limit: 100000
          window: 60s
      when:
        - predicate: 'auth.identity.tier == "pro"'
      counters:
        - expression: auth.identity.tier
```

Check both apiVersions against the installed CRDs before applying:

```bash
kubectl get crd authpolicies.kuadrant.io tokenratelimitpolicies.kuadrant.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.versions[*].name}{"\n"}{end}'
```

- [ ] **Step 5: Apply and run the test until it passes**

```bash
chmod +x platform/25-kuadrant/install.sh
./platform/25-kuadrant/install.sh
kubectl apply -f security/oidc/
kubectl -n llm wait --for=condition=Enforced authpolicy/llm-jwt --timeout=2m
bats tests/smoke/06-auth-quota.bats
```

Expected: 5 tests, 5 passed.

If 401 never appears, the policy is attached but not enforced; check `kubectl -n llm describe authpolicy llm-jwt` for the `Enforced` condition. If 429 never appears, confirm the engine returns `usage.total_tokens` by re-running the contract test from Task 6, since Limitador has nothing to count without it.

- [ ] **Step 6: Update the contract tests, which now need a token**

Every request in `tests/contract/01-openai-api.bats` must now carry a bearer token. Add to its `setup`:

```bash
setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
  TOKEN="$(get_token llm-tier-pro)"
  AUTH="authorization: Bearer $TOKEN"
}
```

and add `-H "$AUTH"` to each `curl` invocation. Re-run to confirm:

```bash
bats tests/contract/
```

Expected: 7 tests, 7 passed.

- [ ] **Step 7: Write `docs/04-why-kuadrant.md`**

Required content: the measured token cost of two requests that look identical in a request-count world, taken from the `usage` field, and the resulting statement about why request-based limits cannot express cost here.

- [ ] **Step 8: Commit**

```bash
git add platform/25-kuadrant security/oidc tests/smoke/06-auth-quota.bats tests/contract docs/04-why-kuadrant.md versions.yaml
git commit -m "feat(security): JWT authentication and per-tier token quota

AuthPolicy verifies the Keycloak JWT at the gateway with public keys, so no
datastore is touched on the request path. TokenRateLimitPolicy counts tokens
and keys the counter on the tier claim.

The test that matters is the last one: the pro tier still works after the free
tier is limited, which proves the quota is per identity rather than per route."
```

---

## Task 9: Autoscaling on queue depth

**Files:**
- Create: `platform/40-keda/{install.sh,values.yaml}`
- Create: `models/ornith-9b/overlays/local/scaledobject.yaml`
- Create: `models/ornith-9b/overlays/cost-saving/kustomization.yaml`
- Test: `tests/smoke/07-autoscaling.bats`
- Modify: `models/ornith-9b/overlays/local/kustomization.yaml`, `docs/02-why-kserve.md`

**Interfaces:**
- Consumes: normalised metrics from Task 7.
- Produces: KEDA in namespace `keda`; a `ScaledObject` scaling the predictor between 1 and 3 replicas on `llmstack:requests_waiting`.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/07-autoscaling.bats`:

```bash
setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

@test "ScaledObject is Ready and never scales to zero" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get scaledobject ornith-9b -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'"
  [ "$output" = "True" ]
  run k -n llm get scaledobject ornith-9b -o jsonpath='{.spec.minReplicaCount}'
  [ "$output" -ge 1 ]
}

@test "sustained load scales the predictor beyond one replica" {
  token=$(get_token llm-tier-pro)
  for i in $(seq 1 12); do
    curl -s -o /dev/null "$BASE/v1/chat/completions" \
      -H "authorization: Bearer $token" -H 'content-type: application/json' \
      -d '{"model":"ornith-9b","messages":[{"role":"user","content":"Write four sentences about tides."}],"max_tokens":256}' &
  done
  run wait_for 300 "predictor to scale above one replica" bash -c \
    "[ \"\$(kubectl --context $KUBECTL_CONTEXT -n llm get deploy ornith-9b-predictor -o jsonpath='{.spec.replicas}')\" -gt 1 ]"
  wait
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
bats tests/smoke/07-autoscaling.bats
```

Expected: both fail, the first because no `ScaledObject` exists.

- [ ] **Step 3: Install KEDA**

Create `platform/40-keda/values.yaml`:

```yaml
resources:
  operator:
    requests: { cpu: 100m, memory: 128Mi }
    limits: { cpu: 500m, memory: 512Mi }
```

Create `platform/40-keda/install.sh`:

```bash
#!/usr/bin/env bash
# Sync wave 3. Scales on queue depth, not CPU: a busy GPU can look idle to CPU
# based autoscaling.
set -euo pipefail
cd "$(dirname "$0")/../.."

helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --version "$(yq -r '.charts.keda' versions.yaml)" \
  -f platform/40-keda/values.yaml --wait --timeout 5m
```

- [ ] **Step 4: Write the ScaledObject**

Create `models/ornith-9b/overlays/local/scaledobject.yaml`. It reads the normalised series, so the same object works in phase 2 against vLLM.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ornith-9b
  namespace: llm
spec:
  scaleTargetRef:
    name: ornith-9b-predictor
  minReplicaCount: 1        # not zero: cold start is dominated by weight loading
  maxReplicaCount: 3
  pollingInterval: 15
  cooldownPeriod: 120
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://kube-prometheus-stack-prometheus.observability.svc:9090
        query: llmstack:requests_waiting
        threshold: "2"
```

Add it to `models/ornith-9b/overlays/local/kustomization.yaml` under `resources`.

- [ ] **Step 5: Apply and run the test until it passes**

```bash
chmod +x platform/40-keda/install.sh
./platform/40-keda/install.sh
kustomize build models/ornith-9b/overlays/local | kubectl apply -f -
bats tests/smoke/07-autoscaling.bats
```

Expected: 2 tests, 2 passed.

If it never scales, query the series directly and confirm it is non-zero under load. A recording rule that evaluates to nothing produces no scaling and no error, which is the failure mode Task 7 warned about.

- [ ] **Step 6: Add the cost-saving overlay and measure what scale to zero costs**

The spec promises this: scale to zero is not the default, and its cold start is a
measured number in this repository rather than an opinion.

Create `models/ornith-9b/overlays/cost-saving/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: llm
resources:
  - ../local
patches:
  - target: { kind: ScaledObject, name: ornith-9b }
    patch: |
      - op: replace
        path: /spec/minReplicaCount
        value: 0
      - op: replace
        path: /spec/cooldownPeriod
        value: 60
```

Measure the cold start it introduces, and commit the number:

```bash
kustomize build models/ornith-9b/overlays/cost-saving | kubectl apply -f -
# wait for KEDA to scale to zero
kubectl -n llm wait --for=jsonpath='{.spec.replicas}'=0 deploy/ornith-9b-predictor --timeout=10m

TOKEN=$(source tests/lib/helpers.bash && get_token llm-tier-pro)
start=$SECONDS
curl -sf http://llm.localtest.me/v1/models -H "authorization: Bearer $TOKEN" >/dev/null
echo "cold start from zero: $((SECONDS - start))s"

# restore the default posture
kustomize build models/ornith-9b/overlays/local | kubectl apply -f -
```

Write the number, with today's date, into `docs/02-why-kserve.md` next to the
statement that Knative was rejected. It is the evidence for ADR 0002.

- [ ] **Step 7: Commit**

```bash
git add platform/40-keda models/ornith-9b/overlays tests/smoke/07-autoscaling.bats docs/02-why-kserve.md
git commit -m "feat(scaling): KEDA scales on queue depth via normalised metrics

The trigger reads llmstack:requests_waiting rather than an engine-specific
series, so the same ScaledObject works against vLLM in phase 2. minReplicaCount
is 1 by design: cold start is dominated by loading weights."
```

---

## Task 10: High availability under real conditions

**Files:**
- Modify: `models/ornith-9b/overlays/local/patch-resources.yaml`
- Create: `models/ornith-9b/overlays/local/pdb.yaml`
- Create: `docs/runbooks/node-drain.md`
- Test: `tests/smoke/08-availability.bats`

**Interfaces:**
- Consumes: autoscaling from Task 9.
- Produces: two replicas with a PodDisruptionBudget of `minAvailable: 1`, topology spread across nodes, a `preStop` delay and a long `terminationGracePeriodSeconds` so streaming responses are not cut.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/08-availability.bats`:

```bash
setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

@test "two replicas are spread across different nodes" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n llm get pods \
    -l serving.kserve.io/inferenceservice=ornith-9b \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | sort -u | wc -l | tr -d ' '"
  [ "$output" -ge 2 ]
}

@test "a PodDisruptionBudget protects one replica" {
  run k -n llm get pdb ornith-9b -o jsonpath='{.status.currentHealthy}'
  [ "$output" -ge 1 ]
  run k -n llm get pdb ornith-9b -o jsonpath='{.status.disruptionsAllowed}'
  [ "$output" -ge 0 ]
}

@test "a streaming response survives a rolling restart" {
  token=$(get_token llm-tier-pro)
  ( curl -sfN "$BASE/v1/chat/completions" \
      -H "authorization: Bearer $token" -H 'content-type: application/json' \
      -d '{"model":"ornith-9b","messages":[{"role":"user","content":"Count slowly to twenty."}],"max_tokens":400,"stream":true}' \
      > /tmp/stream.out ) &
  stream_pid=$!
  sleep 3
  kubectl --context "$KUBECTL_CONTEXT" -n llm rollout restart deploy/ornith-9b-predictor
  wait "$stream_pid"
  run bash -c "grep -c '^data: ' /tmp/stream.out"
  [ "$output" -gt 1 ]
  run bash -c "grep -c 'DONE' /tmp/stream.out"
  [ "$output" -ge 1 ]
}

@test "draining a node keeps the endpoint answering" {
  token=$(get_token llm-tier-pro)
  node=$(kubectl --context "$KUBECTL_CONTEXT" -n llm get pods \
    -l serving.kserve.io/inferenceservice=ornith-9b \
    -o jsonpath='{.items[0].spec.nodeName}')
  kubectl --context "$KUBECTL_CONTEXT" drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/models" -H "authorization: Bearer $token")
  kubectl --context "$KUBECTL_CONTEXT" uncordon "$node"
  [ "$code" = "200" ]
}
```

The third test is the one most tutorials skip. A rolling restart that truncates an in-flight streamed answer is a real outage that a readiness probe reports as healthy.

- [ ] **Step 2: Run the test and watch it fail**

```bash
bats tests/smoke/08-availability.bats
```

Expected: the first two fail (one replica, no PDB). The streaming test likely fails by truncation, which is the behaviour being fixed.

- [ ] **Step 3: Raise replicas and add graceful shutdown**

Add to `models/ornith-9b/overlays/local/patch-resources.yaml`, inside `spec.predictor`:

```yaml
    minReplicas: 2
    # Streaming answers run for tens of seconds. The pod must finish them.
    terminationGracePeriodSeconds: 120
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            serving.kserve.io/inferenceservice: ornith-9b
```

and to the `kserve-container` entry in the same patch:

```yaml
        lifecycle:
          preStop:
            exec:
              # Let the gateway notice the endpoint is going away before the
              # process stops accepting the stream it is already writing.
              command: ["/bin/sleep", "15"]
```

- [ ] **Step 4: Add the PodDisruptionBudget**

Create `models/ornith-9b/overlays/local/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ornith-9b
  namespace: llm
spec:
  minAvailable: 1
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: ornith-9b
```

Add it to the overlay `kustomization.yaml` resources, and raise `ScaledObject.spec.minReplicaCount` to `2` so KEDA does not scale back below the PDB floor.

- [ ] **Step 5: Apply and run the test until it passes**

```bash
kustomize build models/ornith-9b/overlays/local | kubectl apply -f -
kubectl -n llm rollout status deploy/ornith-9b-predictor --timeout=15m
bats tests/smoke/08-availability.bats
```

Expected: 4 tests, 4 passed. Two replicas each hold a copy of the weights, so check memory headroom with `kubectl -n llm top pod` before assuming a failure is logical rather than a resource limit.

- [ ] **Step 6: Add the failover route to a smaller model**

The spec's failure table promises this: when the engine is unavailable, a weaker
answer beats no answer. The CI overlay already pins a 0.5B model, so reuse it.

Create `models/ornith-9b/overlays/local/fallback.yaml` with a second
`InferenceService` named `fallback-small`, pointing at the small model pinned in
`model.yaml` under `ci:`, with `minReplicas: 1` and small resource requests.

Then extend the route so the gateway retries onto it. Add to the `ornith-9b`
`HTTPRoute` rule in `httproute.yaml`:

```yaml
      backendRefs:
        - name: ornith-9b-predictor
          port: 80
          weight: 100
        - name: fallback-small-predictor
          port: 80
          weight: 0        # zero weight: reached only through retry, not load split
      timeouts:
        request: 600s
        backendRequest: 600s
```

Add the retry behaviour with a Kuadrant-independent Istio policy, then prove it:

```bash
kustomize build models/ornith-9b/overlays/local | kubectl apply -f -
# take the primary out of service without deleting it
kubectl -n llm scale deploy/ornith-9b-predictor --replicas=0
TOKEN=$(source tests/lib/helpers.bash && get_token llm-tier-pro)
curl -s -o /dev/null -w '%{http_code}\n' http://llm.localtest.me/v1/models -H "authorization: Bearer $TOKEN"
kubectl -n llm scale deploy/ornith-9b-predictor --replicas=2
```

Expected: `200`, served by the fallback. If it returns `503`, the retry is not
configured and the failover line in the spec is currently aspirational. Either
fix it or change the spec. Do not leave a claim in the spec that no test covers.

Add the assertion to `tests/smoke/08-availability.bats` so it cannot regress:

```bash
@test "the endpoint still answers when the primary has no replicas" {
  token=$(get_token llm-tier-pro)
  kubectl --context "$KUBECTL_CONTEXT" -n llm scale deploy/ornith-9b-predictor --replicas=0
  wait_for 120 "primary to have zero endpoints" bash -c \
    "[ \"\$(kubectl --context $KUBECTL_CONTEXT -n llm get deploy ornith-9b-predictor -o jsonpath='{.status.readyReplicas}')\" = '' ]"
  code=$(curl -s -o /dev/null -w '%{http_code}' http://llm.localtest.me/v1/models -H "authorization: Bearer $token")
  kubectl --context "$KUBECTL_CONTEXT" -n llm scale deploy/ornith-9b-predictor --replicas=2
  [ "$code" = "200" ]
}
```

- [ ] **Step 7: Write the runbook**

Create `docs/runbooks/node-drain.md`: the exact commands used above, what a healthy drain looks like, what to check when `disruptionsAllowed` is 0, the memory ceiling observed on this machine with two replicas resident, and how to tell from a response whether it came from the primary or the fallback.

- [ ] **Step 8: Commit**

```bash
git add models/ornith-9b/overlays/local docs/runbooks/node-drain.md tests/smoke/08-availability.bats
git commit -m "feat(ha): two spread replicas, PDB, and graceful shutdown for streams

The streaming test restarts the deployment mid-response and asserts the answer
still completes. A long termination grace period plus a preStop delay is what
makes that true; without them a rolling update truncates answers while every
probe reports healthy."
```

---

## Task 11: Benchmark harness and the first dated numbers

**Files:**
- Create: `bench/run.sh`, `bench/harness.py`, `bench/summarise.py`
- Create: `bench/scenarios/{01-short.json,02-long-prefill.json,03-shared-prefix.json,04-concurrency-sweep.json}`
- Create: `bench/results/README.md` entry for the first run
- Modify: `Taskfile.yml`, `docs/01-why-vllm.md`

**Interfaces:**
- Consumes: an authenticated serving endpoint from Task 8.
- Produces: `task bench` writes `bench/results/<date>-<machine>-<engine>/` containing `env.json`, per-scenario raw output, and `summary.md`.

- [ ] **Step 1: Write the failing test**

Add `tests/smoke/09-bench.bats`:

```bash
setup() { load '../lib/helpers'; }

@test "bench run produces a dated result directory with an environment record" {
  run bash -c "SCENARIOS=bench/scenarios/01-short.json ./bench/run.sh"
  [ "$status" -eq 0 ]
  latest=$(ls -1dt bench/results/*/ | head -1)
  [ -f "${latest}env.json" ]
  [ -f "${latest}summary.md" ]
  run bash -c "jq -r '.date, .machine, .engine_image' '${latest}env.json' | grep -c ."
  [ "$output" -eq 3 ]
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bats tests/smoke/09-bench.bats
```

Expected: failure, `./bench/run.sh` does not exist.

- [ ] **Step 3: Write the scenarios**

Create `bench/scenarios/01-short.json`:

```json
{
  "name": "short-prompt-short-output",
  "question": "How responsive is a small interactive request?",
  "prompt_tokens": 32,
  "max_tokens": 64,
  "num_prompts": 40,
  "concurrency": 4
}
```

Create `bench/scenarios/02-long-prefill.json`:

```json
{
  "name": "long-prompt-short-output",
  "question": "What does prefill cost when the prompt is large?",
  "prompt_tokens": 8000,
  "max_tokens": 64,
  "num_prompts": 12,
  "concurrency": 2
}
```

Create `bench/scenarios/03-shared-prefix.json`:

```json
{
  "name": "shared-prefix",
  "question": "How much does a repeated prompt prefix help, and how much more will cache-aware routing add in phase 3?",
  "prompt_tokens": 4000,
  "shared_prefix_tokens": 3500,
  "max_tokens": 64,
  "num_prompts": 24,
  "concurrency": 4
}
```

Create `bench/scenarios/04-concurrency-sweep.json`:

```json
{
  "name": "concurrency-sweep",
  "question": "Where does throughput stop improving and latency start degrading?",
  "prompt_tokens": 256,
  "max_tokens": 128,
  "num_prompts": 64,
  "concurrency_levels": [1, 4, 16, 64]
}
```

- [ ] **Step 4: Write the runner**

Create `bench/run.sh`. It records the environment first, because a result without its environment is not a result.

```bash
#!/usr/bin/env bash
# Measures through the public endpoint only, so the same harness works against
# llama.cpp locally and vLLM on GPU nodes.
set -euo pipefail
cd "$(dirname "$0")/.."

DATE="$(date +%Y-%m-%d)"
MACHINE="$(uname -m)-$(sysctl -n machdep.cpu.brand_string 2>/dev/null | tr ' ' '-' | tr -d '()' || echo unknown)"
ENGINE_IMAGE="$(kubectl -n llm get pod -l serving.kserve.io/inferenceservice=ornith-9b \
  -o jsonpath='{.items[0].spec.containers[?(@.name=="kserve-container")].image}')"
ENGINE_NAME="$(basename "${ENGINE_IMAGE%%@*}" | cut -d: -f1)"
OUT="bench/results/${DATE}-${MACHINE}-${ENGINE_NAME}"
mkdir -p "$OUT"

TOKEN="$(source tests/lib/helpers.bash && get_token llm-tier-pro)"

jq -n \
  --arg date "$DATE" --arg machine "$MACHINE" --arg engine_image "$ENGINE_IMAGE" \
  --arg model "$(yq -r '.model.local.hf_file' models/ornith-9b/base/model.yaml)" \
  --arg replicas "$(kubectl -n llm get deploy ornith-9b-predictor -o jsonpath='{.spec.replicas}')" \
  '{date:$date, machine:$machine, engine_image:$engine_image, model:$model, replicas:$replicas}' \
  > "$OUT/env.json"

for f in ${SCENARIOS:-bench/scenarios/*.json}; do
  name="$(jq -r .name "$f")"
  echo "== $name"
  python3 bench/harness.py --scenario "$f" --base-url "http://llm.localtest.me" \
    --token "$TOKEN" --model ornith-9b --out "$OUT/${name}.json"
done

python3 bench/summarise.py --dir "$OUT" > "$OUT/summary.md"
echo "wrote $OUT/summary.md"
```

Create `bench/harness.py`. Standard library only, so there is nothing to install
and nothing to drift.

```python
#!/usr/bin/env python3
"""Measures an OpenAI-compatible endpoint. Engine agnostic on purpose: the same
harness runs against llama.cpp on a laptop and vLLM on GPU nodes."""
import argparse, json, statistics, threading, time, urllib.request

def build_prompt(approx_tokens, shared_prefix_tokens=0, seed=0):
    # Roughly 0.75 words per token. Exactness does not matter; reproducibility does.
    prefix = " ".join(["context"] * int(shared_prefix_tokens * 0.75))
    unique = " ".join([f"w{seed}-{i}" for i in range(int((approx_tokens - shared_prefix_tokens) * 0.75))])
    return (prefix + " " + unique).strip()

def one_request(base, token, model, prompt, max_tokens):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(
        f"{base}/v1/chat/completions", data=body,
        headers={"content-type": "application/json", "authorization": f"Bearer {token}"})
    started = time.perf_counter()
    ttft, last, gaps, chunks, usage = None, None, [], 0, None
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data: "):
                    continue
                payload = line[6:]
                if payload == "[DONE]":
                    break
                now = time.perf_counter()
                if ttft is None:
                    ttft = now - started
                else:
                    gaps.append(now - last)
                last = now
                chunks += 1
                try:
                    obj = json.loads(payload)
                    if obj.get("usage"):
                        usage = obj["usage"]
                except json.JSONDecodeError:
                    pass
        return {"ok": True, "ttft": ttft, "itl": gaps, "chunks": chunks,
                "total": time.perf_counter() - started, "usage": usage}
    except Exception as exc:                      # network, 4xx, 5xx, timeout
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}",
                "total": time.perf_counter() - started}

def run(base, token, model, scenario, concurrency):
    n = scenario["num_prompts"]
    prompts = [build_prompt(scenario["prompt_tokens"],
                            scenario.get("shared_prefix_tokens", 0), i) for i in range(n)]
    results, lock, index = [], threading.Lock(), {"i": 0}

    def worker():
        while True:
            with lock:
                i = index["i"]
                index["i"] += 1
            if i >= n:
                return
            r = one_request(base, token, model, prompts[i], scenario["max_tokens"])
            with lock:
                results.append(r)

    started = time.perf_counter()
    threads = [threading.Thread(target=worker) for _ in range(concurrency)]
    for t in threads: t.start()
    for t in threads: t.join()
    wall = time.perf_counter() - started

    ok = [r for r in results if r["ok"]]
    def pct(values, q):
        if not values: return None
        s = sorted(values)
        return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]
    out_tokens = sum((r["usage"] or {}).get("completion_tokens", r["chunks"]) for r in ok)
    return {
        "concurrency": concurrency,
        "requests": n,
        "errors": len(results) - len(ok),
        "wall_seconds": round(wall, 3),
        "ttft_p50": pct([r["ttft"] for r in ok if r["ttft"]], 0.50),
        "ttft_p95": pct([r["ttft"] for r in ok if r["ttft"]], 0.95),
        "itl_p95": pct([g for r in ok for g in r["itl"]], 0.95),
        "output_tokens": out_tokens,
        "output_tokens_per_second": round(out_tokens / wall, 2) if wall else None,
        "first_error": next((r["error"] for r in results if not r["ok"]), None),
    }

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--scenario", required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--token", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    with open(a.scenario) as fh:
        scenario = json.load(fh)
    levels = scenario.get("concurrency_levels", [scenario.get("concurrency", 1)])
    report = {"scenario": scenario, "runs": [run(a.base_url, a.token, a.model, scenario, c) for c in levels]}
    with open(a.out, "w") as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report["runs"], indent=2))
```

Create `bench/summarise.py`:

```python
#!/usr/bin/env python3
"""Turns a result directory into a markdown table. The environment is printed
above the numbers, because a number without its environment is not a result."""
import argparse, glob, json, os

p = argparse.ArgumentParser(); p.add_argument("--dir", required=True)
d = p.parse_args().dir

with open(os.path.join(d, "env.json")) as fh:
    env = json.load(fh)

print(f"# Benchmark run {env['date']}\n")
for k, v in env.items():
    print(f"- **{k}**: {v}")
print("\n| scenario | conc | reqs | errors | TTFT p50 (s) | TTFT p95 (s) | ITL p95 (s) | out tok/s |")
print("|---|---|---|---|---|---|---|---|")

def f(x):
    return "n/a" if x is None else (f"{x:.3f}" if isinstance(x, float) else str(x))

for path in sorted(glob.glob(os.path.join(d, "*.json"))):
    if path.endswith("env.json"):
        continue
    with open(path) as fh:
        report = json.load(fh)
    name = report["scenario"]["name"]
    for r in report["runs"]:
        print(f"| {name} | {r['concurrency']} | {r['requests']} | {r['errors']} | "
              f"{f(r['ttft_p50'])} | {f(r['ttft_p95'])} | {f(r['itl_p95'])} | {f(r['output_tokens_per_second'])} |")

print("\n## Questions each scenario answers\n")
for path in sorted(glob.glob(os.path.join(d, "*.json"))):
    if path.endswith("env.json"):
        continue
    with open(path) as fh:
        s = json.load(fh)["scenario"]
    print(f"- **{s['name']}**: {s['question']}")
```

Note what `harness.py` does when a request fails: it records the error and keeps
going, and the summary prints an `errors` column. A harness that crashes on the
first 429 cannot measure a rate-limited endpoint, and a harness that silently
drops failures reports a throughput number that is a lie.

- [ ] **Step 5: Run the test until it passes**

```bash
chmod +x bench/run.sh
bats tests/smoke/09-bench.bats
```

Expected: 1 test, 1 passed.

- [ ] **Step 6: Take the first full measurement**

```bash
task bench
cat bench/results/*/summary.md
```

- [ ] **Step 7: Wire the Taskfile and commit**

```yaml
  bench:
    desc: Run every scenario and write a dated result directory
    cmds:
      - ./bench/run.sh
```

```bash
git add bench Taskfile.yml tests/smoke/09-bench.bats docs/01-why-vllm.md
git commit -m "feat(bench): scenario harness writing dated, environment-stamped results

Measures through the public endpoint only, so the same four scenarios compare
llama.cpp on a laptop against vLLM on GPU nodes. Every result directory carries
env.json with the date, machine, engine image digest, and replica count.

First measurement committed. It is the baseline that phase 2 has to beat, and
the number the vendor claims in ADR 0003 will be checked against."
```

---

## Task 12: Argo CD, and proving nothing was done by hand

**Files:**
- Create: `clusters/local-kind/{root-app.yaml,apps/*.yaml}`
- Create: `platform/50-argocd/install.sh`
- Modify: `Taskfile.yml`
- Test: `tests/smoke/10-gitops.bats`
- Modify: `docs/07-why-gitops.md`

**Interfaces:**
- Consumes: every previous task's manifests.
- Produces: an Argo CD `Application` per layer with sync waves 0 to 4; `task local:up` bootstraps a cluster where Argo CD installs everything else; every application reports `Synced` and `Healthy`.

This task is the audit. Any step performed by hand in Tasks 2 to 11 will surface here as an application that will not sync.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/10-gitops.bats`:

```bash
setup() { load '../lib/helpers'; }

@test "every Argo CD application is Synced and Healthy" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{\"\\n\"}{end}'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -v '=Synced/Healthy$' | grep . && false || true
}

@test "sync waves are declared on every application" {
  run bash -c "kubectl --context $KUBECTL_CONTEXT -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.annotations.argocd\\.argoproj\\.io/sync-wave}{\"\\n\"}{end}' | grep -c ."
  count=$(kubectl --context "$KUBECTL_CONTEXT" -n argocd get applications.argoproj.io --no-headers | wc -l | tr -d ' ')
  [ "$output" -eq "$count" ]
}

@test "a rebuilt cluster reaches a working endpoint with no manual steps" {
  skip "run manually: task local:down && task local:up && bats tests/"
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bats tests/smoke/10-gitops.bats
```

Expected: failure, no Argo CD.

- [ ] **Step 3: Install Argo CD**

Create `platform/50-argocd/install.sh`:

```bash
#!/usr/bin/env bash
# The only component installed imperatively. Everything else is its child.
set -euo pipefail
cd "$(dirname "$0")/../.."

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "$(yq -r '.charts.argo_cd' versions.yaml)" \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 10m
```

- [ ] **Step 4: Write one Application per layer**

Create `clusters/local-kind/apps/00-cert-manager.yaml` as the pattern; repeat for each layer with its own wave and source. Waves match the spec's table.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  destination: { server: https://kubernetes.default.svc, namespace: cert-manager }
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: VERSION_FROM_VERSIONS_YAML
    helm:
      parameters:
        - { name: crds.enabled, value: "true" }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Two of the sources have a different shape, so both are written out rather than
described. A path in this repository, `clusters/local-kind/apps/90-model-local.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: model-local
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  project: default
  destination: { server: https://kubernetes.default.svc, namespace: llm }
  source:
    repoURL: https://github.com/OWNER/llm-serving-stack.git   # replace with the real remote
    targetRevision: HEAD
    path: models/ornith-9b/overlays/local
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

A plain manifest URL, `clusters/local-kind/apps/00-gateway-api-crds.yaml`. Server-side
apply matters here: Gateway API CRDs exceed the annotation size limit that
client-side apply uses.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-api-crds
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  destination: { server: https://kubernetes.default.svc, namespace: default }
  source:
    repoURL: https://github.com/kubernetes-sigs/gateway-api
    targetRevision: VERSION_FROM_VERSIONS_YAML
    path: config/crd/standard
  syncPolicy:
    automated: { prune: false, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

Applications and waves to create:

| File | Wave | Source |
|---|---|---|
| `00-gateway-api-crds.yaml` | 0 | Gateway API release manifest URL |
| `00-cert-manager.yaml` | 0 | jetstack chart |
| `10-istio-base.yaml`, `10-istiod.yaml`, `10-istio-cni.yaml`, `10-ztunnel.yaml` | 1 | istio charts |
| `15-keycloak.yaml` | 1 | this repository, path `platform/15-keycloak` |
| `20-kserve.yaml` | 2 | KServe OCI charts |
| `25-kuadrant.yaml` | 2 | kuadrant chart |
| `30-observability.yaml` | 3 | prometheus and otel charts |
| `40-keda.yaml` | 3 | keda chart |
| `90-model-local.yaml` | 4 | this repository, path `models/ornith-9b/overlays/local` |
| `90-security.yaml` | 4 | this repository, path `security/oidc` |

Create `clusters/local-kind/root-app.yaml` pointing at `clusters/local-kind/apps`, so one apply brings in all of them.

- [ ] **Step 5: Reconcile the differences**

```bash
chmod +x platform/50-argocd/install.sh
./platform/50-argocd/install.sh
kubectl apply -f clusters/local-kind/root-app.yaml
kubectl -n argocd get applications.argoproj.io -w
```

Any application stuck `OutOfSync` marks a manual step from an earlier task. Fix it in the manifest, not in the cluster. Common cases: the Keycloak realm ConfigMap built by a shell script, and the image digest substituted by `sed`. Both need to become declarative, for example by committing the rendered manifest or generating the ConfigMap through Kustomize's `configMapGenerator`.

- [ ] **Step 6: Prove reproducibility from an empty machine**

This is the acceptance test for the whole task:

```bash
task local:down
task local:up
bats tests/
```

`local:up` should do exactly three things: create the cluster, install Argo CD, apply the root application. Then wait. Update the Taskfile accordingly:

```yaml
  local:up:
    desc: Empty machine to a ready service
    cmds:
      - task: local:cluster
      - ./platform/50-argocd/install.sh
      - kubectl apply -f clusters/local-kind/root-app.yaml
      - kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy applications.argoproj.io --all --timeout=30m
```

Record how long the rebuild took. That number belongs in `docs/07-why-gitops.md` and in the recovery runbook.

- [ ] **Step 7: Commit**

```bash
git add clusters/ platform/50-argocd Taskfile.yml tests/smoke/10-gitops.bats docs/07-why-gitops.md
git commit -m "feat(gitops): Argo CD app-of-apps with sync waves, and a rebuild proof

Argo CD is the only imperative install; every other layer is one of its
children with a declared sync wave. Rebuilding the cluster from empty and
re-running the whole suite is what proves no step was done by hand.

Rebuild time recorded in docs/07-why-gitops.md; it is also the starting point
for the recovery time objective."
```

---

## Task 13: Policy and CI on arm64

**Files:**
- Create: `policy/{require-resource-limits.yaml,disallow-floating-tags.yaml,require-labels.yaml}`
- Create: `.github/workflows/ci.yml`
- Create: `models/ornith-9b/overlays/ci/{kustomization.yaml,patch-model.yaml}`
- Test: `tests/smoke/11-policy.bats`

**Interfaces:**
- Consumes: every manifest in the repository.
- Produces: three Kyverno policies enforced in cluster and evaluated in CI; a CI workflow on `ubuntu-24.04-arm` that lints, evaluates policy, and runs the smoke suite against a kind cluster with a 0.5B model.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/11-policy.bats`:

```bash
setup() { load '../lib/helpers'; }

@test "a pod without resource limits is rejected" {
  run k -n llm run nolimits --image=busybox:1.36 --restart=Never --command -- sleep 1
  [ "$status" -ne 0 ]
}

@test "a floating image tag is rejected" {
  run k -n llm run floating --image=busybox:latest --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:latest","resources":{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}}]}}' \
    --command -- sleep 1
  [ "$status" -ne 0 ]
}

@test "every overlay in the repository builds" {
  for o in models/*/overlays/*; do
    run kustomize build "$o"
    [ "$status" -eq 0 ]
  done
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bats tests/smoke/11-policy.bats
```

Expected: the first two fail, because both pods are created successfully today.

- [ ] **Step 3: Write the policies**

Create `policy/require-resource-limits.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-limits
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [llm]
      validate:
        message: "cpu and memory limits are required: an unbounded model server can evict the control plane"
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    memory: "?*"
                    cpu: "?*"
```

Create `policy/disallow-floating-tags.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-floating-tags
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-digest-or-fixed-tag
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [llm]
      validate:
        message: "image must be pinned by digest, not a floating tag"
        pattern:
          spec:
            containers:
              - image: "*@sha256:*"
```

Create `policy/require-labels.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-part-of
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet]
              namespaces: [llm]
      validate:
        message: "app.kubernetes.io/part-of is required so ownership is queryable"
        pattern:
          metadata:
            labels:
              app.kubernetes.io/part-of: "?*"
```

KServe generates the predictor Deployment, so this policy will reject it until
the label is added. Add it in the base `InferenceService` under
`spec.predictor.labels`, which KServe propagates, rather than weakening the
policy.

Add a Kyverno Application to `clusters/local-kind/apps/` at wave 1, and add `policy/` as its source.

- [ ] **Step 4: Fix what the policies now reject**

Enforcing digests will fail the init container from Task 6, which uses `curlimages/curl:latest`. Pin it:

```bash
docker buildx imagetools inspect curlimages/curl:latest | grep -E 'Name|Platform'
```

Record the digest in `versions.yaml` under `images.curl` and reference it from the overlay. This is the policy earning its place: it found a floating tag that was already in the repository.

- [ ] **Step 5: Write the CI overlay**

Create `models/ornith-9b/overlays/ci/patch-model.yaml`, replacing the weights with a roughly 0.5B GGUF model and lowering resources to fit 4 vCPU. Find and pin one the same way as Task 6, step 1, and record it in `model.yaml` under a `ci:` key.

- [ ] **Step 6: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: ci
on:
  pull_request:
  push: { branches: [main] }

jobs:
  lint:
    runs-on: ubuntu-24.04-arm   # same architecture as the development machine
    steps:
      - uses: actions/checkout@v4
      - name: Install tools
        run: |
          set -euo pipefail
          curl -sSL https://github.com/kubernetes-sigs/kustomize/releases/latest/download/install_kustomize.sh | bash
          sudo mv kustomize /usr/local/bin/
          sudo snap install yq
      - name: Every overlay builds
        run: for o in models/*/overlays/*; do kustomize build "$o" >/dev/null; done
      - name: No empty version pins
        run: test "$(yq -r '.. | select(type == "!!str") | select(. == "")' versions.yaml | wc -l)" -eq 0

  policy:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
      - name: Install Kyverno CLI
        run: |
          set -euo pipefail
          VERSION=$(curl -s https://api.github.com/repos/kyverno/kyverno/releases/latest | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
          curl -sSL "https://github.com/kyverno/kyverno/releases/download/${VERSION}/kyverno-cli_${VERSION}_linux_arm64.tar.gz" | tar xz
          sudo mv kyverno /usr/local/bin/
      - name: Policies pass against rendered manifests
        run: |
          for o in models/*/overlays/*; do
            kustomize build "$o" > /tmp/rendered.yaml
            kyverno apply policy/ --resource /tmp/rendered.yaml
          done

  smoke:
    runs-on: ubuntu-24.04-arm
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - name: Create cluster
        uses: helm/kind-action@v1
        with:
          config: prereqs/kind-cluster.yaml
      - name: Install platform
        run: |
          set -euo pipefail
          ./platform/10-istio/gateway-api-crds.sh
          ./platform/00-cert-manager/install.sh
          ./platform/10-istio/install.sh
          ./platform/15-keycloak/install.sh
          ./platform/20-kserve/install.sh
          ./platform/25-kuadrant/install.sh
      - name: Deploy the CI model
        run: kustomize build models/ornith-9b/overlays/ci | kubectl apply -f -
      - name: Smoke and contract tests
        run: |
          sudo apt-get update && sudo apt-get install -y bats
          bats tests/smoke/01-wave0.bats tests/smoke/02-gateway.bats \
               tests/smoke/03-identity.bats tests/smoke/04-kserve.bats \
               tests/smoke/06-auth-quota.bats tests/contract/
```

The runner has 4 vCPU, so the observability, autoscaling, availability, and benchmark suites are deliberately excluded. Say so in the workflow with a comment rather than leaving a reader to wonder.

Two CI steps from the spec are **not** implemented in phase 1, and the reason belongs in the workflow as a comment so nobody later assumes they were forgotten:

```yaml
  # Not present in phase 1, deliberately:
  #   - multi-arch image build: this repository owns no image. The engine is
  #     upstream ghcr.io/ggml-org/llama.cpp, pinned by digest.
  #   - image signing and SBOM: nothing to sign until we build something.
  # Both arrive with the first image this repository owns. Until then, supply
  # chain control is the digest pin plus the disallow-floating-tags policy.
```

- [ ] **Step 7: Run locally, then in CI**

```bash
kustomize build models/ornith-9b/overlays/ci >/dev/null && echo "ci overlay builds"
bats tests/smoke/11-policy.bats
```

Expected: 3 tests, 3 passed. Then push the branch and confirm all three CI jobs are green.

- [ ] **Step 8: Commit**

```bash
git add policy .github/workflows/ci.yml models/ornith-9b/overlays/ci versions.yaml
git commit -m "feat(ci): Kyverno policies plus arm64 CI running the smoke suite

The digest policy immediately found a floating curlimages/curl:latest tag
already in the repository, which is the point of enforcing it in both places.

CI runs on ubuntu-24.04-arm so it exercises the same architecture as the
development machine. With 4 vCPU it uses a 0.5B model and skips the
observability, scaling, availability, and benchmark suites."
```

---

## Task 14: Recovery drill and the phase 1 report

**Files:**
- Create: `docs/runbooks/recovery-drill.md`
- Create: `docs/runbooks/keycloak-for-real.md`
- Create: `docs/08-why-llm-d.md` (phase 3 preview, written from measurement)
- Create: `bench/results/<date>-recovery/summary.md`
- Modify: `Taskfile.yml`, `README.md`

**Interfaces:**
- Consumes: everything.
- Produces: `task drill:recovery` measuring time to first token after destroying the namespace; a documented recovery time objective; the phase 1 completion record.

- [ ] **Step 1: Write the failing test**

Add `tests/smoke/12-recovery.bats`:

```bash
setup() { load '../lib/helpers'; }

@test "recovery drill records a time to first token" {
  run bash -c "./bench/recovery-drill.sh"
  [ "$status" -eq 0 ]
  latest=$(ls -1dt bench/results/*-recovery/ | head -1)
  run bash -c "jq -r .seconds_to_first_token '${latest}result.json'"
  [ "$output" -gt 0 ]
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bats tests/smoke/12-recovery.bats
```

Expected: failure, the script does not exist.

- [ ] **Step 3: Write the drill**

Create `bench/recovery-drill.sh`:

```bash
#!/usr/bin/env bash
# Destroys the workload namespace and measures how long Argo CD needs to get
# back to a first answered token. That number, not the time to Ready, is the
# recovery time objective for an LLM service.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="bench/results/$(date +%Y-%m-%d)-recovery"
mkdir -p "$OUT"

start=$SECONDS
kubectl delete namespace llm --wait=true

# Argo CD rebuilds without human help. If it does not, the drill has found a
# manual step and that is the finding.
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  applications.argoproj.io --all --timeout=40m

TOKEN="$(source tests/lib/helpers.bash && get_token llm-tier-pro)"
until curl -sf http://llm.localtest.me/v1/models -H "authorization: Bearer $TOKEN" >/dev/null; do
  sleep 5
done
elapsed=$((SECONDS - start))

jq -n --arg s "$elapsed" \
  --arg model "$(yq -r '.model.local.hf_file' models/ornith-9b/base/model.yaml)" \
  --arg machine "$(uname -m)" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{seconds_to_first_token: ($s|tonumber), model: $model, machine: $machine, date: $date}' \
  > "$OUT/result.json"

printf 'recovery: %s seconds to first token\n' "$elapsed" | tee "$OUT/summary.md"
```

- [ ] **Step 4: Run the drill and record the number**

```bash
chmod +x bench/recovery-drill.sh
task drill:recovery
cat bench/results/*-recovery/result.json
bats tests/smoke/12-recovery.bats
```

Expected: 1 test, 1 passed, and a real number in seconds.

- [ ] **Step 5: Write the two runbooks**

Create `docs/runbooks/recovery-drill.md`: the command, the measured number with its date, where the time actually went (namespace deletion, Argo sync, weight download, weight load), and the single change that would most reduce it.

Create `docs/runbooks/keycloak-for-real.md`: what production Keycloak requires that this repository deliberately does not build, namely an external database, clustering, backup and restore of the realm, and secrets from `external-secrets` rather than a committed dev secret. State plainly that dev mode loses all state on restart and that the realm file is what makes that acceptable here.

- [ ] **Step 6: Write `docs/08-why-llm-d.md` from your own numbers**

Use the shared-prefix scenario from Task 11. Report the throughput difference between the shared-prefix run and the short-prompt run on this engine, then state the specific claim phase 3 will test: that cache-aware routing across replicas produces a further gain, against the reported 3x output tokens per second and 2x lower time to first token from ADR 0003 which remain unverified.

- [ ] **Step 7: Check phase 1 against its acceptance criteria**

Run the whole suite and confirm the nine criteria in the spec, section 15:

```bash
bats tests/
```

Record the result in `README.md`, replacing the "Getting started: not yet" section with the real quick start, and add a short status line stating which of the nine criteria hold and the date checked.

- [ ] **Step 8: Commit**

```bash
git add bench/recovery-drill.sh bench/results docs/runbooks docs/08-why-llm-d.md README.md Taskfile.yml tests/smoke/12-recovery.bats
git commit -m "feat(dr): recovery drill measuring time to first token, and phase 1 report

The drill deletes the workload namespace and lets Argo CD rebuild, measuring
time to a first answered token rather than time to Ready. For an LLM service
the difference is the weight download, which is most of the number.

README now records which of the nine phase 1 acceptance criteria hold, with the
date checked."
```

---

## Notes for the executor

**Where this plan is deliberately incomplete, and why.** Four values cannot be honestly written in advance, so each has a step that discovers it and a file that records it:

1. Upstream chart names and versions (Task 1, steps 4 and 5). Documentation pages disagreed with release notes when the spec was written, so every version is read at execution time and stored in `versions.yaml` with its date.
2. The GGUF repository and filename for the quantised model (Task 6, step 1). The model card lists 102 community quantisations; picking one at execution time and pinning it with a checksum is correct, guessing a repository name is not.
3. Engine metric names (Task 7, step 1). These come from a running `/metrics` endpoint and go into ADR 0006.
4. Kuadrant and Kyverno CRD apiVersions (Tasks 8 and 13). These change between releases, so each is checked against the installed CRD before the manifest is applied.

**When a task fails in a way this plan did not predict**, stop and write it down before working around it. The spec's risk table has eight entries; a ninth is a finding, not an inconvenience.

**Do not soften a failing test to make a task pass.** If the 429 test cannot reach the limit, the quota is not working, and changing the loop count hides that. The same applies to the streaming-through-restart test, which is the one most likely to be quietly weakened.
