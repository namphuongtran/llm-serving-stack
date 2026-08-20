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

**SETTLED 2026-08-20**, by `task local:up` on a cluster created from empty.
Both claims the old marker made were guesses, and both hold.

| Claim | Observed |
|---|---|
| Argo CD applies the file | `ConfigMap/kube-system/coredns` is `Synced`, tracked as `istio-gateway:/ConfigMap:kube-system/coredns` |
| The manifest's `namespace: kube-system` beats the Application's `istio-system` destination | It did. The object is in `kube-system` |
| `Prune=false` survives the round trip | The live object carries `argocd.argoproj.io/sync-options: Prune=false` |

The functional check, not only the status field. `llm-istio` had ClusterIP
`10.96.82.77`, and from a throwaway pod in `kube-system`:

```
getent hosts llm.localtest.me
10.96.82.77       llm.localtest.me  llm.localtest.me
```

So the rewrite reached the cluster through the pull path and works there. Note
that the rest of that run failed, for six unrelated reasons recorded below in
"The pull-based path". This one file was not among them.

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

## The pull-based path, first run 2026-08-20

Everything above used the imperative path, `platform/NN-*/install.sh`. This
section is the other path, `task local:up`, run for the first time on
2026-08-20 against a cluster deleted and recreated from empty.

It did not come up, twice. Run 1 found seven defects and run 2 found six more,
and none of the thirteen could be seen from the imperative path.

A note on the dates in this section, because this repository requires a
measurement to carry the date it was taken. Every clock time here is UTC and
carries a `Z`. The first run began at `2026-08-19T23:23:27Z` and the work
continued past midnight UTC. The date label "2026-08-20" is the local date on
the build machine, which is UTC+7, so `23:23:27Z` was 06:23 local on
2026-08-20. Where an earlier section says 2026-08-19, local and UTC agreed on
that day; here they do not.

The run: started `2026-08-19T23:23:27Z`, exited **201** at
`2026-08-19T23:56:05Z`, 32 minutes and 38 seconds. Three Applications met the Synced condition (`root-app`,
`cert-manager`, `gateway-api-crds`) and fourteen timed out.

That exit code is itself the check on the fix. On the same cluster the old
one-line wait exited **0 in one second**; the replacement took the full 30
minute timeout and then failed. Both were reading the same broken cluster.

Memory was never the constraint. The run peaked at **7502 MiB of 23744 MiB, 30
per cent**, with 57 pods, at 23:38:58Z, over 93 samples taken every 20 seconds. The imperative run peaked at 17855 MiB,
but by then the model weights were loaded. Here the model was never deployed at
all, for the reason in defect 5.

### 1. Every Application pointed at a different program

Eight lines read `targetRevision: HEAD`, one in each of eight files. Argo CD
resolves `HEAD` to the remote default branch, and that branch held an unrelated
C# project. On 2026-08-20 `git ls-tree --name-only origin/main` printed

```
OrderShare.sln
OrderShare
README.md
packages
```

So `root-app` reported

```
type: ComparisonError
message: Failed to load target state: ... rpc error: code = Unknown desc =
         clusters/local-kind/apps: app path does not exist
```

and created none of its 15 children.

The files now read `targetRevision: main`, and this branch was fast-forwarded
into `main` the same day so that the value is true. `main` was already an
ancestor of the branch, so no merge commit was needed.

Counted rather than recalled, with

```
git show 64e07fd:clusters/local-kind/root-app.yaml | grep -c 'targetRevision: HEAD'
for f in $(git ls-tree --name-only 64e07fd clusters/local-kind/apps/); do
  git show "64e07fd:$f" | grep -c 'targetRevision: HEAD'
done
```

which names root-app plus seven children: `10-istio-gateway`, `12-kyverno`,
`15-keycloak`, `25-kuadrant`, `30-observability`, `90-model-local`, and
`90-security`. Commit `07ad4f9` says "six child Applications" in its message.
That is wrong, and it contradicts the "Eight lines" in its own first sentence.
The number is seven. The message is left as it stands and corrected here,
because the rule in this repository is to record a finding rather than edit the
record until it agrees with itself.

Nothing without a cluster could have caught this. The field was well formed and
pointed somewhere real. It pointed at a different program.

### 2. And then it reported success

The last command of `task local:up` was

```
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  applications.argoproj.io --all --timeout=30m
```

