# Deployment walkthrough

How to bring this stack up one layer at a time, what each layer costs, and what
running it found.

This document exists because the repository had two install paths and neither
answered the first question a person with a laptop asks: how far can I get
before Docker runs out. Every number here was measured, not estimated, and
carries the date it was measured.

## Answer first

On 2026-08-19, on an Apple M4 with 32 GiB of RAM and Docker Desktop given
10 CPUs and 23.2 GiB, **all thirteen layers came up and the service answered a
real request**: 401 without a token, 200 with a JWT from Keycloak, and a streaming
chat completion. See [Where it got to](#where-it-got-to).

The platform layers, from an empty machine to Argo CD running, took **9 minutes
59 seconds** and settled at **7.0 GiB, 29% of what Docker was given**. With both
models loaded it reached **17855 MiB, 75%**. Memory was never the limit, but the
model layer is most of it.

Both of those numbers were wrong when this document was first written, and the
corrections are recorded rather than quietly applied. It said 9m33s, which is 573
seconds; the `seconds` column in `docs/deployment-log.tsv` sums to 599 for those
layers, and no subset of that column sums to 573 at all. It said 17811 MiB, which
appears in no row of the log. Both errors came from transcribing what the terminal
printed instead of re-deriving from the tracked log, which is the one thing this
repository's evidence rule exists to prevent.

Getting the model layer up took three fixes, each only visible after the previous
one landed. All three are now in the repository, the last one as
`platform/10-istio/coredns-rewrite.yaml`. That file replaces kind's whole CoreDNS
Corefile, which is only safe while the node image stays digest-pinned, so read
[the gap that closed](#the-gap-that-was-open-and-how-it-closed) before bumping
`kubernetes.kind_node`.

## Run it

```bash
task preflight                 # tools, Docker CPU and memory, helm repo aliases
./tools/step-up.sh list        # the thirteen steps, and which are done
./tools/step-up.sh next        # run the next one, then measure
./tools/step-up.sh all         # keep going until a step fails or the guard stops
./tools/step-up.sh measure     # measure without installing anything
```

Every run appends a row to `docs/deployment-log.tsv`. Read it with
`column -t -s $'\t' docs/deployment-log.tsv`.

The guard stops the run for one of two reasons, and says which:

- **A pod cannot be scheduled** for `Insufficient memory` or `Insufficient cpu`.
  This is a wall, not slowness.
- **The kind node containers exceed `STOP_PCT`** of Docker's memory, default 85.
  Override deliberately with `STOP_PCT=95`.

Memory is read with `docker stats` on the node containers, not `kubectl top`.
kind installs no metrics-server, so `kubectl top` returns "Metrics API not
available" on a fresh cluster.

### Before you start

`task preflight` requires 8 CPUs and 20 GiB. It reads Docker's allocation, not
the host's. It divides by 1073741824 and compares with `-ge 19`, so 19.0 GiB
passes and 18.9 does not.

If it fails on memory, raise **Docker Desktop → Settings → Resources** and
restart Docker. On the machine this was written on the default was 7.7 GiB out of
32 GiB installed, which fails, and raising it to 23.2 GiB was the only change
needed.

## What each layer costs

Measured 2026-08-19 on a 3-node kind cluster (1 control-plane, 2 workers), node
image `kindest/node:v1.36.1`, with kind v0.32.0. `mem` is the sum of resident
memory across the three node containers, so it includes the cluster itself.

| # | Step | Seconds | Pods after | mem | % of 23.2 GiB |
|---|---|---:|---:|---:|---:|
| 1 | `cluster` | 14 | 13 | 814 MiB | 4 |
| 2 | `gateway-api-crds` | 2 | 13 | 1230 MiB | 5 |
| 3 | `cert-manager` | 41 | 16 | 1546 MiB | 6 |
| 4 | `istio` | 46 | 24 | 1992 MiB | 8 |
| 5 | `kyverno` | 63 | 28 | 2816 MiB | 11 |
| 6 | `keycloak` | 58 | 29 | 3378 MiB | 14 |
| 7 | `kserve` | 47 | 30 | 3835 MiB | 16 |
| 8 | `kuadrant` | 111 | 37 | 4389 MiB | 18 |
| 9 | `observability` | 126 | 46 | 5737 MiB | 24 |
| 10 | `keda` | 47 | 50 | 6214 MiB | 26 |
| 11 | `argocd` | 44 | 59 | 7043 MiB | 29 |
| 12 | `model` | see below | 57 | 7089 MiB | 29 |
| 13 | `security` | 0 | 60 | 17855 MiB | 75 |

Two layers dominate: `kuadrant` and `observability` are 237 of the 599 seconds.
Among the platform layers `observability` is also the largest single jump in
memory, 1348 MiB, which is expected: it brings Prometheus, Grafana, Alertmanager, node-exporter,
kube-state-metrics, the OTel Collector, Pushgateway, and Tempo.

The model layer is the expensive one, and the prediction written here before it
ran was wrong in the right direction. It said to expect 16 GiB of requests on top
of 7.0 GiB, against 23.2 GiB available. Measured: the whole cluster reached
17855 MiB, 75%, with both models resident. Requests are not resident memory, which
is why the estimate overshot.

Read row 12 carefully. Its 7089 MiB is the log's own `model` row, written two
seconds after `kubectl apply` returned, long before either model had finished
downloading its weights. The 17855 MiB in row 13 is the first sample taken after
both were resident, so it is the honest figure for "the model layer loaded". The
jump between the two rows, about 10.7 GiB, is what the models actually cost and it
is larger than any platform layer's.

Re-measured 2026-08-20 with both models still resident, after a Docker Desktop
restart: 17576 MiB, 74%. That is a second sample, not a correction of the first.

Its `seconds` column is left as "see below" on purpose: the step's own `kubectl
apply` returns in 2 seconds, and the real cost is the weight download and model
load that follow it, which the step does not wait for. Timing that honestly needs
a different measurement than this script takes.

## The step order, and why it is not just the nine install scripts

`./tools/step-up.sh` runs existing scripts and existing manifests. It is not a
third install path. But the order matters and two of the steps are not obvious:

- **`gateway-api-crds` is a real script that nothing on the imperative path
  calls.** `platform/10-istio/gateway-api-crds.sh` exists and is correct, but
  `platform/10-istio/install.sh` does not run it, and neither does `task
  local:up`. Only `.github/workflows/ci.yml` calls it, at lines 175 and 296.
  Running the nine `install.sh` scripts in numeric order therefore installs no
  Gateway API CRDs, and the istio layer then fails with `no matches for kind
  "Gateway"`. That ordering requirement used to live only in CI.
- **`model` and `security` have no imperative script at all.** They exist only
  as Argo CD Applications (`clusters/local-kind/apps/90-model-local.yaml` and
  `90-security.yaml`), so the walkthrough applies the same manifests by hand.

## Defects this walkthrough found

Seven, and most were invisible to every static check, including four separate
review passes over the whole repository. Running is what found them. Three more
are in [It took three fixes, not one](#it-took-three-fixes-not-one).

### `task local:up` failed at its second command on any fresh clone

`platform/50-argocd/install.sh` was mode `100644` in git while the other fifteen
tracked shell scripts were `100755`. `Taskfile.yml:78` invokes it as
`./platform/50-argocd/install.sh`, and that line is the second command of `task
local:up`. A fresh clone got `Permission denied`.

No static check found it because a file mode is not file content. `task lint`
now asserts that every tracked `*.sh` is `100755` **in the index**, not merely in
the working tree: on this repository's volume `chmod +x` alone did not update the
index, and `git update-index --chmod=+x` was needed.

### The KServe install script aborted on macOS bash

`platform/20-kserve/install.sh` expanded `"${extra[@]}"` under `set -u`. bash
3.2.57, which macOS ships as `/bin/bash`, treats an empty array expansion as an
unbound variable:

```
./platform/20-kserve/install.sh: line 31: extra[@]: unbound variable
```

The first chart in the loop, `kserve-crd`, is exactly the empty case, so the
script died before installing anything. `/bin/bash -n` cannot see it, because the
file parses; CI never saw it, because GitHub runners have bash 5. The fix is the
portable `${extra[@]+"${extra[@]}"}` form.

### Two selectors targeted a label Istio removed in 1.24

`platform/10-istio/telemetry.yaml` and
`platform/30-observability/podmonitor.yaml` both selected
`istio.io/gateway-name`. On the live cluster:

```
kubectl -n istio-system get pod -l istio.io/gateway-name=llm -o name                   -> 0 pods
kubectl -n istio-system get pod -l gateway.networking.k8s.io/gateway-name=llm -o name   -> 1 pod
```

So the gateway was never told to emit spans, and the gateway PodMonitor found no
target. After correcting both keys, Prometheus reports the target as
`health=up`, scraping `http://10.244.2.6:15020/stats/prometheus`.

The same run settled the other half of that file's `Untried` marker: the pod does
declare port 15020, named `metrics`.

### Tests that pass while the system is broken

Two were confirmed by mutation, not by argument.

`tests/smoke/11-policy.bats` asserted only `[ "$status" -ne 0 ]`, which any
failure satisfies. Pointed at a context that does not exist, the old form passes
and the new form fails with the real cause:

```
ok 1 OLD form: status -ne 0 only
not ok 2 NEW form: also asserts Kyverno rejected it
  # not rejected by Kyverno: error: context "does-not-exist" does not exist
```

`tests/smoke/05-observability.bats` asserted `up{namespace=...}` returned at
least one series. `up` is 0 for a target Prometheus discovered but could not
scrape, and 0 is still a series. On this cluster `up == 0` returned **6** series
at that moment, the control-plane components kube-prometheus-stack scrapes and
kind does not expose. Both assertions now use `== 1`.

A third: `fail` was used in tests but defined nowhere. It comes from
`bats-assert`, which this repository does not vendor and which is not installed,
so `fail "..."` would have died with "command not found" — failing the test for
the wrong reason. It is now defined in `tests/lib/helpers.bash`.

## Where it got to

**All thirteen steps completed, and the service answers.** Observed 2026-08-19
15:26 UTC:

| Check | Result |
|---|---|
| `GET /v1/models`, no token | HTTP 401, rejected by the AuthPolicy |
| `GET /v1/models`, valid JWT from Keycloak | HTTP 200, serving `ornith-9b` |
| Streaming chat completion | 43 SSE `data:` chunks |
| `AuthPolicy` / `TokenRateLimitPolicy` | both `Enforced=True` |
| Both `InferenceService` objects | `Ready=True` |

llama.cpp logged `model loaded` and `listening on http://0.0.0.0:8080`, loading
from `/models/model.gguf`. Memory settled at **17855 MiB, 75%** of the 23.2 GiB
Docker was given, with both models resident. The guard threshold is 85%, so it
fits but not with much room.

Two measurements worth keeping:

- **Each replica downloads the weights independently.** `minReplicas: 2` meant
  two 5.6 GB downloads into two separate emptyDir volumes, 11.2 GB in total. Both
  finished at exactly 5629108704 bytes, matching the `x-linked-size` header
  recorded in `models/ornith-9b/base/model.yaml`.
- **The per-slot context is 2048, not 4096.** llama.cpp logged
  `n_slots = 2, n_ctx_slot = 2048`, confirming that `--ctx-size 4096 --parallel 2`
  divides the context. Two bench scenarios ask for more prompt tokens than a slot
  holds.

### It took three fixes, not one

Option 1 was chosen, and each fix only became visible after the previous one
landed. The full record with upstream citations is in
`models/ornith-9b/overlays/local/patch-resources.yaml`.

1. **Move our volume off `/mnt/models`.** KServe infers multi-model serving for
   any InferenceService with no `storageUri`, injects its model agent, and the
   agent appends a `/mnt/models` mount with no duplicate check. Our volume is now
   at `/models`.
2. **Pin the injected agent's image.** With the mount fixed, the pod was rejected
   by this repository's own `disallow-floating-tags` policy: the chart renders the
   agent image with an empty tag, giving the floating `kserve/agent:v0.20.0`. The
   policy did exactly its job. Now pinned by digest in both copies of the KServe
   values.
3. **Make the issuer resolvable from inside the cluster.** Every authenticated
   request returned 401 with a valid token. Authorino's log named the cause:
   `dial tcp [::1]:80: connect: connection refused` fetching
   `http://llm.localtest.me/realms/llm/.well-known/openid-configuration`.
   `llm.localtest.me` resolves to 127.0.0.1, so inside a pod it means the pod.

### The gap that was open, and how it closed

Fix 3 was applied by hand at first and had no home in git. It now does:
`platform/10-istio/coredns-rewrite.yaml`.

```
rewrite name llm.localtest.me llm-istio.istio-system.svc.cluster.local
```

It is a plain ConfigMap manifest, not a Job, so it works identically on the
imperative path and under Argo CD with no ServiceAccount, no RBAC, and no extra
pinned image. `platform/10-istio/install.sh` applies it last, after the Gateway
exists, and the Argo CD Application already sources that directory, so no inline
copy is needed and there is nothing to keep in sync.

**The cost is real and stated in the file's header.** CoreDNS has no `import`
directive in kind's Corefile and `rewrite` must sit inside the `.:53` block, so
there is no way to add one line without owning the whole file. The manifest
therefore replaces the Corefile that `kindest/node` ships, and everything in it
except the rewrite is kind's default copied verbatim. That is only safe because
`versions.yaml` pins the node image by digest. **Bumping `kubernetes.kind_node`
means re-reading that Corefile.**

Proved by mutation rather than by argument, on 2026-08-19:

| Step | Result |
|---|---|
| Restore kind's original Corefile | `/v1/models` with a valid JWT → HTTP 401 |
| Apply the repo manifest, nothing else | HTTP 200 after about 80 seconds, no restart |

The 80 seconds is CoreDNS's `reload` interval plus Authorino's own retry. It is
why `install.sh` waits for the name to resolve from a throwaway pod rather than
running `kubectl rollout status deploy/coredns`: nothing restarts, so a rollout
check returns immediately and proves nothing. That wrong check was in the script
for one revision.

> **Untried (2026-08-19):** that Argo CD applies this file cleanly. The
> walkthrough used the imperative path throughout, so `root-app.yaml` was never
> applied and no Argo CD Application ever synced. The manifest is a plain
> ConfigMap in a directory the Application already sources, and its explicit
> `namespace: kube-system` should win over the Application's `istio-system`
> destination, but neither claim has been observed. Settle it with
> `task local:up` on a fresh cluster.

### Two more test defects, found by the same run

`tests/smoke/03-identity.bats` had four tests and all four asked from the HOST.
Authorino asks from a POD, so none of them could see the failure above. Two
pod-side tests were added, and writing them surfaced two problems.

The first is in the suite as it stood: test 1 queried `/realms/llm` and read
`.issuer` from it. That endpoint returns Keycloak's realm info document, whose
keys are `account-service`, `public_key`, `realm`, `token-service`, and
`tokens-not-before`. There is no `issuer` field, so `jq -r .issuer` printed `null`
and the equality check could never pass. It now queries the discovery document,
which is both where `issuer` lives and what Authorino actually fetches.

The second I wrote myself. The new DNS test first asserted only that
`getent hosts llm.localtest.me` exited 0 from a pod. The mutation run showed that
passes with the rewrite removed: the name still resolves, via the upstream
forwarder, to 127.0.0.1. It was satisfied by the wrong answer. It now asserts the
resolved address equals the gateway Service's ClusterIP. With that change, both
new tests fail when the rewrite is absent and pass when it is present.

### One contract test fails, for a understood reason

`tests/contract/01-openai-api.bats` runs 5 tests against the live cluster: 4 pass,
1 fails.

```
not ok 2 POST /v1/chat/completions returns a non-empty message
```

The pinned model is a reasoning model. It returns `reasoning_content` and leaves
`content` empty until it has finished thinking. Measured at several limits, all
with `finish_reason: length` and `content` length 0:

| `max_tokens` | `content` | `reasoning_content` |
|---:|---:|---:|
| 24 | 0 | 86 |
| 64 | 0 | 219 |
| 128 | 0 | 454 |
| 256 | 0 | 952 |
| 512 | 0 | 1825 |

The test asks for 24. So the assertion is not wrong about the OpenAI contract; it
is wrong about this model. That has consequences beyond the test: every
`bench/scenarios/*.json` caps output at 64 or 128 tokens, so the benchmark would
measure reasoning throughput and report an empty answer as a success.

> **Unmeasured (2026-08-19):** the `max_tokens` at which this model does emit
> `content`. 512 was not enough and the per-slot context is 2048. Settle it by
> raising the limit until `content` is non-empty, then decide whether the test
> should raise its own limit or assert on `reasoning_content` too.

## Safety notes

- **Check your context before running anything.** Every `platform/*/install.sh`
  uses bare `kubectl`, so each targets whatever context is current.
  `tools/step-up.sh` asserts the context once, up front, rather than letting nine
  scripts each assume it.
- **`bench/recovery-drill.sh` deletes namespace `llm`.** Until 2026-08-19 it did
  so with bare `kubectl`, because the helpers were sourced inside a command
  substitution rather than at top level. On the machine where this was found the
  current context was `docker-desktop`. It now routes through `k()`, refuses to
  run when the context is unreachable, and its readiness gate is bounded rather
  than an unbounded `until` loop.
- `tests/smoke/12-recovery.bats` runs that drill, so `bats tests/smoke` triggers
  the delete.

## Tearing down

```bash
task local:down     # deletes the kind cluster
```

`docs/deployment-log.tsv` survives, which is the point: the numbers stay after
the cluster is gone. Delete the log to start the walkthrough from scratch, since
`step-up.sh` reads it to decide what is already done.
