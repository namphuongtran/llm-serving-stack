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
through `platform/50-argocd`, the model overlay, the OIDC policies) has an
imperative install script. Without Argo CD, "install everything" means running
**nine** `install.sh` scripts by hand (counted 2026-09-04 with `ls
platform/*/install.sh`), in the right order, and remembering to re-run any of
them by hand again after every git change. That is exactly the failure mode this
layer exists to close: a step a human ran once and never wrote down is invisible
until the cluster is rebuilt without that human present.

Running the nine in numeric order is also **not enough**, and this was found by
doing it (`docs/deployment-walkthrough.md`, "The step order"):

- `platform/10-istio/gateway-api-crds.sh` exists and is correct, and no
  `install.sh` calls it. Only `.github/workflows/ci.yml` does. So the nine
  scripts install no Gateway API CRDs, and the istio layer then fails with `no
  matches for kind "Gateway"`. That ordering requirement lived only in CI.
- `model` and `security` have **no imperative script at all**. They exist only
  as Argo CD Applications, so the walkthrough applies the same manifests by
  hand.

Thirteen steps, nine scripts. The four-step gap is the argument.

## What the second path found that the first could not

Fifteen defects came out of the first three runs of the pull-based path, and
**none of them was visible from the imperative path**. That is the argument for
keeping two paths, stated as a result rather than as a principle. Two are worth
knowing before editing anything under `clusters/local-kind/`.

**Argo CD applies client-side by default**, which writes each rendered manifest
into an annotation capped at 262144 bytes. Five of the fifteen charts here ship
CRDs larger than that, so KServe, Kyverno, Kuadrant, the observability stack, and
KEDA all failed to install. `helm install` never writes that annotation, which is
exactly why the imperative path installs the same charts without complaint. One
tool's default made five layers fail, and the other tool could not have shown it.

**An Argo CD Application that fails to read its git path still reports
`health.status: Healthy`.** That single property broke both the acceptance check
and sync-wave ordering, and it made `task local:up` exit 0 **in one second** on a
cluster where nothing had been deployed.

The consequences are permanent, and they are why two scripts exist:

| Belief | What replaced it |
|---|---|
| `.status.health.status` means the Application did something | `clusters/local-kind/wait-for-sync.sh` reads sync status, counts the children against the directory, and requires every Application green in the same sample |
| Sixteen green Applications means the service works | `clusters/local-kind/verify-serving.sh` asserts the request path: 401 without a token, then 200 with a real JWT |

Run 3 is why the second row is not paranoia. It exited **0**, all sixteen
Applications were `Synced` and `Healthy` in three consecutive samples, and the
first request was `GET /v1/models` with no token returning **HTTP 200**
(`docs/STATUS.md`, criterion 1). Do not weaken `verify-serving.sh` to "not 200":
503 is the fail-closed case and would satisfy that.

R24 is the same shape, found later and still open. On 2026-08-21 a pushed change
to the predictor's pod template could not roll out, because the Deployment's
surge arithmetic deadlocks against this cluster's topology constraint.
Throughout, the Application read `Synced` and `Healthy`, the `ServingRuntime` on
the cluster carried the new spec, and the pod serving traffic carried the old
one. **A green Application means git and the API server agree. It does not mean
the workload changed.**

One thing the pull path already had and the imperative path did not:
`clusters/local-kind/root-app.yaml:28` sets `retry: limit 20`, so Argo CD rides
out a webhook that is not reachable yet. The imperative scripts had no such
retry, and four consecutive CI runs died on that gap before
`platform/lib/apply.sh` was written (`docs/STATUS.md`, "The webhook readiness
race").

## What it costs to run

Argo CD itself is one more workload on a 32 GB machine already running Istio,
Keycloak, Prometheus, KServe, and a 5.6 GB model. `platform/50-argocd/install.sh`
does not set resource requests or limits explicitly, so the chart's own defaults
apply.

Measured 2026-08-19: the `argocd` step took **44 seconds** and moved the cluster
from 6214 MiB to 7043 MiB, an **829 MiB** jump, taking the pod count from 50 to
59 (`docs/deployment-log.tsv`). That is a whole-cluster delta rather than an
isolated figure for the four Argo CD workloads.

> **Unmeasured (2026-08-19):** `argocd-server`, `argocd-repo-server`,
> `argocd-application-controller`, and `argocd-redis`'s memory footprint
> separately. **The reason has changed and the per-pod reading has not been
> taken.** This marker originally said no cluster existed; one has existed since
> 2026-08-19. Run `kubectl -n argocd top pod --no-headers` once a cluster is up.
> kind installs no metrics-server, so `docker stats` on the node containers is
> the fallback the rest of this repository uses.

**Two further costs are not measured in megabytes, and both were found by
running.**

**Every value exists twice** (R3). An Argo CD Application is one git object and
cannot read a values file from this repository, so chart values and image digests
are copied inline into the Application. Changing a value or a digest means
changing both copies, and no mechanism detects a half-applied change. Grep for
the old string on every change.

**The two paths are not interchangeable on an existing cluster, in either
direction.** `./platform/12-kyverno/install.sh` on a cluster that Argo CD built
exits 1 at its **first** command:

```
Error: unable to continue with install: ServiceAccount "kyverno-admission-controller"
in namespace "kyverno" exists and cannot be imported into the current release:
invalid ownership metadata; annotation validation error: missing key
"meta.helm.sh/release-name"
```

Argo CD renders the chart and applies it, so Helm holds no release record.
`CLAUDE.md` describes the install scripts as a working manual bootstrap, and that
holds **only on a cluster those scripts built**.

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

**Measured 2026-08-20: `task local:down && task local:up` took 17 minutes 9
seconds and exited 0**, on a machine with Docker given 10 CPUs and 23.2 GiB. It
deleted a running 3-node cluster, built a new one, installed Argo CD, applied
`root-app.yaml`, and reached a ready service with no step run by hand: sixteen
Applications `Synced` and `Healthy` in three consecutive samples, then 401
without a token and a streamed answer with one. Started 05:44:19Z, finished
06:01:29Z. That is the proof the whole tree is reproducible from git alone.

> **Unmeasured (2026-08-20):** the wall-clock time of
> `task local:down && task local:up && bats tests/`, end to end, on this
> machine. **The 17m09s above is a lower bound for it, not the number**, because
> that run stopped at `local:up` and never ran the suites. This marker stays
> until the full command runs. `docs/deployment-walkthrough.md` has the per-layer
> timings from the imperative path, totalling 9 minutes 59 seconds for the
> platform layers, which is a second, looser floor. Run the full command once and
> record the number here with its date; it is also the starting point for the
> recovery time objective `bench/recovery-drill.sh` measures in Task 14 (that
> drill deletes the `llm` namespace and lets Argo CD rebuild it, which is a
> strict subset of this full rebuild).