Against the cluster above, with zero child Applications and nothing deployed,
it exited **0 in one second**.

An Argo CD Application that never managed to compare anything reports
`health.status: Healthy`. It has no resource to call unhealthy, so it calls
itself healthy. `sync.status` is the field that tells the truth. Both probed
against the same object at the same moment:

| `--for=jsonpath=` | Result |
|---|---|
| `{.status.sync.status}=Synced` | `error: timed out waiting for the condition on applications/root-app` |
| `{.status.health.status}=Healthy` | `application.argoproj.io/root-app condition met`, exit 0 |

So acceptance criterion 1 was worse than unproven. The command written to
settle it could not fail, in either direction, on an empty cluster.

`clusters/local-kind/wait-for-sync.sh` replaces that line with four
assertions: root-app is `Synced`; the number of Applications equals the number
of `kind: Application` documents in `clusters/local-kind/apps/` plus one; every
Application reaches `Synced` then `Healthy`; and three consecutive samples find
every Application `Synced/Healthy` **at the same moment**.

The last of those is not decoration. `kubectl wait --all` checks each object in
turn and never rechecks one that already passed, so it can succeed on objects
that were green at different times, and these Applications do flap OutOfSync
while their neighbours sync. `--all` does fail on an empty set, probed the same
day: zero matching objects gives `error: no matching resources found`, exit 1.
It does not fail on a partial set, which is why the count is checked separately.

### 3. Sync waves gave twelve seconds of ordering

The waves ordered the children correctly. They ordered them two to three
seconds apart. Creation timestamps from the run:

| Wave | Created |
|---|---|
| 0 | 23:25:42Z |
| 1 | 23:25:45Z |
| 2 | 23:25:47Z |
| 3 | 23:25:49Z |
| 4 | 23:25:52Z |
| 5 | 23:25:54Z |

Six waves in twelve seconds, for a stack whose layers need minutes.

The gate between waves is the child Application's own health, and a freshly
created Application reports `Healthy` at once, for the reason in defect 2. So
defect 2 is not one bug in one command. The same property also removed the
ordering that this repository's whole delivery design rests on.

### 4. A failed sync is never retried

`model-local` failed at 23:31:05Z with

```
failed to discover server resources for group version serving.kserve.io/v1beta1:
the server could not find the requested resource (retried 5 times)
```

Six minutes later it had still not tried again, and by then the CRDs it wanted
existed: 5 KServe CRDs and 17 Kuadrant CRDs were present. `security-oidc`
failed the same way on `AuthPolicy.kuadrant.io "" not found`.

`selfHeal: true` does not cover this. Self-heal corrects drift. It does not
re-run an operation that failed. No Application declared
`syncPolicy.retry`, so Argo CD made five attempts inside one operation and
stopped. All sixteen now declare a backoff.

### 5. The 262144-byte annotation cap, which stopped five layers

This is the defect that decided the run. It hit **five of the fifteen
Applications**, not the two first recorded here. Counted by reading
`.status.operationState.message` on all fifteen and matching the string:

| Application | CRDs over the cap |
|---|---|
| `kserve` | `inferenceservices.serving.kserve.io` |
| `kyverno` | `clusterpolicies.kyverno.io`, `policies.kyverno.io` |
| `kuadrant` | `authpolicies.kuadrant.io` |
| `observability` | `alertmanagers`, `alertmanagerconfigs`, `prometheusagents`, `prometheuses`, `scrapeconfigs`, `thanosrulers`, all `.monitoring.coreos.com` |
| `keda` | `scaledjobs.keda.sh` |

A sample message, verbatim:

```
CustomResourceDefinition "inferenceservices.serving.kserve.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes (retried 5 times)
```

Argo CD applies client-side by default, which writes the entire manifest into
the object's `kubectl.kubernetes.io/last-applied-configuration` annotation.
Kubernetes caps annotations at 262144 bytes. The largest CRDs here exceed it.

Both failures cascaded:

- With `inferenceservices.serving.kserve.io` absent, `serving.kserve.io/v1beta1`
  was not discoverable, so `90-model-local` synced none of its six resources.
  **The stack had no InferenceService at all**, which is why no model was ever
  loaded and why the memory figure above is so much lower than the imperative
  run's.
