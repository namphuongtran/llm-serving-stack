# Why delivery is pull based

## The question this answers

Why can a CI pipeline not deploy to a cluster running on a laptop?

A push-based pipeline (CI runs `kubectl apply` at the end of a build) needs a
network path from GitHub's runners to this specific laptop, plus a credential
that pipeline can use to authenticate to it. Neither exists, and both are the
wrong thing to build even if they could: a laptop that is off, asleep, or
behind a different network the next day would silently break every deploy.

Argo CD inverts this. It runs inside the cluster and pulls from git on its own
schedule; nothing outside the cluster ever needs a path in. The same
`clusters/local-kind/` tree that drives this laptop's `kind` cluster is the
shape a real GPU cluster's Argo CD instance reads too (`clusters/gpu-cloud/`,
not built in phase 1) - the delivery mechanism does not change between
phases, only which directory of Applications it points at.

## What breaks if this layer is removed

Every platform layer this repository builds (`platform/00-cert-manager`
through `platform/40-keda`, the model overlay, the OIDC policies) has an
imperative install script that predates this task. Without Argo CD, "install
everything" means running eight scripts by hand, in the right order, and
remembering to re-run any of them by hand again after every git change. That
is exactly the failure mode Task 12 exists to close: a step a human ran once
and never wrote down is invisible until the cluster is rebuilt without that
human present.

## What it costs to run

Argo CD itself is one more workload on a 32 GB machine already running Istio,
Keycloak, Prometheus, KServe, and a 6 GB model. `platform/50-argocd/install.sh`
does not set resource requests/limits explicitly (the chart's own defaults
apply), so this is a real number this repository has not yet measured.

> **Unmeasured (2026-08-19):** `argocd-server`, `argocd-repo-server`,
> `argocd-application-controller`, and `argocd-redis`'s combined memory
> footprint on this machine, run
> `kubectl -n argocd top pod --no-headers` once a cluster exists.

## The one thing that surprised me while building it

Writing the Argo CD Applications for layers that already had install scripts
(Tasks 2 through 11) is what turned this task into an audit rather than a
straightforward wiring exercise. Every install script that used
`kubectl create configmap ... --dry-run=client | kubectl apply -f -`, a
`kubectl apply -f - <<'YAML' ... YAML` heredoc, a `sed` placeholder
substitution, or a `kubectl patch` against a controller-generated object
turned out to be an imperative step with no equivalent git object for an
Argo CD Application to source. None of these were deliberate shortcuts; each
made sense as a single imperative script run once. They only become visible
as a gap when a second, independent path (GitOps) has to reproduce the exact
same end state from git alone. Found and converted in this task:

| Imperative step | Where | Declarative replacement |
|---|---|---|
| `kubectl create configmap keycloak-realm --from-file=...` | `platform/15-keycloak/install.sh` | `configMapGenerator` in `platform/15-keycloak/kustomization.yaml` |
| `sed -e "s\|IMAGE_PLACED_BY_INSTALL_SCRIPT\|...\|"` | `platform/15-keycloak/install.sh` | Digest written directly into `platform/15-keycloak/keycloak.yaml` |
| `kubectl create configmap llm-serving-dashboard ... \| kubectl label ...` | `platform/30-observability/install.sh` | `configMapGenerator` in `platform/30-observability/kustomization.yaml` |
| `kubectl apply -f - <<'YAML'` (PodMonitor) | `platform/30-observability/install.sh` | Committed file `platform/30-observability/podmonitor.yaml` |
| `kubectl apply -f - <<'YAML'` (Kuadrant CR) | `platform/25-kuadrant/install.sh` | Committed file `platform/25-kuadrant/kuadrant.yaml` |
| `kubectl create namespace llm ... \| kubectl label namespace llm istio.io/dataplane-mode=ambient` | `platform/10-istio/install.sh` | Committed file `platform/10-istio/namespace-llm.yaml` |
| `kubectl patch svc llm-istio --type=merge -p '{"spec":{"type":"NodePort",...}}'` | `platform/10-istio/install.sh` | `networking.istio.io/service-type: NodePort` annotation on `gateway.yaml`, plus a PostSync hook Job (`platform/10-istio/gateway-service-nodeport.yaml`) for the exact `nodePort` number, which that annotation does not cover (open upstream gap, istio/istio#45113) |

The install scripts themselves were left in place rather than deleted: they
remain a working manual bootstrap, now a second, parallel path to the same end
state that `task local:up` drives through Argo CD instead.

## Rebuild time

Section 15 of the design spec requires `task local:up` to take an empty
machine to a ready service; Task 12's step 6 asks for that rebuild to be
timed as proof the whole tree is reproducible from git alone, with no step run
by hand outside `local:up` itself.

> **Unmeasured (2026-08-19):** the wall-clock time of
> `task local:down && task local:up && bats tests/`, end to end, on this
> machine. The memory constraint that once blocked this is gone: Docker Desktop
> was raised to 23.2 GiB the same day and a cluster ran the whole stack. But it
> ran through the imperative path, not `task local:up`, so this number is still
> owed. `docs/deployment-walkthrough.md` has the per-layer timings that came out
> of that run, totalling 9 minutes 33 seconds for the platform layers, which is a
> floor for this number and not a substitute for it. Run that command
> once and record the number here with its date; it is also the starting
> point for the recovery time objective `bench/recovery-drill.sh` measures in
> Task 14 (that drill deletes the `llm` namespace and lets Argo CD rebuild
> it, which is a strict subset of this full rebuild).
