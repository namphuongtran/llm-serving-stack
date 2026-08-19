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
sets `minReplicaCount: 1` deliberately, and the alternative
(`overlays/cost-saving/`) is opt-in with its cold start measured rather than
assumed.

> **Unmeasured (2026-08-19):** the wall-clock time from a cold `ornith-9b-predictor`
> replica count of 0 to the first successful response, using the
> `cost-saving` overlay. No cluster exists in this authoring pass (plan
> Ruling 9), so this has not been run. Once a cluster exists:
> ```
> kustomize build models/ornith-9b/overlays/cost-saving | kubectl apply -f -
> kubectl -n llm wait --for=jsonpath='{.spec.replicas}'=0 deploy/ornith-9b-predictor --timeout=10m
> TOKEN=$(source tests/lib/helpers.bash && get_token llm-tier-pro)
> start=$SECONDS
> curl -sf http://llm.localtest.me/v1/models -H "authorization: Bearer $TOKEN" >/dev/null
> echo "cold start from zero: $((SECONDS - start))s"
> kustomize build models/ornith-9b/overlays/local | kubectl apply -f -   # restore minReplicaCount: 2
> ```

## What breaks if this layer is removed

Without KServe, every model needs its own hand-maintained Deployment,
Service, HPA (or, here, `ScaledObject`), and `HTTPRoute`, each free to drift
from the others in small ways - a different readiness probe, a different
port name, a different label selector. The `PodMonitor` in
`platform/30-observability/install.sh` and the `ScaledObject` in
`models/ornith-9b/overlays/local/scaledobject.yaml` both depend on
conventions KServe enforces once (the container port named `http`, the
`serving.kserve.io/inferenceservice` label, the predictor Deployment named
`<isvc>-predictor`); without it, every model owner would have to reproduce
those conventions correctly by hand.

## What it costs to run

A controller to install, secure, upgrade, and debug, on a laptop that already
runs Istio, Kuadrant, Keycloak, Prometheus, Grafana, and KEDA (ADR 0002's own
"cost accepted" section names this same list). `platform/20-kserve/install.sh`
installs exactly the two charts Standard mode needs
(`kserve-crd`, `kserve-resources`), not the full ten-chart catalogue, to keep
that cost to what this phase actually uses.

## The one thing that surprised me while building it

Not something found while building, but something the plan asked for that
could not be produced the way it was asked: a measured cold-start number,
committed as evidence rather than left as ADR 0002's promise. No cluster
exists in phase 1 authoring to scale `ornith-9b-predictor` to zero and back
(see the Unmeasured marker above). The `cost-saving` overlay itself is
complete and would produce that number the first time it runs against a real
cluster; what is missing is the number, not the mechanism.