- With `clusterpolicies.kyverno.io` absent, all three ClusterPolicies failed
  with `no matches for kind "ClusterPolicy" in version "kyverno.io/v1"`.
  **This repository's own admission policies were never installed by the pull
  path.** The guard that rejected KServe's floating-tag agent image on the
  imperative run was simply not there.
- With the Prometheus operator CRDs absent, the `Prometheus` object failed with
  `no matches for kind "Prometheus" in version "monitoring.coreos.com/v1"`.
  **There was no Prometheus**, so nothing in the observability layer could have
  worked.
- With `authpolicies.kuadrant.io` absent, `security-oidc` failed on
  `AuthPolicy.kuadrant.io "" not found`. This correction matters: that failure
  was first recorded here as pure wave ordering, curable by the backoff in
  defect 4. It was not. The CRD never applied, and no amount of retrying would
  have produced it.

`helm install` does not write that annotation, so `platform/20-kserve/install.sh`
and `platform/12-kyverno/install.sh` install the same charts with no complaint.
This is the clearest case yet of the two-path divergence that `CLAUDE.md`
warns about: one defect, visible from one path only.

The fix is `ServerSideApply=true`, and it was already in this repository.
`clusters/local-kind/apps/00-gateway-api-crds.yaml` carried that option before
today. It was applied to one Application out of the six that turned out to need
it. The option is now set on all sixteen, rather than on the five known
victims: any chart can grow past the cap between one version pin and the next,
and there is no reason for this stack to prefer client-side apply anywhere.

### 6. istio-base synced successfully and stayed OutOfSync

Its sync operation reported `successfully synced (all tasks run)`, and the
Application still reported OutOfSync on one resource,
`ValidatingWebhookConfiguration/istiod-default-validator`.

The drift is by design, and the chart says so. Rendered from `istio/base`
1.30.3 on 2026-08-20, the validator carries a comment saying istiod will update
`failurePolicy` to `Fail` and patch in the `caBundle`, followed by
`failurePolicy: Ignore` and no `caBundle` key. Read from the live object the
same day: `failurePolicy: Fail`, and a populated `caBundle`.

So git can never match the cluster here. Without an `ignoreDifferences` block
the Application stays OutOfSync for the life of the cluster, and
`wait-for-sync.sh` waits on every Application reaching Synced, so this one
resource would hold `task local:up` until its timeout.

### 7. A default value, declared, made an Application permanently OutOfSync

`root-app` synced successfully and reported one resource OutOfSync forever:
`Application/istio-gateway`.

`clusters/local-kind/apps/10-istio-gateway.yaml` declared

```yaml
    directory:
      recurse: false
```

and the live object's `spec.source.directory` came back empty. Argo CD drops
`recurse: false`, because false is the default. So git carried a field the
cluster would never report, and the comparison could not converge.

The declaration is removed. The behaviour is unchanged, because false is what
Argo CD does anyway; only the false drift is gone. `25-kuadrant.yaml` declares
`recurse` too and does not drift, because it uses a multi-source `sources:`
list rather than a single `source:`. That difference is not understood, and it
is recorded here rather than explained.

### Run 2, and the six defects that only a working sync can show

Run 2 started `2026-08-19T23:58:35Z` and exited **201** at `2026-08-20T01:01:35Z`.
The seven fixes above worked, and getting past them exposed a second layer.

What run 2 settled, all of it new:

| Fact | Run 1 | Run 2 |
|---|---|---|
| Applications hitting the annotation cap | 5 | **0** |
| Applications Synced | 3 of 16 | **13 of 16** |
| `InferenceService` objects | none created | **both `READY=True`** |
| This repository's three ClusterPolicies | never installed | **installed, `Ready=True`, `admission=true`** |
| `Prometheus` object | never created | pod `prometheus-kube-prometheus-stack-prometheus-0` exists |

And the service answered, through the pull-delivered stack, at `00:12Z`:

```
GET /v1/models, no token                 -> HTTP 401
GET /v1/models, JWT from Keycloak        -> HTTP 200, serving ornith-9b
POST /v1/chat/completions, stream: true  -> 67 data chunks, terminates with [DONE]
```

`content` was empty and all 64 tokens went to `reasoning_content`, which is the
reasoning-model behaviour already recorded above, not a delivery failure.

So the substance of acceptance criterion 1 was met. The criterion is not, because
`task local:up` still exited non-zero, on three Applications that could never go
green.

