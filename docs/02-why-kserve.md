# Why a control plane

## The question this answers

Why not hand-write a Deployment, Service, HPA, and route for each model?

## Answer

A hand-written Deployment has no shared idea of what "ready" means for a
model server: a TCP-open check would report ready long before weights finish
loading, and every model would need its own bespoke readiness probe wired by
hand. KServe's `InferenceService` gives every model the same contract -
`ServingRuntime` supplies the engine, the `InferenceService` supplies the
model - so swapping a model (or, in phase 2, swapping the engine) changes one
resource instead of rewriting a Deployment, Service, and route together. The
`ServingRuntime`/`InferenceService` split in this repository
(`runtimes/llamacpp-arm64/` versus `models/ornith-9b/`) is exactly this
contract: nothing about Ornith-1.0-9B lives in the runtime file, and nothing
about llama.cpp lives in the model file.

`InferenceService` Standard mode was chosen over Knative serverless mode for
a reason worth repeating here rather than only in ADR 0002: scale to zero and
availability are in direct conflict for this workload. Model weights are
gigabytes; a pod starting from zero must load them before it can answer a
single request, which is minutes rather than seconds. Knative's autoscaler
treats scale to zero as a free feature and would apply it by default; KServe
Standard mode does not, so `models/ornith-9b/overlays/local/scaledobject.yaml`
sets `minReplicaCount: 2` deliberately, and the alternative
(`overlays/cost-saving/`) is opt-in with its cold start measured rather than
assumed.

That minutes-rather-than-seconds claim now has a number beside it. On
2026-08-19 the whole cluster sat at 7089 MiB two seconds after the model layer's
`kubectl apply` returned, and at 17855 MiB once both models were resident
(`docs/deployment-log.tsv`, rows 12 and 13). The weights are **10766 MiB** of
that. Loading them is the cold start, and nothing about scale to zero makes it
cheaper.

## What the contract looked like once it ran

The `ServingRuntime`/`InferenceService` split is a claim about where facts
live, and running the stack tested it twice. It failed once and it held once.

**It failed on memory sizing (R16, found 2026-08-20).**
`runtimes/llamacpp-arm64/servingruntime.yaml` requested 8Gi and limited 12Gi.
Those numbers were chosen for a 9B Q4 model at `--ctx-size 4096`, which makes
them a model fact sitting in the runtime file. The proof was already in the
repository and nobody had read it that way: `fallback-small` had to override
them to 1Gi and 2Gi in `models/ornith-9b/overlays/local/fallback.yaml`. An
override is what a misplaced fact looks like from the other side. The fix moved
`resources` into `models/ornith-9b/overlays/local/patch-resources.yaml`, and it
was verified by reading the rendered overlay rather than the source:
`ornith-9b` carries 8Gi and 12Gi, `fallback-small` carries its own 1Gi and 2Gi,
and the `ServingRuntime` container renders no `resources` at all.
`--ctx-size` and `--parallel` are still in the runtime file and deserve the same
treatment.

**It held on model naming.** No model name appears in `runtimes/`, checked by
`task lint` on every overlay, and the runtime carries a comment saying why
`--alias` is not set there.

The lesson is the one boundary 1 in `CLAUDE.md` states: a boundary is not
enforced by a directory layout. It is enforced by somebody noticing an override.

## What breaks if this layer is removed

Without KServe, every model needs its own hand-maintained Deployment,
Service, HPA (or, here, `ScaledObject`), and `HTTPRoute`, each free to drift
from the others in small ways - a different readiness probe, a different
port name, a different label selector. The `PodMonitor` in
`platform/30-observability/podmonitor.yaml` and the `ScaledObject` in
`models/ornith-9b/overlays/local/scaledobject.yaml` both depend on
conventions KServe enforces once (the container port named `http`, the
`serving.kserve.io/inferenceservice` label, the predictor Deployment named
`<isvc>-predictor`); without it, every model owner would have to reproduce
those conventions correctly by hand.

Those conventions were exercised on 2026-08-20 rather than assumed. The
`PodMonitor` selects predictor pods by that label and Prometheus scraped all
three of them; when an `AuthorizationPolicy` experiment cut the scrape path, all
three targets went `health=down` together and `llamacpp:requests_deferred`
returned nothing at all, which silently takes KEDA's only input with it
(`docs/sad/11-risks-and-debt.md`, R12). One convention, three consumers, one
failure.

