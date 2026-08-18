# Why a mesh-capable gateway

Status: half written. The design reasoning below does not need a cluster to
state. The resource-usage measurement does, and no cluster exists on this
machine yet (see docs/adr/0003 for the full decision record).

## The question this answers

Why does the choice of proxy come down to one Envoy filter called ext_proc?

The gateway choice looks like "Envoy Gateway versus Istio versus Traefik".
That framing is wrong: **Istio's data plane is Envoy.** A sidecar is Envoy.
An Istio ingress gateway is Envoy. So the real comparison is between a
gateway that manages Envoy for north-south traffic only (Envoy Gateway), a
mesh that manages Envoy for both directions (Istio), and a different proxy
entirely (Traefik) that is not built on Envoy at all.

What actually decides the question for LLM serving is one filter. The
Gateway API Inference Extension's endpoint picker (the component that
performs cache-aware routing, sending a request to the pod that already
holds the matching KV cache instead of a pod that would have to recompute
the prefill) is implemented as an Envoy external processing (`ext_proc`)
server. A gateway that does not expose `ext_proc` cannot host that endpoint
picker, no matter how good its general Gateway API conformance is: ADR
0003 notes Traefik has full conformance and still does not qualify, because
no evidence of `ext_proc` support was found for it. So the question is not
"which gateway is best" in general, it is "which gateway can run this one
filter". That is what makes Istio (Envoy underneath) and Envoy Gateway
(Envoy directly) the only two real candidates. ADR 0003 picks Istio in
ambient mode over Envoy Gateway for the reasons recorded there, chiefly
that Kuadrant, the policy layer chosen in ADR 0004, needed to survive a
gateway change, and Istio adds east-west mTLS as a mesh that a plain
gateway does not.

## Notes to fill in

- **What breaks if this layer is removed.** There would be no single entry
  point for `llm.localtest.me`, no place to terminate the Gateway API
  routes both the API and Keycloak share, and no data plane capable of
  hosting the `ext_proc`-based endpoint picker phase 3 depends on for
  cache-aware routing.
- **What it costs to run.**

  > **Unmeasured (2026-08-19):** the resident memory of `istiod` and
  > `ztunnel` on this machine, run `kubectl -n istio-system top pod
  > --no-headers` (or `kubectl -n istio-system get pods` if metrics-server
  > is not installed) once a cluster exists.

  This is the number that would test the ztunnel-versus-sidecar footprint
  figures ADR 0003 quotes from vendor blogs (roughly 0.06 vCPU and 12 MB per
  node for ztunnel, against roughly 0.20 vCPU and 60 MB per pod for a
  sidecar, both explicitly marked not verified there). Nothing here should
  be read as having confirmed or refuted those figures. That needs the
  command above, run against a live cluster.
- **The one thing that surprised me while building it.**

  > **Unmeasured (2026-08-19):** this is an observation from operating the
  > running layer, not from writing its manifests, write it once the
  > installer in `platform/10-istio/install.sh` has actually been run
  > against a cluster.
