# Runbook: draining a node under ornith-9b

What to check before, during, and after taking a node out of service, and how
to read the result. Written 2026-08-19 against the manifests in
`models/ornith-9b/overlays/local/` (patch-resources.yaml, pdb.yaml,
fallback.yaml, httproute.yaml). No cluster ran while this was written; see
the `Unmeasured` marker below for what to check against a real one.

Cross-backend failover (routing to `fallback-small` when the primary is
down) is withdrawn, not deferred: see ADR 0007
(`docs/adr/0007-failover-not-expressible-in-gateway-api.md`). The sections
below that used to describe proving it now describe why it does not exist
in phase 1 instead.

## Before you drain

Confirm the budget can currently absorb one eviction:

```bash
kubectl --context "$KUBECTL_CONTEXT" -n llm get pdb ornith-9b \
  -o jsonpath='{.status.currentHealthy} healthy, {.status.disruptionsAllowed} disruptions allowed{"\n"}'
```

- `disruptionsAllowed: 0` means eviction of any ornith-9b-predictor pod is
  currently blocked. Do not force it. Check first:
  - Are both replicas `Ready`? `kubectl -n llm get pods -l serving.kserve.io/inferenceservice=ornith-9b`
  - Did a previous drain leave a pod `Pending` (no node with room)? `kubectl -n llm get pods -o wide`
  - Is `ScaledObject.spec.minReplicaCount` still `2`
    (`models/ornith-9b/overlays/local/scaledobject.yaml`)? If a change dropped
    it below the PDB's `minAvailable: 1`, KEDA can scale to a replica count
    the budget cannot protect, and the budget itself will never show
    `disruptionsAllowed` above 0 with only one replica running.
- `currentHealthy` should be 2 (one per replica). If it is 1, the second
  replica is not yet `Ready`; wait rather than drain.

## Draining

```bash
node=$(kubectl --context "$KUBECTL_CONTEXT" -n llm get pods \
  -l serving.kserve.io/inferenceservice=ornith-9b \
  -o jsonpath='{.items[0].spec.nodeName}')
kubectl --context "$KUBECTL_CONTEXT" drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
```

A healthy drain looks like:

1. `kubectl drain` cordons the node, then evicts pods one at a time, honouring
   the PodDisruptionBudget: it will not evict the second ornith-9b-predictor
   pod on a different node's schedule until the first has rescheduled and
   become `Ready` elsewhere, because the budget only ever allows one
   unavailable replica at a time.
2. The evicted pod's `preStop` hook (`patch-resources.yaml`) sleeps 15
   seconds before the container actually stops, giving the gateway time to
   stop sending it new requests; `terminationGracePeriodSeconds: 120` gives
   any in-flight streamed response up to that long to finish before the
   kubelet sends `SIGKILL`.
3. Throughout, `curl "$BASE/v1/models" -H "authorization: Bearer $TOKEN"`
   keeps returning `200`, because the topology spread constraint
   (`topologyKey: kubernetes.io/hostname`) put the two replicas on different
   nodes in the first place, so draining one never removes the last replica.
4. `kubectl uncordon "$node"` afterward lets the drained node take pods again.

## If `disruptionsAllowed` stays 0 during the drain

Something else already has one replica down (crash loop, OOM, a previous
drain not yet uncordoned). Find it before draining a second node:

```bash
kubectl --context "$KUBECTL_CONTEXT" -n llm get pods -l serving.kserve.io/inferenceservice=ornith-9b -o wide
kubectl --context "$KUBECTL_CONTEXT" -n llm describe pod <the not-Ready one>
```

## Memory ceiling with two replicas resident

> **Unmeasured (2026-08-19):** memory footprint of two ornith-9b-predictor
> replicas resident together on this machine (Apple M4, 32 GB), run
> `kubectl --context "$KUBECTL_CONTEXT" -n llm top pod -l serving.kserve.io/inferenceservice=ornith-9b`
> once a cluster exists.

The `llamacpp-arm64` ServingRuntime requests 8Gi and limits 12Gi per replica
(`runtimes/llamacpp-arm64/servingruntime.yaml`); two replicas therefore
request 16Gi and can burst to 24Gi combined, before counting the
`fallback-small` predictor's own 1Gi request / 2Gi limit. Check
`kubectl -n llm top pod` before treating a scheduling failure or an OOMKill
as a logic bug rather than a resource ceiling on this 32 GB machine.

## Telling primary from fallback in a response

llama.cpp's server sets the OpenAI-compatible response's `model` field from
its own `--alias` flag, not from the client's requested model name. From the
server's own documentation: "By default, model `id` field is the path to
model file, specified via `-m`. You can set a custom value for model `id`
field via `--alias` argument." (`tools/server/README.md`, `ggml-org/llama.cpp`,
read 2026-08-19.)

`ornith-9b`'s `InferenceService` sets `--alias ornith-9b`
(`models/ornith-9b/base/inferenceservice.yaml`); `fallback-small`'s sets
`--alias fallback-small` (`models/ornith-9b/overlays/local/fallback.yaml`).
This still matters for calling `fallback-small` directly (see below); it no
longer matters for telling which one answered a request through the gateway,
because the gateway never routes to `fallback-small` (next section).

## Why there is no failover route to prove

ADR 0007 (`docs/adr/0007-failover-not-expressible-in-gateway-api.md`)
withdrew the mechanism this runbook used to describe here: a `weight: 0`
`backendRef` on the model's `HTTPRoute` (named `ornith-9b` then, renamed
`ornith-9b-openai` on 2026-08-19), reached through Envoy retries.
It cannot work. Envoy selects among an `HTTPRoute`'s weighted backends once,
at initial route match; a retry is attempted against a different host
**inside the already-selected cluster**, never against a different backend
(Envoy issue 5891, closed without the behaviour changing). A permanently
zero-weight backend therefore has zero probability of ever being selected,
on the first attempt or any retry. A second, independent defect existed in
the same attempt: the retry policy attached via `spec.gateways:
[istio-system/llm]`, which Istio resolves against its own
`networking.istio.io` `Gateway` kind, not the Gateway API
`gateway.networking.k8s.io` `Gateway` this repository actually has under
that name, so it most likely never attached to anything either.

`models/ornith-9b/overlays/local/retry-policy.yaml` has been deleted, and
the `HTTPRoute` carries only the primary backend - it has no rule that
matches on the request's `model` field, so posting `"model":"fallback-small"`
to `$BASE` still lands on `ornith-9b-predictor`, whatever `llama.cpp` then
does with an alias it does not recognise. `fallback-small` is still deployed
(`models/ornith-9b/overlays/local/fallback.yaml`) and independently useful,
and Task 13's CI overlay reuses its model pin, but reaching it now takes a
port-forward straight to its own Service, not a request through the gateway:

```bash
kubectl --context "$KUBECTL_CONTEXT" -n llm port-forward svc/fallback-small-predictor 8081:80 &
curl -s http://127.0.0.1:8081/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"fallback-small","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' \
  | jq -r .model
kill %1
```

Genuine cross-backend failover needs an Envoy-native construct outside
Gateway API (an aggregate cluster via `EnvoyFilter`); building one is not in
phase 1's scope. `tests/smoke/08-availability.bats`'s "the endpoint still
answers when the primary has no replicas" test is marked `skip`ped with ADR
0007 as its reason, not deleted and not left failing: there is nothing left
to measure here, because the capability itself was withdrawn rather than
merely unmeasured.