**Defect 8. An HPA that can never be healthy, on a cluster with no metrics.**
`istiod` reported `Synced/Degraded` for the life of the cluster, with no child
resource unhealthy and a hard refresh making no difference. The live HPA said

```
AbleToScale=True    reason=SucceededGetScale
ScalingActive=False  reason=FailedGetResourceMetric
```

and `kubectl get apiservice v1beta1.metrics.k8s.io` returned NotFound. kind ships
no metrics-server, so the one HPA the istiod chart renders can never scale, and
Argo CD reads that as Degraded. `autoscaleEnabled: false` in both copies of the
istiod values removes it. Verified by rendering: `helm template istio/istiod
1.30.3` with this repository's values file renders exactly one
HorizontalPodAutoscaler, named `istiod`, and the line removes it.

**Defect 9. A deprecated alias that the controller rewrites.**
Git said `serving.kserve.io/deploymentMode: RawDeployment`; the live object said
`Standard`. `constants.go` at tag v0.20.0 marks the alias `deprecated: use
Standard` and `ParseDeploymentMode` normalises it, so the two are behaviourally
identical - and `versions.yaml` said exactly that, as the reason for keeping the
alias. What that note missed is that KServe writes the normalised value back, so
git and the cluster could never agree and every InferenceService was OutOfSync
for good. Behaviour is not the only thing a string in git decides.

**Defects 10 and 11. Defaults the API server and the webhook fill in.**
Three HTTPRoutes were OutOfSync because the Gateway API CRD defaults
`parentRefs[].group`, `parentRefs[].kind`, `backendRefs[].group`,
`backendRefs[].kind`, and `backendRefs[].weight`. Both InferenceServices were
OutOfSync because KServe adds a `modelFormat` annotation, a finalizer, and
`name: ""` plus `resources: {}` inside `spec.predictor.model`.

The two are fixed differently on purpose. **A default that can be written is
written**: the HTTPRoute manifests now spell out all five fields, and
`kustomize build` output now matches the live object byte for byte. A finalizer
cannot be written, because putting a controller's finalizer in git has Argo CD
fight the controller for it, so the InferenceService fields go in
`ignoreDifferences`.

**Defects 12 and 13. Why only Kyverno's CRDs drifted.**
Eleven Kyverno CRDs and all three ClusterPolicies were OutOfSync while the
policies were Ready and enforcing. Diffing rendered chart output against the live
objects gave two causes. The chart emits `labels: {}` and `annotations: {}`, and
the API server drops empty maps, then adds `conversion: {strategy: None}` - that
is why the other four CRD-shipping charts do not drift, they emit no empty maps.
The ClusterPolicies pick up five schema defaults: `spec.admission`,
`spec.background`, `spec.emitWarning`, `spec.rules[].skipBackgroundRequests`, and
`spec.rules[].validate.allowExistingViolations`.

The `ignoreDifferences` block for this one was tested on the live cluster before
being committed: patched onto the running Application, `kyverno` went from
`OutOfSync` with 14 drifting resources to `Synced/Healthy` with **0**.

**A fix that did not work, recorded because it looked obvious.**
`ServerSideDiff=true` is the documented Argo CD option for exactly this class,
and Argo CD here is v3.5.1, well past the version that introduced it. Patched
onto the live `model-local` Application with a hard refresh, all three of its
OutOfSync resources stayed OutOfSync. It is not in any manifest in this
repository. Reading the version number would have produced a confident and wrong
commit message.

**Defect 14. `kubectl wait --all` is the wrong instrument, and it is gone.**
The two `--all` waits in `wait-for-sync.sh` reported per object - run 2's log has
7 `condition met` lines and 9 `timed out` lines - gave no progress for the whole
timeout, and then failed all at once. Run 2 also took 63 minutes of wall clock
against a 30 minute timeout, and the log does not say where the extra time went.
That is not understood, and it is recorded rather than explained.

Both waits are replaced by one loop that asserts what the criterion needs: every
Application `Synced` **and** `Healthy` in the same sample, three samples running.
It prints the laggards as they change, so a failed run names its cause. Checked
against the live cluster with a 20 second budget: exit 1, and the message named
`istiod=Synced/Degraded`, `keycloak=OutOfSync/Healthy`,
`model-local=OutOfSync/Healthy`.

## CI, first run 2026-08-20

