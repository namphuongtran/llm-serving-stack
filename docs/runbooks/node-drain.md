# Runbook: draining a node under ornith-9b

What to check before, during, and after taking a node out of service, and how
to read the result. Written 2026-08-19 against the manifests in
`models/ornith-9b/overlays/local/` (patch-resources.yaml, pdb.yaml,
fallback.yaml, retry-policy.yaml, httproute.yaml). No cluster ran while this
was written; see the `Unmeasured` markers below for what to check against a
real one.

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
So the served-by engine is the response's own `model` field:

```bash
curl -s "$BASE/v1/chat/completions" -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"model":"ornith-9b","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' \
  | jq -r .model
# "ornith-9b"    -> answered by the primary
# "fallback-small" -> answered by the failover route
```

For a streamed response, check the `model` field of any chunk rather than
the request body, for the same reason.

## Proving the failover route works

```bash
kubectl --context "$KUBECTL_CONTEXT" -n llm scale deploy/ornith-9b-predictor --replicas=0
TOKEN=$(source tests/lib/helpers.bash && get_token llm-tier-pro)
curl -s -o /dev/null -w '%{http_code}\n' http://llm.localtest.me/v1/models -H "authorization: Bearer $TOKEN"
kubectl --context "$KUBECTL_CONTEXT" -n llm scale deploy/ornith-9b-predictor --replicas=2
```

> **Unmeasured (2026-08-19):** whether the endpoint keeps answering with the
> primary at zero replicas, run the commands above (and
> `tests/smoke/08-availability.bats`, test "the endpoint still answers when
> the primary has no replicas") once a cluster exists.

This is not a formality. `models/ornith-9b/overlays/local/retry-policy.yaml`
carries a specific, recorded doubt about its own mechanism: Envoy selects
among the HTTPRoute's weighted backends (`ornith-9b-predictor:100`,
`fallback-small-predictor:0`) by fixed probability on the initial attempt
and on every retry alike, so a permanently zero-weight backend may never be
chosen regardless of the primary's health. That file documents the doubt in
full; nothing in this repository has run a cluster to confirm or refute it.
If the drill above returns `503`, that doubt was correct, and the failover
line in the design spec is aspirational until the routing is rebuilt on a
mechanism that changes cluster selection on primary health (an Envoy
aggregate cluster via `EnvoyFilter`, for example) rather than a retry count.
