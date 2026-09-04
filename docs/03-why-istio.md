# Why a mesh-capable gateway

Status: written 2026-09-04. The design reasoning below never needed a cluster.
The operating sections did, and a cluster has existed since 2026-08-19, so they
are now written from what it did rather than from what was expected. One
resource number is still owed and is marked as such. Full decision record:
[ADR 0003](adr/0003-gateway-istio-ambient.md).

## The question this answers

Why does the choice of proxy come down to one Envoy filter called ext_proc?

The gateway choice looks like "Envoy Gateway versus Istio versus Traefik". That
framing is wrong: **Istio's data plane is Envoy.** A sidecar is Envoy. An Istio
ingress gateway is Envoy. So the real comparison is between a gateway that
manages Envoy for north-south traffic only (Envoy Gateway), a mesh that manages
Envoy for both directions (Istio), and a different proxy entirely (Traefik) that
is not built on Envoy at all.

What actually decides the question for LLM serving is one filter. The Gateway API
Inference Extension's endpoint picker (the component that performs cache-aware
routing, sending a request to the pod that already holds the matching KV cache
instead of a pod that would have to recompute the prefill) is implemented as an
Envoy external processing (`ext_proc`) server. A gateway that does not expose
`ext_proc` cannot host that endpoint picker, no matter how good its general
Gateway API conformance is: ADR 0003 notes Traefik has full conformance and still
does not qualify, because no evidence of `ext_proc` support was found for it. So
the question is not "which gateway is best" in general, it is "which gateway can
run this one filter". That is what makes Istio (Envoy underneath) and Envoy
Gateway (Envoy directly) the only two real candidates. ADR 0003 picks Istio in
ambient mode over Envoy Gateway for the reasons recorded there, chiefly that
Kuadrant, the policy layer chosen in ADR 0004, needed to survive a gateway
change, and Istio adds east-west mTLS as a mesh that a plain gateway does not.

## What breaks if this layer is removed

There would be no single entry point for `llm.localtest.me`, no place to
terminate the Gateway API routes that the API and Keycloak share, and no data
plane capable of hosting the `ext_proc`-based endpoint picker that phase 3
depends on for cache-aware routing.

The middle item is the one that turned out to matter most, and it is not
obvious from the manifests. Three separate things sit behind the same Gateway:

| Route | Where | Consequence |
|---|---|---|
| `/v1/*`, the inference API | `models/ornith-9b/.../httproute` | The workload |
| `/realms/*`, Keycloak | `platform/15-keycloak/httproute.yaml:13` | Token issuance |
| OIDC discovery, from Authorino | `security/oidc/authpolicy.yaml:30` | The auth decision itself |

The third row is a loop, and it was confirmed on a live cluster on 2026-08-20
rather than inferred: in-cluster DNS resolves `llm.localtest.me` to
`10.96.147.130`, which is the gateway Service `istio-system/llm-istio`, while
Keycloak's own Service is `10.96.216.103`
(`docs/sad/11-risks-and-debt.md`, R11). So Authorino resolves the issuer
**through the very gateway it is filtering**. Under sustained load that loop
degrades the reject path: 2 of 20 requests carrying no token at all returned
HTTP 500 instead of 401, and under heavier load 6 of 10 requests with a valid
token returned 500 (`docs/STATUS.md`, "The first load test", finding 2). It
fails closed and never returns 200 without a token, so it is a reliability
defect and not a security hole. It is still the clearest measured statement of
what "one entry point" costs.

## What ambient mode gives, and what it does not

Ambient was chosen for footprint: one ztunnel per node instead of one proxy per
pod. It also gives east-west mTLS, which is the mesh half of the decision.

**mTLS is not authorisation, and this repository measured the difference.**
Only namespace `llm` carries `istio.io/dataplane-mode: ambient`
(`platform/10-istio/namespace-llm.yaml`). Both Kuadrant policies attach to an
`HTTPRoute`, so they see gateway traffic only. `git grep 'kind:
AuthorizationPolicy\|kind: NetworkPolicy'` returned nothing on 2026-08-20, which
means any pod in the cluster could call `ornith-9b-predictor` directly with no
token and no quota (R12).

The attempt to close that gap is the more useful record. An
`AuthorizationPolicy` allowing only the gateway and Prometheus did close it: all
four in-cluster paths went from HTTP 200 to a reset connection, and the gateway
path stayed correct. **It also killed every predictor metric.** All three scrape
targets went `health=down`, because `observability` is not in the mesh, so
Prometheus is a plain pod with no SPIFFE identity and its principal can never
match. `llamacpp:requests_deferred` returned nothing, which silently removes
KEDA's only input. The policy was deleted rather than kept. Enrolling a second
namespace in the mesh is the real next step, and `node-exporter` on host
networking is in the way.