Pushing this branch never triggered CI: `.github/workflows/ci.yml` runs on
`pull_request` and on `push` to `main`, and `main` held a different project.
Fast-forwarding `main` triggered run `32315429345`, the first CI run this
repository has ever had.

| Job | Result |
|---|---|
| `lint` | success |
| `policy` | success |
| `observability` | failure, on one test out of 24 |
| `smoke` | cancelled by its own `timeout-minutes: 45` |

The infrastructure was not the problem. In the `observability` job, `Create
cluster`, `Install tools`, `Add helm repos`, `Install platform`, `Deploy the CI
model`, and `Install observability` all succeeded on an `ubuntu-24.04-arm`
runner. Both failures are in the test suites.

### The one failing test, and it was not about Tempo

```
not ok 21 tempo answers ready through its service, so the collector has a target
# (in test file tests/smoke/05-observability.bats, line 189)
#   `[[ "$output" == *200* ]]' failed
```

Line 188, `[ "$status" -eq 0 ]`, passed. Only the output check failed.

Reproduced locally the same day: Tempo answers `/ready` with `HTTP=200` and body
`ready`. The test was wrong. It asserted on the output of `kubectl run --rm -i`,
and that output is not reliable - kubectl cannot always attach, in which case it
streams logs instead, and `--rm` can delete the pod before the logs are read:

```
warning: couldn't attach to pod/tempo-ready-body-71683, falling back to
streaming logs: error attaching to container: no running task found
```

`kubectl run` still exits 0. Running the test's exact command locally printed no
`200` at all, only kubectl's session banner and `pod ... deleted`.

`tests/smoke/03-identity.bats` records this same race and was already written to
read only the exit code. This test was not. It now asserts inside the pod and
reads the exit code, and its pod name gains `$$` so an interrupted run cannot
make the next one fail with `already exists`. Checked both ways against a live
cluster: it passes, and the same shape against a path Tempo answers 404 for
exits 1.

Of the five tests in `tests/contract/01-openai-api.bats`, all five passed. The
reasoning-model failure recorded earlier in this document did not appear, because
the CI job deploys `models/ornith-9b/overlays/ci`, a different model. This was
the first thing predicted as the likely cause of the CI failure, and it was
wrong.

### The 39-minute silent hang

`smoke` ran tests 1 to 28 in about twenty seconds, failed test 29
(`a valid token is accepted`, expecting 200) at `00:03:50Z`, then printed nothing
until GitHub cancelled the job at `00:43:18Z`.

Test 30 is acceptance criterion 4, the 429 test, and it was

```bash
for i in $(seq 1 40); do
  code=$(chat "$token" 64)
  [ "$code" = "429" ] && break