## What it costs to run

A controller to install, secure, upgrade, and debug, on a laptop that already
runs Istio, Kuadrant, Keycloak, Prometheus, Grafana, and KEDA (ADR 0002's own
"cost accepted" section names this same list). `platform/20-kserve/install.sh`
installs exactly the two charts Standard mode needs
(`kserve-crd`, `kserve-resources`), not the full ten-chart catalogue, to keep
that cost to what this phase actually uses.

Measured 2026-08-19: the `kserve` step took **47 seconds** and moved the cluster
from 3378 MiB to 3835 MiB, a **457 MiB** jump. That is a whole-cluster delta and
includes anything else that moved in the same window, not an isolated figure for
the controller (`docs/deployment-log.tsv`).

Two further costs only appear once the controller is running, and neither was
predicted:

**The controller reports ready before it can admit anything.** Its readiness
probe is `/readyz` on port **8081** while its admission webhook serves on
**9443**, so `kubectl rollout status` returning does not mean a `ServingRuntime`
will be accepted. CI hit exactly that gap: `successfully rolled out` at
`06:45:08.0058`, `connection refused` from
`servingruntime.kserve-webhook-server.validator` at `06:45:08.2002`, **194 ms**
apart (`docs/STATUS.md`, "The webhook readiness race"). This document opens by
saying a control plane gives every model one idea of what ready means. It is
worth stating plainly that the control plane's own readiness did not cover its
own webhook.

**The Deployment is KServe's, and its defaults can deadlock against your
constraints.** R24, measured 2026-08-21: no rolling update of the predictor can
complete on this cluster. `maxSurge` is 25% of 2 replicas, which rounds **up**
to 1; `maxUnavailable` is 25% of 2, which rounds **down** to 0. So the Deployment
must add a pod before removing one, and the new pod cannot schedule against the
topology spread constraint. Throughout, Argo CD read `Synced` and `Healthy`, the
`ServingRuntime` on the cluster carried the new spec, and the pod serving traffic
carried the old one. A hand-written Deployment would have had the same arithmetic
problem, and it would have been yours to change.

## The cold start this repository still owes

> **Unmeasured (2026-08-19):** the wall-clock time from a cold
> `ornith-9b-predictor` replica count of 0 to the first successful response,
> using the `cost-saving` overlay. **The reason has changed and the number has
> not.** This marker originally read "no cluster exists in this authoring pass";
> a cluster has existed since 2026-08-19 and the measurement has simply not been
> taken. Once a cluster is up:
> ```
> kustomize build models/ornith-9b/overlays/cost-saving | kubectl apply -f -
> kubectl -n llm wait --for=jsonpath='{.spec.replicas}'=0 deploy/ornith-9b-predictor --timeout=10m
> TOKEN=$(source tests/lib/helpers.bash && get_token llm-tier-pro)
> start=$SECONDS
> curl -sf http://llm.localtest.me/v1/models -H "authorization: Bearer $TOKEN" >/dev/null
> echo "cold start from zero: $((SECONDS - start))s"
> kustomize build models/ornith-9b/overlays/local | kubectl apply -f -   # restore minReplicaCount: 2
> ```
> Read R24 before running this. A change to the predictor's pod template cannot
> roll out on a two-worker cluster, so restoring the local overlay may need a
> deliberate delete rather than an update.

## The one thing that surprised me while building it

That the interesting failures of a control plane are not the ones it was chosen
to prevent.

KServe did the job it was picked for. Two models, one runtime, one set of
conventions, and both `InferenceService` objects reported `READY=True` on
2026-08-20. Nothing in this document's first section turned out to be wrong.

What went wrong sat one level down, in the parts a control plane owns on your
behalf and therefore hides. Its webhook was not ready when it said it was ready.
Its Deployment's rollout strategy cannot satisfy this cluster's topology rules,
and the layer above reported green while the workload did not move. Both are
costs of delegation, and neither is visible from the manifest you wrote. They
are visible from the objects the controller wrote for you, which is a different
thing to go and read.