## What it costs to run

Measured 2026-08-19 on a 3-node kind cluster: the `istio` step took **46
seconds** and moved the cluster from 1546 MiB to 1992 MiB, a **446 MiB** jump
(`docs/deployment-log.tsv`). That figure covers istiod, three ztunnels, and the
gateway together, and it is a whole-cluster delta rather than an isolated
measurement of any one of them.

> **Unmeasured (2026-08-19):** the resident memory of `istiod` and `ztunnel`
> separately, on this machine. **The reason has changed and the number has
> not.** This marker originally said no cluster existed; one has existed since
> 2026-08-19 and the per-pod reading was never taken. Run `kubectl -n
> istio-system top pod --no-headers` once a cluster is up. kind installs no
> metrics-server, so `docker stats` on the node containers is the fallback the
> rest of this repository uses.

This is still the number that would test the ztunnel-versus-sidecar footprint
figures ADR 0003 quotes from vendor blogs (roughly 0.06 vCPU and 12 MB per node
for ztunnel, against roughly 0.20 vCPU and 60 MB per pod for a sidecar, both
explicitly marked not verified there). **The 446 MiB above neither confirms nor
refutes them**, because it does not separate the three components and this
cluster serves no load at that point in the install.

A second cost is structural rather than numeric. Istio owns the gateway
Deployment, so parts of it are not yours to configure. Two examples, both from
this repository:

- The `NodePort` number could not be set declaratively. The
  `networking.istio.io/service-type: NodePort` annotation covers the Service
  type and not the port number, so `platform/10-istio/gateway-service-nodeport.yaml`
  is a PostSync hook Job that patches it. The gap is upstream, istio/istio#45113.
- The Deployment's pod template is reverted by `istio.io/gateway-controller`,
  which is why the fix in the next section is a CronJob rather than a probe.

## The one thing that surprised me while building it

**The gateway fetches its policy shim once, fails closed, and never looks
again.** Measured on a live cluster on 2026-08-20, eight hours into a healthy
run, with no bootstrap or install involved.

Kuadrant enforces through a Wasm module that Envoy fetches over HTTP. The
Kuadrant operator container died at 13:36:45Z and came back at 13:37:06Z, a
21-second window. Inside it, at **13:36:52.999Z**, the gateway exhausted its
fetch retries:

```
Retry limit exceeded for fetching data from remote data source
Plugin kuadrant-wasm-shim failed to load
Plugin configured to fail closed failed to load
```

The Service endpoint was healthy again 13 seconds later and Envoy never looked.
**Every request returned 503, token issuance included**, because Keycloak sits
behind the same gateway. `kubectl rollout restart deploy/llm-istio` fixed it in
one attempt.

One correction is worth keeping, because it changes what the fix has to be. This
repository said for a day that the fetch went to a remote registry. It does not.
The `EnvoyFilter` `istio-system/kuadrant-llm` names
`http://kuadrant-operator-wasm.kuadrant-system.svc.cluster.local:8082/plugin.wasm`,
an in-cluster Service. A dependency on the public internet and a dependency on
another pod in this cluster have different fixes, and only one of them is
something this repository can do anything about.

The fix is `platform/10-istio/wasm-watchdog.yaml`, a CronJob that reads the one
metric that discriminates the two states and patches the Deployment's pod
template, which is what `kubectl rollout restart` does. A readiness probe would
have been better and is not available, for the ownership reason above: the
Deployment is reverted by `istio.io/gateway-controller`, and the `EnvoyFilter`
is labelled `kuadrant.io/managed=true` with no `retry_policy` to widen.

Proved by mutation twice, on 2026-08-20: broke at 15:04:28Z and served HTTP 401
again at 15:08:15Z, then broke at 15:16:38Z and recovered at 15:20:19Z. So
**3m47s and 3m41s unattended, against unbounded before**. Watched for six
minutes and four further runs afterwards, the Deployment `generation` stayed at
7, so one failure gives exactly one restart. Two samples are a measurement and
not a guarantee.

What surprised me is not that a fetch failed. It is that choosing a mesh means
the most important Deployment in the request path is written by a controller,
and the ordinary tool for this problem, a probe, was unavailable for that exact
reason. The gateway was reversible in the sense ADR 0003 promised, and it was
not configurable in the sense a hand-written Deployment would have been.