done
```

with `chat()` calling `curl` with **no `--max-time`**. A count is not a bound when
each iteration can take arbitrarily long. Forty unbounded completions is where
the forty minutes went.

Four things in that one file, all fixed:

1. `chat()` now passes `--max-time 120`. A 64-token completion that takes longer
   than two minutes is a fault this suite should report, not wait out.
2. The 429 loop is bounded by a wall clock as well as a count, and it reports
   every HTTP code it saw. The old form asserted on the last code only, so a run
   where every request returned 500 was indistinguishable from a quota that never
   ran out.
3. Nothing waited for the model to load before asserting 200, which is why test
   29 failed seconds after the platform finished installing. The
   `observability` job on the same commit needed 53 seconds to reach `readiness
   becomes true and the model answers`. There is now a readiness gate.
4. This was the one suite of twelve that never got `require_cluster`.

`get_token` in `tests/lib/helpers.bash` also gained `--max-time 30`, for the same
reason: every caller sits inside a deadline, and a hung token request spends all
of it without saying anything.

### Criterion 4 cannot be settled on this machine, and now there is a number

Running the rewritten suite against the live cluster gave 4 passes and one
failure, the 429 test. The bound worked exactly as intended: instead of 39
minutes of silence, it stopped and named the cause.

The cause is arithmetic, not a quota bug. `security/oidc/tokenratelimitpolicy.yaml`
gives the free tier **500 tokens per 60s window**, and a token-based counter only
advances once a response reports its usage. So the budget can only be spent if
the stack generates more than 500 tokens inside 60 seconds. From llama.cpp's own
timing log on 2026-08-20:

```
eval time = 12633.52 ms / 8 tokens (1804.79 ms per token, 0.55 tokens per second)
```

0.55 tokens per second is **33 tokens** in a 60 second window, against a **500
token** budget. The window resets roughly fifteen times over before the budget
could be spent.

One number from that day should not be read as latency. A `curl` for a single
64-token completion returned `HTTP 000` after `--max-time 300`, but the two
requests after it returned `HTTP 500` in under a second, so the server was
already saturated by a concurrent `bats` run. That is contention. The clean
figure is the engine's own 0.55 tokens per second, which puts a 64-token
completion at about 116 seconds of eval.

So criterion 4 is not untested any more. It is **untestable as specified on this
engine**, and settling it needs either a free-tier budget in reach of 0.55
tokens per second or a faster engine. That is a decision about the limits, not a
patch to the test, and the test says so in its failure message rather than
leaving a red result to be misread as a broken AuthPolicy.

## Correction, 2026-08-20: the quota IS reachable here, and this section's reasoning was wrong

The paragraphs above are kept because the arithmetic in them is correct and the
conclusion drawn from it is not. The error is one word:

> "the budget can only be spent if the stack **generates** more than 500 tokens
> inside 60 seconds"

`usage.total_tokens` is prompt tokens **plus** completion tokens, not completion
tokens alone. So the generation rate is one way to spend the budget and not the
only one. A single request with a long enough prompt spends it without
generating anything at all.

Measured 2026-08-20 06:55Z against the free tier, with a roughly 500-token prompt
and `max_tokens: 1`:

```
request 1  ->  HTTP 200   usage.total_tokens=552
request 2  ->  HTTP 429
```

Two requests. The first is over the 500-token budget on its own, and the second
is rejected. **Criterion 4 is settleable on this machine**, and the engine's
0.55 tokens per second never had to enter into it.

What this cost is worth stating plainly. The 0.55 figure was measured, dated, and
correct. The claim built on it was not, and no measurement was taken to check the
claim itself, because the arithmetic looked conclusive. A number that is right
does not make the sentence around it right.

### Criterion 4 holds, in CI, and the local result was not the whole story

The rewritten `06-auth-quota.bats` ran in CI run `32320742653` and

```
ok 30 the free tier is cut off with 429 once its token budget is spent
```

passed in 6.3 seconds. So the AuthPolicy, the TokenRateLimitPolicy, and
Limitador all do what criterion 4 asks. What could not be shown locally was not
the quota; it was that this laptop's engine cannot generate 500 tokens inside a
60 second window. CI deploys `models/ornith-9b/overlays/ci`, and that model can.

The `smoke` job also went from **45 minutes, killed by its own timeout** to
**7 minutes 30 seconds** and a clean pass/fail. Two tests failed, both in
`tests/contract/02-readiness.bats`, and both were defects in the test:

- `readiness becomes true and the model answers` called `/v1/models` with **no
  bearer token**. That works in the `observability` job, which never installs
  Kuadrant, and returns 401 in the `smoke` job, which applies
  `security/oidc/authpolicy.yaml`. The same test passed in one job and failed in
  the other on the same commit. `tests/contract/01-openai-api.bats` already sent
  a token; this suite did not.
- `readiness is false while weights are still loading` deleted the predictor
  pods, slept 5 seconds, and read `.items[0]`. That is whichever pod the API
  server lists first, which after a `--wait=false` delete is often the OLD pod,
  still `ready: true`. It is also vacuous in the other direction: before the new
  container starts there is no `containerStatuses` entry at all, so the query
  returns an empty string, and an empty string is not `true`. **The old
  assertion passed on having observed nothing.** It now identifies the
  replacement pod by name, waits for a readiness value to exist, and requires
  that value to be `false`.

### Defect 15. One flaky clone took four Applications down with it

Run 3 stalled with 11 of 16 Applications `Synced/Healthy` and the rest blocked
behind `gateway-api-crds`, which reported

```
ComparisonError - DeadlineExceeded desc = context deadline exceeded
```

on every attempt, leaving **0** Gateway API CRDs installed. Nothing that
declares an `HTTPRoute` can sync without them, so `istio-gateway`, `keycloak`,
`model-local`, and `security-oidc` all sat OutOfSync. One dependency at the head
of the order took four with it.

The numbers, all measured 2026-08-20:

| | |
|---|---|
| Deadline the repo-server was given | **60s**, read from its own gRPC log lines |
| Shallow clone of `gateway-api` v1.5.1 from this machine | **12s**, 21 MB on disk |
| Size of the repo Argo CD clones | 30011 KB |
| Size of the release file the imperative path fetches instead | 1024333 bytes |

So the repository is not too big to clone in 60 seconds. Sixteen Applications
generating manifests at once on a laptop is the cause, and run 2 reached Synced
on the same Application, which is worse than a consistent failure because it
makes the fault look random.

`platform/50-argocd/install.sh` now sets
`controller.repo.server.timeout.seconds=180` and
`reposerver.parallelism.limit=4`, one for each half of that. Both were verified
by rendering the chart with the script's own flags and reading
`argocd-cmd-params-cm` out of the output.

This is also the widest two-path divergence in the repository. The imperative
path runs one `kubectl apply -f <release URL>` and fetches a single 1 MB file.
The declarative path clones 30 MB of Go source, docs, and tests to read one
directory, because an Argo CD Application can source a git repository, a Helm
chart, or an OCI artifact, and not a URL. Vendoring `standard-install.yaml` here
would remove the clone at the cost of a megabyte of generated YAML that has to
be refreshed whenever `versions.yaml`'s `crds.gateway_api` moves. That is the
next thing to try if raising the deadline is not enough.

### Defect 16. A controller that checks a CRD once, at startup, and exits

Downstream of defect 15, and the clearest demonstration of what twelve seconds of
sync-wave ordering costs. While `gateway-api-crds` was still timing out, KServe
(wave 2) started, found no HTTPRoute CRD, and refused to run:

```
The InferenceService controller won't watch gateway.networking.k8s.io/v1/HTTPRoute
resources because the CRD is not available.
unable to create controller ... error: gateway API mode requires
gateway.networking.k8s.io/v1 "HTTPRoute" CRD
```

`kserve-controller-manager` went to `CrashLoopBackOff` with 6 restarts and a
`back-off 5m0s`, its `manager` container never ready. So `kserve` reported
`Synced/Degraded` and `model-local` could not sync an InferenceService, because
nothing was there to admit one.

Two things this says that the earlier defects did not.

First, Argo CD's `retry` fixes Argo CD's retries and nothing else. This is a
**pod** exiting, so recovery is Kubernetes' own restart backoff, which grows to
five minutes. The backoff eventually wins - the CRDs do arrive - but the
recovery is measured in minutes and `task local:up` is holding a deadline
meanwhile.

Second, real ordering cannot come from sync waves as long as the gate between
waves is child Application health, because a fresh Application reports Healthy
at once (defect 2). The `retry` backoff makes Argo CD's own tasks converge; it
cannot stop a container from starting too early.

The fix that would give true ordering is a PreSync hook on the KServe
Application that blocks until `crd/httproutes.gateway.networking.k8s.io` is
Established. This repository already uses that shape:
`platform/10-istio/gateway-service-nodeport.yaml` is a PostSync hook Job with
its own ServiceAccount, Role, and RoleBinding. That is not written yet, and this
paragraph is the record of why it should be rather than a claim that it is.

### Run 3: `task local:up` exited 0, and the gateway had no authentication

Run 3 started `2026-08-20T01:22:02Z` and **exited 0** at `01:51:31Z`, 29 minutes
and 29 seconds. All sixteen Applications reported `Synced` and `Healthy` in three
consecutive samples. Peak memory 18376 MiB of 23744, 65 pods.

Every fix from runs 1 and 2 held. `istiod` was `Synced/Healthy` where it had been
permanently Degraded. `kyverno` was Synced. `gateway-api-crds` timed out for ten
minutes and then recovered on its own, which is the `retry` backoff doing exactly
what it was added for. `model-local` reached Synced on `Retrying attempt #6`; in
run 1 it would have stopped at five.

Then the first request told a different story:

```
GET /v1/models with no token  ->  HTTP 200
```

**Everything green, and the gateway was open.** `security-oidc` was
`Synced/Healthy`, every Kuadrant pod was `Running`, and the AuthPolicy said:

```
Accepted=False  reason=MissingDependency
"[Gateway API] is not installed, please restart Kuadrant Operator pod once
 dependency has been installed"
```

**Defect 17.** The Kuadrant operator checks for Gateway API at startup, caches
the answer, and refuses every policy until someone restarts it. It says so in its
own message. Nothing crashed, so Kubernetes restart backoff never applied - this
is the difference between it and KServe in defect 16, which crash-looped and
recovered on restart 7 without help. Kuadrant would have stayed like that for the
life of the cluster.

Restarting `deploy/kuadrant-operator-controller-manager` gave
`Accepted=True Enforced=True`. And then every request returned **503**.

**Defect 18.** The gateway's logs:

```
Wasm remote code fetch is unstable and may cause a crash
Retry limit exceeded for fetching data from remote data source.
Plugin kuadrant-wasm-shim failed to load
Plugin configured to fail closed failed to load
```

Kuadrant enforces policy through a Wasm module that Envoy fetches over HTTP,
configured **fail closed**. This paragraph said "from a remote registry" until
2026-08-20, and that was wrong. Read out of the live `EnvoyFilter`
`istio-system/kuadrant-llm`, the source is
`http://kuadrant-operator-wasm.kuadrant-system.svc.cluster.local:8082/plugin.wasm`:
another Pod in this cluster, not the internet. See R19 in
[`docs/sad/11-risks-and-debt.md`](sad/11-risks-and-debt.md), because this failure
recurred on 2026-08-20 with no bootstrap involved. The fetch failed, so the gateway rejected
everything, valid tokens included. Restarting `deploy/llm-istio` made it fetch
again, and the full path came good: 401 with no token, 401 with a forged token,
200 with a Keycloak JWT serving `ornith-9b`.

So criterion 1 is **still not settled**, and this is a sharper result than a
failure would have been. The delivery path completed, reported success, and left
a service that needed two manual restarts. `tests/smoke/10-gitops.bats` has a
test named "a rebuilt cluster reaches a working endpoint with no manual steps".
Two is not none.

### What that changes

**`task local:up` now ends with `clusters/local-kind/verify-serving.sh`.**
Sixteen green Applications says the manifests reached the cluster. It does not
say the request path works, and the criterion asks for a ready service. The
script asserts an unauthenticated request is rejected with 401 - not merely that
it fails, because 503 is the fail-closed case and would satisfy a weaker check -
and then that a real JWT gets 200 with a model listed. On failure it prints the
AuthPolicy conditions and the gateway's Wasm errors, which are the two things
that explained this run.

It was mutation tested, and the first attempt was a bad test rather than a good
result: deleting the AuthPolicy did not trip it, because Argo CD's `selfHeal`
restored the policy inside the 20 seconds of waiting (the replacement was 44
seconds old when checked). Scaling `deploy/llm-istio` to zero did trip it, exit
1, with the diagnosis printed. That mutation also exposed a defect in the
script's own `code()` helper: `curl ... || printf 'curl-exit'` printed **both**,
because curl writes `000` on a connection failure and then the `||` appended its
own word, giving `returned 000curl-exit`. Output and exit code are captured
separately now, the same fix `chat()` in `06-auth-quota.bats` needed.

**`platform/25-kuadrant/gwapi-wait.yaml` is a PreSync hook** that blocks the
Kuadrant sync until `gateway.networking.k8s.io/v1` serves `httproutes`. Sync
waves cannot do this: they ordered the Applications correctly and ordered them
twelve seconds apart, for the reason in defect 3.

Two things about that hook were wrong when first written, and both were caught by
checking rather than reasoning:

- It globbed the CRD's status for `'"type":"Established"'` followed by
  `'"status":"True"'`. The API server serializes a CRD condition with keys in the
  order `lastTransitionTime, message, reason, status, type`, so `status` comes
  **before** `type` and the assumed order is not the response's order. It now
  asks the discovery endpoint whether the group serves `httproutes`, which is one
  unambiguous token and a stronger claim: a group that is served is a CRD that is
  Established and usable.
- It carried a ClusterRole granting `get` on `customresourcedefinitions`, which
  the discovery check does not use. Reading `/apis/*` needs no grant: the
  built-in `system:discovery` binding covers `Group/system:authenticated`.
  Verified with `kubectl auth can-i get /apis/gateway.networking.k8s.io/v1 --as`
  that ServiceAccount, which answered `yes` with no bindings of its own. The
  ClusterRole and its binding are gone, so the hook now asks for no privilege at
  all.

KServe gets no hook. It converges on its own through restart backoff, slowly, and
a second hook is cost without a change in outcome. That is a scope decision, and
this paragraph is where it is recorded.

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
