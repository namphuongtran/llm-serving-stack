# Status: what is proven, what is not

This file is the tracked account of what this repository has actually
observed, and what it has only written down. It is the single most important
document here, and it is deliberately longer than the README.

It moved out of `README.md` on 2026-08-20, unchanged. Nothing was rewritten,
softened, or shortened **in the move itself**: the README had grown to the point
where the status buried the introduction, and the introduction buried the
status. `README.md` now carries a summary and links here.

One thing changed **after** the move, later the same day, and it is a
measurement rather than an edit: criterion 9 went green. It is recorded in
place, with the run IDs, rather than smoothed into the surrounding text.

## Where the repository stands

**Run for the first time on 2026-08-19, and partly proven.** Until that day the
README's first line read "code-complete, unrun", and everything below it was
written and statically checked but never observed. Since then it has been run
three ways: by hand layer by layer, by Argo CD from git, and by CI.

All thirteen layers came up on a 3-node `kind` cluster and the service answered
a real request: HTTP 401 without a token, HTTP 200 with a JWT from Keycloak, and
a streaming chat completion. Argo CD reached the same working service from git
on 2026-08-20. `docs/deployment-walkthrough.md` is the account, with every number
dated, and `tools/step-up.sh` is how to repeat it one layer at a time.

**Four of the nine phase 1 acceptance criteria hold as of 2026-08-20**, and the
count moved twice in one day, in both directions. The table under "What is
unproven" says which is which.

**Criterion 1 now holds.** Run 4 of the pull path took a deleted cluster to a
ready service in **17 minutes 9 seconds**, exit 0, with no manual step, and the
request path was checked independently of the script that reported it.

**Criterion 9 no longer holds, and this file claimed it did for two commits.**
Four consecutive CI runs were green, which is what that claim was measured on.
The next two runs were red, both in the `observability` job, and both were
triggered by documentation-only commits that cannot have broken it. The honest
status is **flaky**, not holding. See "Criterion 9" below for both failures.

The rule this breaks is the repository's own: four green samples is a
measurement, and "holds" is a claim about the future that four samples did not
support. The correction is recorded here rather than applied quietly.

Running it is what found the defects, and static review did not. The first run
found seven that four separate review passes over the whole repository had all
missed: a file mode that broke `task local:up` at its second command, a bash 3.2
array expansion that killed the KServe install, two selectors naming a label
Istio removed in 1.24, and three tests that passed while the thing they named was
broken.

The pull-based path then found fifteen more, and none of them was visible from
the imperative path. Two are worth knowing before reading any of this:

- Argo CD applies **client-side** by default, writing each manifest into a
  262144-byte annotation. Five of the fifteen charts here ship CRDs larger than
  that, so KServe, Kyverno, Kuadrant, the observability stack, and KEDA all
  failed to install. `helm install` never writes that annotation, which is why
  the imperative path installs the same charts without complaint.
- An Argo CD Application that fails to read its git path still reports
  `health.status: Healthy`. That one property broke both the acceptance check
  and sync-wave ordering, and it made `task local:up` exit 0 in one second on a
  cluster where nothing had been deployed.

Each defect is recorded where it was found.

## Three kinds of gap, and they are not the same kind

- **Unproven.** A number or outcome nobody has measured, because no cluster
  exists to measure it against. The manifest and the test are both believed
  correct; the measurement is owed.
- **Doubted.** A mechanism there is a specific, sourced, technical reason to
  believe does not work as designed, whether or not a cluster ever confirms
  it. There is one: cross-backend failover, recorded in
  [ADR 0007](adr/0007-failover-not-expressible-in-gateway-api.md), which
  is withdrawn from phase 1 rather than pending.
- **Unverified by construction.** Phase 1's own acceptance bar, which cannot
  be met until the suite runs once, end to end.

## The first load test, 2026-08-20, and the three things it found

The stack had never been put under sustained load. On 2026-08-20, after criterion
1 was settled, 64 streaming requests were sent through the gateway at concurrency
8 over about 7 minutes. The engine has 2 slots per replica and 2 replicas, so 4
in flight and 4 deferred, which is above the `ScaledObject` threshold of 2.

Nothing here is a reason to stop. All three are recorded because none of them was
visible from a run that only brings the stack up and asks it one question.

### 1. KEDA scales to three, and the third replica can never schedule

KEDA did its job. Under load, queue depth reached 5 and the HPA read
`1667m/2 (avg)`, so it set `spec.replicas: 3`. The third pod never ran:

```
ornith-9b-predictor-...-6qsrg   2/2   Running   llm-serving-stack-worker
ornith-9b-predictor-...-bhtcp   2/2   Running   llm-serving-stack-worker2
ornith-9b-predictor-...-gk8v2   0/2   Pending   <none>

0/3 nodes are available: 1 node(s) had untolerated taint(s),
2 node(s) didn't match pod topology spread constraints.
```

This is arithmetic, not a transient. The cluster has three nodes; the
control-plane is tainted, leaving two schedulable. `topologySpreadConstraints`
uses `maxSkew: 1` with `DoNotSchedule` on `kubernetes.io/hostname`. Two replicas
sit one per worker, so a third would make the skew 2 and is refused.
**`maxReplicaCount: 3` and `maxSkew: 1` cannot both be satisfied on two worker
nodes.** Nothing in this repository records that the two settings contradict each
other.

**And `tests/smoke/07-autoscaling.bats` would pass.** It asserts
`.spec.replicas -gt 2`, which is the number KEDA writes, not the number of pods
that serve traffic. The desired count went to 3 and `readyReplicas` stayed at 2.
That is the same shape as the three tests this repository already records as
passing while the thing they named was broken.

Three ways to resolve it, none applied yet, because choosing one is a design
decision rather than a fix: add a third worker to `prereqs/kind-cluster.yaml`;
lower `maxReplicaCount` to 2, which makes the autoscaler pointless; or relax the
spread constraint to `ScheduleAnyway`, which is what
`models/ornith-9b/overlays/local/patch-resources.yaml` deliberately refused,
because the availability tests depend on the replicas being on different nodes.

### 2. Under load, the gateway returns 500 on both paths

The auth layer degrades under concurrency, and it degrades in both directions:
a request with no token stops getting 401, and a request with a valid token
stops getting 200. Both become HTTP 500.

Measured 2026-08-20, twenty requests per row unless stated:

| When | No token | Valid pro token |
|---|---|---|
| Under sustained load, 06:14Z to 06:22Z | 500 x5 then 401 x15 | **500 x6 of 10** |
| Quiet, 06:32Z | 401 x18, **500 x2** | 200 x20 |
| Under benchmark load, 06:35Z | not sampled | `task chat` failed **3 of 3** |

The last row is the cleanest evidence, because it was not looking for this:
`bench/run.sh` was running one scenario, and three consecutive `tools/chat.sh`
calls returned `Internal Server Error.` Authorino logged `UNAVAILABLE` at
06:35:20Z, 06:35:22Z, and 06:35:23Z, which is those three requests.

It recovers on its own when the load stops.

The cause is in Authorino's own log, not inferred:

```
"authorized":false,"response":"UNAVAILABLE","object":{"code":14}

logger authorino...authconfig.jwt
msg "failed to discovery openid connect configuration"
issuerUrl "http://llm.localtest.me/realms/llm"
```

gRPC code 14 is `UNAVAILABLE`, which the gateway renders as HTTP 500. A denial
would be code 16, `UNAUTHENTICATED`, which renders as 401. So **OIDC discovery
against Keycloak is a runtime dependency of the reject path, not only of the
accept path**: when Authorino cannot load the issuer's configuration, a request
carrying no token at all gets 500 rather than 401.

**This is not a security hole.** It never returns 200 without a token; it fails
closed. But criterion 3 asks for 401, and `clusters/local-kind/verify-serving.sh`
asserts 401, so a `task local:up` that finished during one of these windows would
fail on a healthy platform. That is the correct behaviour for the check and a
real source of flakiness for the criterion.

One tooling defect found beside it: `tools/chat.sh` printed
`Internal Server Error.` and **exited 0**.

### 3. Eighteen containers restarted, including the control plane

During the load, at 06:14:53Z and within a few minutes of it, eighteen containers
restarted across the cluster, among them `kube-scheduler`,
`kube-controller-manager`, four Kuadrant operators, four Kyverno controllers, and
the Argo CD repo-server. Most exited 0 (`Completed`), some exited 1 (`Error`);
none reported `OOMKilled`, and no node reported `MemoryPressure`.

Memory across the three node containers, measured with `docker stats`:

| When | Total | % of 23.2 GiB |
|---|---|---|
| Before load, 06:03Z | 18407 MiB | 77 |
| After load, 06:22Z | 19574 MiB | 82 |
| Later, 06:32Z | 19902 MiB | 84 |

**No cause is asserted here.** Eighteen simultaneous restarts under load, with
memory climbing, is a symptom worth recording and not a diagnosis. What is
established is the correlation and the timestamps; what is owed is the cause.

> **Unmeasured (2026-08-20):** why eighteen containers restarted within minutes
> of each other under load. Re-run the load with
> `kubectl get events -A --sort-by=.lastTimestamp -w` captured to a file, and
> read the reasons rather than inferring them from restart counts.

### 4. The free tier quota IS reachable here, and this file said it was not

For one day this file, `CLAUDE.md`, `docs/deployment-walkthrough.md`, and two
files in `docs/sad/` all said criterion 4 was untestable on this engine. The
reasoning was:

> the budget can only be spent if the stack **generates** more than 500 tokens
> inside 60 seconds, and llama.cpp generates 0.55 tokens per second, which is 33
> tokens per window

Every number in that sentence is correct and dated. The conclusion is wrong,
because `usage.total_tokens` is prompt tokens **plus** completion tokens.
Generation rate is one way to spend the budget, not the only one.

Measured 2026-08-20 06:55Z, free tier, a roughly 500-token prompt with
`max_tokens: 1`:

```
request 1  ->  HTTP 200   usage.total_tokens=552
request 2  ->  HTTP 429
```

Two requests settle it. **The lesson is not about tokens.** A measured, dated,
correct number was used to support a claim, and nobody measured the claim,
because the arithmetic looked conclusive. This repository's rule about numbers
did not catch it, because the number was never the problem.

### 5. No benchmark on this engine can finish before its own token expires

The first benchmark run this repository has ever completed, scenario
`01-short.json`, 40 requests at concurrency 4:

| TTFT p50 | TTFT p95 | ITL p95 | out tok/s | errors |
|---|---|---|---|---|
| 186.494s | 199.852s | 29.684s | 0.210 | **31 of 40** |

Nine errors were HTTP 500 and three were 503, both finding 2. **Nineteen were
HTTP 401**, and those are a defect in the harness:

- `bench/run.sh:24` fetches one token: `TOKEN="$(get_token llm-tier-pro)"`.
- `platform/15-keycloak/realm-export.json` sets `accessTokenLifespan: 900`.
- This run took about 19 minutes, from 06:33Z to 06:52Z.

The token expired at about minute 15 and every request after that was rejected.
At 0.210 output tokens per second, **every scenario in `bench/scenarios/` runs
longer than 15 minutes on this engine**, so this is not a corner case: no
benchmark here can currently complete.

The latency figures above come from 9 successful requests out of 40, on a cluster
that was also failing. They are a first data point and not this stack's
performance.

> **Unmeasured (2026-08-20):** clean benchmark numbers. Fix `bench/run.sh` to
> refresh the token during a run, then re-run `task bench` on a quiet cluster and
> commit the dated result directory under `bench/results/`.

## The webhook readiness race

**Four consecutive CI runs died on this, and it is one defect, not four.** All
four were documentation-only commits, which cannot break a cluster job.

`helm --wait` and `kubectl rollout status` return when a Deployment reports
available. Neither waits for an **admission webhook to be reachable**. Every
install script then uses the very next command to create an object that webhook
must admit.

Two instances, two components, measured from the CI logs:

| Run | Job | Timing | Webhook |
|---|---|---|---|
| `32340677894` | `observability` | `06:45:08.0058` rolled out, `06:45:08.2002` refused, **194 ms** | `servingruntime.kserve-webhook-server.validator` |
| `32342136049` | `smoke` | `07:05:15.1581` rolled out, `07:05:15.2340` refused, **73 ms** | `mutate-policy.kyverno.svc` |

```
Internal error occurred: failed calling webhook "servingruntime.kserve-webhook-server.validator":
Post "https://kserve-webhook-server-service.kserve.svc:443/...": dial tcp 10.96.75.106:443: connect: connection refused
```

`connection refused` on a ClusterIP is the signature of a Service with no ready
endpoints: kube-proxy installs a REJECT rule. For KServe there is a second,
independent reason: its readiness probe is `/readyz` on **8081** while the
webhook serves on **9443**, so readiness does not cover the webhook at all.

**Why it looked random.** It is a race, so which job loses is luck. `smoke`
survived twice only because it installs Kuadrant after KServe, which takes tens
of seconds and incidentally covered the gap. On the third run `smoke` lost and
`observability` won.

### The scope is four call sites, not two

Every `failurePolicy: Fail` webhook in this cluster belongs to cert-manager,
KServe, istiod, or Kyverno. Anywhere an object is applied right after the webhook
that must admit it:

| Site | Applies | Webhook | Seen fail |
|---|---|---|---|
| `platform/12-kyverno/install.sh` | `policy/*.yaml` | `kyverno-policy-mutating` | yes |
| `.github/workflows/ci.yml`, `Deploy the CI model` | the model overlay | `servingruntime.serving.kserve.io` | yes |
| `platform/10-istio/install.sh` | `gateway.yaml`, `telemetry.yaml` | `istio-validator-istio-system` | not yet |
| `platform/15-keycloak/install.sh` | into namespace `llm` | `kyverno-resource-validating` | not yet |

### The fix, and why a plain retry would have been wrong

`platform/lib/apply.sh` provides `apply_retry`, and all four sites use it. It
retries **only** the unreachable signature and fails immediately on a denial:

```
failed calling webhook ... connect: connection refused   -> transient, retry
admission webhook "..." denied the request: ...          -> real, fail at once
```

That distinction is the whole design. `.github/workflows/ci.yml` states that a
policy rejection must turn the job red, and that the red "is a real finding
rather than a CI problem to route around". A retry loop that swallowed all
errors would turn exactly that finding green after a few seconds.

The loop carries a wall clock, default 180s, which is this repository's own rule
after a CI job hung for 39 minutes.

**This is not a new pattern here.** `clusters/local-kind/root-app.yaml` already
carries `retry: limit 20`, so Argo CD rides out the same race on the pull-based
path. The imperative path was missing what the declarative path already had.

### Proved by mutation on a live cluster, 2026-08-20

Three tests, each against the real webhook rather than a simulation:

| Test | Setup | Result |
|---|---|---|
| Unreachable webhook recovers | `kserve-controller-manager` scaled to 0, endpoints `[]`, webhook config still present, scaled back after 30s | retried **30 attempts over 65s**, then `exit 0` |
| Denial is not retried | a Pod with a floating tag applied to namespace `llm` | `exit 1` in **0s**, `apply_retry: admission denied, not retrying` |
| The wall clock bounds it | same as test 1 with `APPLY_RETRY_TIMEOUT=6`, backend never restored | `exit 1` after **7s**, 4 attempts, original error printed |

Test 1 was run first against Kyverno and proved nothing, because **Kyverno removes
its own webhook configurations when its admission controller is down**. With no
webhook config there is no race to reproduce. KServe does not do this, which is
why it is the honest reproduction and also why it is the one CI hit twice.

### The first fix went red, and the reason is the point

Run `32343704184` failed in both cluster jobs, and **not on the webhook**:

```
mktemp: too few X's in template 'apply-retry'
```

`mktemp -t apply-retry` is valid BSD, which is what macOS ships, and invalid GNU
coreutils, which is what the runners ship. Verified afterwards inside this
repository's own `kindest/node` container, GNU coreutils 9.7: the old form
reproduces the CI error exactly and `mktemp "${TMPDIR:-/tmp}/apply-retry.XXXXXX"`
works. Both forms work on macOS.

**Why three passing mutation tests did not catch it.** All three used
`apply_retry <file>`. The temp file exists only on the `apply_retry -` path, and
every CI call site is a pipe. The tests exercised the branch that was already
fine and never touched the branch that shipped broken.

This is the mirror image of a defect this repository already records: the KServe
install script died on bash 3.2 locally and CI could never have seen it, because
runners have bash 5. Here the code worked on macOS and only Linux could see it.
Both directions are real, which is why both paths have to run.

A second bug surfaced in the same test round, on a third platform. Sourcing the
helper from **zsh**, the macOS default shell a human would use, printed
`trap: undefined signal: RETURN` and leaked the temp file, because zsh has no
`RETURN` trap. The cleanup is now explicit at every return instead.

Re-tested after both fixes, 2026-08-20:

| Test | Result |
|---|---|
| stdin path, happy case, under `bash` and under `zsh` | exit 0, no trap error, **no temp file leaked** |
| stdin path with the webhook down, restored after 25s | retried **29 attempts over 58s**, then created, exit 0 |
| `mktemp` template under GNU coreutils 9.7 | old form errors, new form works |

### CI went green, and that is not evidence the fix works

Run `32344494225` on `dde6587` passed all four jobs. Read the next paragraph
before drawing the obvious conclusion.

```
07:35:23.1122  deployment "kserve-controller-manager" successfully rolled out
07:35:23.3602  servingruntime.serving.kserve.io/llamacpp-arm64 created
```

**248 ms**, against the 194 ms that failed two runs earlier, and it succeeded on
the first attempt. Searching the whole run for the helper's own retry messages:

```
"webhook not reachable yet"  0 occurrences
"succeeded on attempt"       0 occurrences
```

**The race did not happen.** The retry branch, which is the entire point of the
change, was never executed in CI. What this run proves is narrower than it
looks:

| Claim | Proven by this run? |
|---|---|
| The `mktemp` and `zsh` defects are fixed | **yes** - the step ran at all, which it could not before |
| `apply_retry` is wired in and applies correctly | **yes**, on the happy path |
| The retry rides out an unreachable webhook | **no** - proven locally by mutation, not here |
| CI is reliably green | **no** - one sample, and the interesting branch was cold |

### A second run, and a sentence of mine that it corrects

Run `32347833827` on `6a34cab` also passed all four jobs, and also never entered
the retry branch: `webhook not reachable yet` and `succeeded on attempt` both
appear **0** times, as does `failed calling webhook`.

Every gap measured so far, between `successfully rolled out` and the first object
that needs the webhook:

| Site | Gap | Result |
|---|---|---|
| Kyverno policies, `smoke` | **73 ms** | failed |
| Kyverno policies, `smoke` | 145 ms | passed |
| KServe model, `observability` | **194 ms** | failed |
| KServe model, `observability` | 248 ms | passed |
| KServe model, `observability` | 255 ms | passed |
| KServe model, `smoke` | about 42 s | passed |

**This corrects something written two commits ago.** That entry said the timings
"refute a tempting shortcut: 194 ms failed and 248 ms passed, so the gap alone
does not decide it". Two points cannot refute a threshold, and with six points
every failure sits below every success at the same site, which is exactly what a
propagation delay looks like. The data is **consistent** with a threshold, not
against one.

A retry is still the right fix, for a different reason than the one given: the
threshold is not a constant. It moves with runner load, cluster size, and how
many objects kube-proxy is reprogramming at that moment. A `sleep` has to guess
a number that has no principled value; a retry adapts to whatever the number is
on the day.

That is the second time in this session a correct set of numbers carried a wrong
conclusion, the first being the free-tier quota in finding 4. Both were caught by
taking another measurement rather than by re-reading the sentence.

> **Untried (2026-08-20):** whether the retry branch works in CI. Five mutation
> tests pass locally across bash, zsh, and GNU coreutils; CI has gone green once
> without exercising it. Criterion 9 stays flaky. The evidence that would settle
> it is a CI run whose log contains `apply_retry: ... succeeded on attempt N`
> with N above 1, which cannot be forced and has to be waited for.

**And the changed script could not be run end to end here**, which is a separate
finding worth its own line. `./platform/12-kyverno/install.sh` on this cluster
exits 1 at its **first** command:

```
Release "kyverno" does not exist. Installing it now.
Error: unable to continue with install: ServiceAccount "kyverno-admission-controller"
in namespace "kyverno" exists and cannot be imported into the current release:
invalid ownership metadata; annotation validation error: missing key
"meta.helm.sh/release-name"
```

This cluster was built by Argo CD, which renders the chart and applies it, so
Helm holds no release record. The failure is at `helm upgrade --install`, before
`apply_retry` is reached, so it says nothing about the change above. What it does
say is that `CLAUDE.md`'s description of the install scripts as "a working manual
bootstrap" holds **only on a cluster those scripts built**. The two paths are not
interchangeable on an existing cluster, in either direction.

## What is unproven

The single most important section of this file. One run on 2026-08-19 settled two
of the nine criteria and a handful of the markers below; the rest are still owed,
so what follows is not a formality.

### The nine phase 1 acceptance criteria

Two held on 2026-08-19. Three on 2026-08-20, then four when CI went green, then
five when the pull path came up clean, then four again when CI went red twice.
Settle the rest with `bats tests/` against a live cluster, then record the result
and the date here.

| # | Criterion | Status | Settle it |
|---|---|---|---|
| 1 | `task local:up` takes an empty machine to a ready service | **HOLDS 2026-08-20**, on run 4. Exit 0 in 17m09s, sixteen Applications green, 401 without a token and a streamed answer with one, no manual step | `task local:down && task local:up` |
| 2 | A JWT obtained from Keycloak returns a streamed chat completion | **HOLDS 2026-08-19** | `bats tests/smoke/03-identity.bats tests/contract/01-openai-api.bats` |
| 3 | A request without a JWT is rejected with 401 | **HOLDS 2026-08-19** on an idle cluster. **Degrades under sustained load**: 2 of 20 returned 500, measured 2026-08-20 06:32Z. Never 200 | `bats tests/smoke/06-auth-quota.bats` |
| 4 | Exceeding the token quota returns 429 | **HOLDS 2026-08-20**, in CI **and locally**. This row said "not reachable on the local engine" for a day; see finding 4 | `bats tests/smoke/06-auth-quota.bats` |
| 5 | Grafana shows TTFT p95 and requests waiting from real traffic | untested | `bats tests/smoke/05-observability.bats` |
| 6 | Under load, KEDA scales the predictor above its floor of 2 replicas, to 3, with evidence | **partly, and the test would pass anyway.** KEDA set `spec.replicas: 3` under real load 2026-08-20, and the third pod **can never schedule on this cluster**. See "The first load test" below | `bats tests/smoke/07-autoscaling.bats` |
| 7 | Draining a node keeps the service available, PDB holding | untested | `bats tests/smoke/08-availability.bats` |
| 8 | The recovery drill runs and its recovery time is committed | untested | `task drill:recovery` |
| 9 | CI is green on an arm64 runner | **FLAKY 2026-08-20**, and this row said HOLDS for two commits. Four green, four red, then green again after the webhook race was fixed. The green run did not exercise the fix | `gh run list`, after a push to `main` or a pull request |

Criterion 1 is the one to read carefully, and it took four runs.

**Run 4 settled it, on 2026-08-20.** `task local:down && task local:up` deleted a
running cluster, built a new one, and reached a ready service:

```
run started   2026-08-20T05:44:19Z
run finished  2026-08-20T06:01:29Z
elapsed       17m 09.65s
exit          0

all Applications Synced and Healthy (3 of 3 consecutive samples)
16 of 16 Applications Synced and Healthy
verify-serving.sh: unauthenticated request rejected with 401
verify-serving.sh: the gateway serves ornith-9b
```

**Checked independently at 06:02:02Z, because a script reporting its own success
is the exact failure run 3 was.** Not through `verify-serving.sh`, and not
through the Application list:

| Check | Result |
|---|---|
| `GET /v1/models`, no token | `HTTP 401` |
| `GET /v1/models`, forged token | `HTTP 401` |
| `GET /v1/models`, real JWT | `HTTP 200`, serving `ornith-9b`, Q4_K_M, 8.95B params |
| `POST /v1/chat/completions`, `stream: true` | **43 SSE chunks**, terminated by `data: [DONE]` |
| `InferenceService` | `ornith-9b=True`, `fallback-small=True` |
| Predictor replicas | 2, on `worker` and `worker2`, different nodes |

**Three things this run showed that a bare "exit 0" would hide.** All three are
recorded because none of them is a defect, and each one would look like one to
somebody reading a dashboard:

- **Two containers restarted, and no human restarted them.** `keda-operator`
  once (exit 0, `Completed`, 05:47:20Z) and `kserve-controller-manager` five
  times (exit 1, `Error`, last at 05:50:58Z). Both report `ready=True` now.
  These are Kubernetes recovering during convergence, not the `kubectl rollout
  restart` that run 3 needed twice. The criterion asks for no manual step, and
  there was none. Five restarts of the KServe controller is still a number worth
  keeping rather than rounding away.
- **Three TTFT prober pods were in `Error`, and that is expected.** They ran 8
  to 10 minutes before the check, while the model was still loading its weights,
  so there was nothing to probe. The next pod `Completed` and reported
  `ttft-prober: 0.392332s`. Reading `kubectl get pods` alone would have raised a
  false alarm here.
- **Memory reached 18407 MiB, 77% of the 23.2 GiB Docker was given**, across 66
  pods, measured at 06:03Z with `docker stats` on the three node containers, the
  same method the walkthrough uses. That is a third sample beside 17855 MiB (75%,
  2026-08-19) and 17576 MiB (74%, 2026-08-20 morning), not a correction of
  either. The trend is upward and the remaining headroom is not large.

**What this run does NOT settle.** `docs/07-why-gitops.md` owes the wall-clock
time of `task local:down && task local:up && bats tests/`. This run was
`down && up` with no test suite, so 17m09s is a lower bound for that number and
not the number. The marker stays.

The three runs before it are kept below, because the defects they found are the
reason run 4 was clean.

**Run 1 failed.** It was the first time the pull path had ever run, on a cluster
created from empty. Seven defects came out of that one run, and none of them was
visible from the imperative path. `docs/deployment-walkthrough.md`, section "The
pull-based path", is the account. Two of the seven are worth naming here:

- The old final command of `task local:up` waited only on an Application's
  health status, and an Application that failed to read its git path still
  reports `Healthy`. It exited 0 in one second on a cluster where nothing had
  been deployed. `clusters/local-kind/wait-for-sync.sh` replaces it.
- Argo CD applies client-side by default, which writes each manifest into a
  262144-byte annotation. Five of the fifteen charts here ship CRDs larger than
  that, so KServe, Kyverno, Kuadrant, the observability stack, and KEDA all
  failed. `helm install` never writes that annotation, which is why the
  imperative path installs the same charts without complaint.

Run 3 is the one to read, and it is the reason this criterion was written as
"not settled" rather than "fails" until run 4 replaced it. It exited **0**. All sixteen Argo CD
Applications were `Synced` and `Healthy` in three consecutive samples. And the
first request was:

```
GET /v1/models with no token  ->  HTTP 200
```

The Kuadrant operator had started before the Gateway API CRDs existed, caches
that, and refuses every policy until it is restarted by hand - it says so in its
own status message. Nothing crashed, so nothing restarted it. Then a second
manual restart was needed, of the gateway itself, because Kuadrant enforces
through a Wasm module Envoy fetches from a remote registry and that fetch is
configured to fail closed. After both restarts the path was correct: 401 with no
token, 401 with a forged one, 200 with a Keycloak JWT.

Two manual restarts is not none, and this criterion asks for none. `task
local:up` now ends with `clusters/local-kind/verify-serving.sh`, which asserts
the request path rather than the Application list, so a run cannot report success
over an open gateway again. `platform/25-kuadrant/gwapi-wait.yaml` is a PreSync
hook that stops the ordering problem at its source.

Run 2 is worth reading too. It got the whole way to a working service:

```
GET /v1/models, no token                 -> HTTP 401
GET /v1/models, JWT from Keycloak        -> HTTP 200, serving ornith-9b
POST /v1/chat/completions, stream: true  -> 67 data chunks, terminates with [DONE]
```

with both `InferenceService` objects `READY=True`, this repository's three
admission policies installed and enforcing, and 13 of 16 Argo CD Applications
Synced. So the substance of the criterion held. The criterion did not, because
`task local:up` exited 201 on three Applications that could never go green: an
HPA with no metrics-server behind it, a deprecated annotation KServe rewrites,
and defaults the API server fills in. Six more defects came out of that, on top
of run 1's seven.

All thirteen fixes are in. The re-run that would settle this criterion is owed.

Criterion 9 does not hold, and the whole history fits in one table. Pushing a
branch never triggered CI, because the workflow runs on `pull_request` and on
`push` to `main`. Fast-forwarding `main` triggered the first CI run this repository ever
had. Read with `gh run list --branch main`, 2026-08-20:

| Run | Time (UTC) | Commit | Result |
|---|---|---|---|
| 32315429345 | 2026-08-19 23:57 | `f6ae1e4` | failure |
| 32320604250 | 2026-08-20 01:19 | `adcc293` | failure |
| 32320742653 | 2026-08-20 01:21 | `e62976f` | failure |
| 32323568376 | 2026-08-20 02:08 | `fbb8208` | **success** |
| 32324040807 | 2026-08-20 02:16 | `35f42df` | **success** |
| 32324328098 | 2026-08-20 02:21 | `0a4bef5` | **success** |
| 32326772197 | 2026-08-20 03:02 | `891b255` | **success** |
| 32336384415 | 2026-08-20 05:38 | `b5b2976` | **failure** |
| 32338396051 | 2026-08-20 06:07 | `0268848` | **failure** |

Nine runs: three red, four green, two red. The runner is arm64, which the
criterion asks for: `Image: ubuntu-24.04-arm`, image release
`ubuntu24-arm64/20260817.96`, read out of run `32326772197`'s own log rather than
out of the workflow file.

**The last two failures are the reason this criterion no longer holds, and they
are worth reading carefully.** Both were triggered by documentation-only commits,
which cannot break a cluster job. In both, `lint`, `policy`, and `smoke` passed
and only `observability` failed, and the two failed for different reasons:

| Run | Failure | Why it is a race, not a defect |
|---|---|---|
| `32336384415` | Tests 12 and 13, `prometheus is scraping the predictor` and `normalised llmstack series exist`, both on `[ "$output" -ge 1 ]` | Test 14, `raw engine series backing the normalisation still exist`, **passed in the same run**, as did test 17 on the gateway. The raw series were there and the recording rules had not produced their output yet. 22 of 24 tests passed |
| `32338396051` | The `Deploy the CI model` step: `failed calling webhook "servingruntime.kserve-webhook-server..."`, `Internal error occurred` | The KServe admission webhook was not serving yet when the step applied the model. Nothing waits for it |

Neither is a platform failure. Both are the same class the CI section already
warns about: a step that assumes something is ready without waiting for it. They
are recorded here rather than retried until green, because a flaky job is a
finding and a green retry would hide it.

**What this cost.** Two commits of this repository asserted that criterion 9
holds. It did, on the four samples taken. It stopped holding on the next push,
and the claim was written in a form that four samples could not support. The fix
is not to re-run CI until it is green; it is to stop writing "holds" from a
sample that small.

**What the three red runs were, because the failures matter more than the
count.** `lint` and `policy` passed in all of them. The other two jobs each
built a real `kind` cluster and installed the whole platform successfully, then
failed in the test suites: one test asserted on output that `kubectl run --rm`
does not reliably produce, and one unbounded loop hung a job for 39 minutes
until its own timeout killed it. Both are fixed. **Neither was a platform
failure**, and that distinction is why the runner size was never the problem.

Criterion 2 is met with one caveat recorded in
`docs/deployment-walkthrough.md`: `tests/contract/01-openai-api.bats` passes 4 of
5, and the failing one is about this model being a reasoning model, not about the
API contract.

### Measurements still owed

Every owed number is marked at the place it belongs, not in a central list, so
it cannot drift away from the claim it qualifies. Find them all with:

```
git ls-files -z | xargs -0 grep -n '\*\*Unmeasured (20'
```

which returned **15** on 2026-08-19, across 12 files. Each marker names the
command that settles it.

**Re-measured 2026-08-20 against tracked files: 18 markers across 14 files.**
The 15 above is 2026-08-19's number, and it was quoted forward for a day. That
is the one thing this section exists to forbid. Run the command; do not read the
last number somebody wrote here.

It returned 14 earlier the same day. The twelfth file is
`docs/deployment-walkthrough.md`, and its marker owes the one number the run could
not produce: the `max_tokens` at which this model emits `content` rather than only
`reasoning_content`. 512 was not enough.

The command counts tracked files, and that is the point. It used to be
`grep -rn ... --exclude-dir=.git --exclude-dir=docs/superpowers`, which did not
work: `--exclude-dir` matches a directory's basename, never a path, so
`docs/superpowers` excluded nothing. That form also missed `.superpowers/` and
`docs/UNVERIFIED.md`, both ignored by `.gitignore`. Run verbatim on 2026-08-19
it returned 52 rather than 14. The published number was always the tracked-file
number; only the command was wrong. A fresh clone hides this, because a clone
has none of those three paths.

`Untried` is the companion marker, for a mechanism nobody has exercised rather
than a number nobody has measured. Find those with:

```
git ls-files -z | xargs -0 grep -nE 'Untried \(20[0-9]{2}-'
```

which returned **12** on 2026-08-20, across seven files: this one,
`platform/10-istio/telemetry.yaml`, `platform/12-kyverno/install.sh`,
`tests/contract/01-openai-api.bats`, two in
`platform/30-observability/tempo.yaml`, two in
`tests/smoke/05-observability.bats`, and four in `.github/workflows/ci.yml`.

**Re-measured 2026-08-20, later the same day, after the documentation was
restructured. Still 12, still across seven files, but not the same seven.**
`README.md`'s marker went, because the rewritten README no longer carries a
"Getting started" section claiming its own commands are untried; the criteria
table and this file say that instead. `docs/sad/07-deployment-view.md` brought
one, because no GPU cluster has ever been created from this repository. Both
files are named in the list above only in the sense that "this one" now means
`docs/STATUS.md` rather than `README.md`.

**That list was wrong in both of its forms, and re-measuring is what showed it.**
The prose above names seven files including this one and omits
`docs/sad/07-deployment-view.md`. The block that used to sit here named seven
including `07-deployment-view.md` and omitted this one. Neither set is the real
one. Re-measured 2026-08-20 against tracked files, there are **16 markers across
eleven files**:

```
.github/workflows/ci.yml                       4
docs/STATUS.md                                 1
docs/sad/07-deployment-view.md                 1
platform/10-istio/telemetry.yaml               1
platform/12-kyverno/install.sh                 1
platform/30-observability/podmonitor.yaml      1
platform/30-observability/recording-rules.yaml 1
platform/30-observability/tempo.yaml           2
security/oidc/tokenratelimitpolicy.yaml        1
tests/contract/01-openai-api.bats              1
tests/smoke/05-observability.bats              2
```

It read 13 across eight files earlier the same day, before R13, R14, and R18
were fixed. Each of those three fixes brought a marker, because each changes a
mechanism that no run has exercised yet. The count rising here is the shape this
is supposed to take: a fix that cannot be verified offline owes a marker rather
than a claim.

That paragraph used to add that the tracked-file count was **11**, because
`docs/sad/` was not yet committed, and that committing it would make the two
numbers agree. `docs/sad/` **is** committed now (`git ls-files docs/sad/`), so
there is one number rather than two, and it is 13 rather than 12. The
`Unmeasured` command moved the same way: it read **16** across 13 files counting
the then-uncommitted documents and **15** across 12 counting tracked files only,
and against tracked files on 2026-08-20 it reads **18 across 14**. That one did
not move when R13 to R18 were fixed, because those fixes owe an exercised
mechanism rather than a number.

It was 13 across eight files earlier the same day. The one that went is
`docs/deployment-walkthrough.md`'s, which asked whether Argo CD applies the
CoreDNS manifest cleanly. Running the pull path settled it: the ConfigMap is
`Synced`, its explicit `namespace: kube-system` beat the Application's
`istio-system` destination, `Prune=false` survived, and `llm.localtest.me`
resolved to the gateway ClusterIP from inside a pod.

It moved three times across two days, and every move is the shape this is
supposed to take rather than a regression. From 10 to 11 when `actions/checkout`
went v4 to v7, because v7 needs the node24 runtime and no local command can prove
these runners have it. To 12 when the stack was first run layer by layer, because
the CoreDNS manifest that run produced had only ever been applied by hand. To 13
on 2026-08-20, when a review pass replaced two claims that had been asserted
without a mutation to back them, in `tempo.yaml` and the contract suite.

The same two days RETIRED three markers that running settled, and one that was
simply wrong. `tempo.yaml` no longer wonders whether Tempo 3.0.3 starts, because
it does. `podmonitor.yaml` no longer wonders whether the gateway pod declares
port 15020 or whether Prometheus scrapes it, because both were observed; its
second marker had also contradicted `docs/deployment-walkthrough.md` outright,
and the walkthrough was right.

The count rising is the expected shape of this work, not a regression. Every
component added since 2026-08-19 has been written and never run, so each one
brings its own marker naming the command that would settle it.

A third marker form was introduced and retired on the same day, 2026-08-19, when
the stack was first run layer by layer on a real cluster:

```
git ls-files -z | xargs -0 grep -n '\*\*BLOCKED (20'
```

which returns **0**. `BLOCKED` is for something that was tried, failed, and is
understood: it carries the exact error and the upstream source lines that explain
it. It is deliberately not `Untried`, because trying it is what produced the
finding. The one instance was the model layer, and it lasted a few hours;
`models/ornith-9b/overlays/local/patch-resources.yaml` now carries the resolved
record instead. Keep the form available: it is the honest marker for a finding
that is understood but not yet fixed.

The date digits in that pattern are not decoration. Without them the pattern
matches the line that documents the marker form, `CLAUDE.md:199`, so it reports
14 instead of 13. It cited `CLAUDE.md:176` until 2026-08-20, which is a different
bullet in the same section: that line is the "a number without the date it was
measured is invalid" rule, not the marker form. A citation that resolves and does
not hold is the exact defect this section exists to warn about. The `Unmeasured` pattern above dodges the same trap a
different way, by requiring the `**` a real marker carries.

This paragraph said "reports 7" until 2026-08-19. That number was never
producible: dropping the digits can only ADD matches, so a number below the real
count was wrong in direction as well as in size. Re-measured by diffing the two
greps over tracked files, which shows exactly one added line.

Two details in that pattern are deliberate, and both were found by running it
rather than by reasoning about it. It matches the marker form `**Unmeasured (`
rather than the bare phrase, so it does not count this paragraph or any other
prose that mentions the pattern it counts. And it requires a real date, `(20`,
so it skips the rule that defines the marker in `CLAUDE.md`, which is written
`(<date>)`.

### An accepted gap, not an owed measurement

llama.cpp emits no traces at all. The engine contract requires an OTLP traces
endpoint, and llama.cpp's server documentation mentions neither OTLP nor
OpenTelemetry.
[ADR 0005](adr/0005-two-runtimes-one-control-plane.md), lines 58 to 64,
records this as a cost found while implementing and not anticipated when the
decision was taken. The OTel Collector is deployed anyway, with a receiver no
engine feeds. The practical effect is that time to first token cannot come
from spans, and is measured instead by the client-side prober in
`platform/30-observability/ttft-prober-cronjob.yaml`. Nothing is owed here
short of adding vLLM in phase 2.

## What is proven, and the sharp limit on it

Nothing that requires a cluster. What holds without one:

- Every `helm install --dry-run=client` and `helm template` this repository's
  install scripts and Argo CD Applications were checked against **renders
  without error**.
- Every `kustomize build` across every overlay renders without error.
- Every CRD field this repository's manifests use was confirmed against the
  pinned chart's own rendered schema, not memory.
- The real `kyverno` CLI confirms the admission policies reject exactly what
  `tests/smoke/11-policy.bats` asserts they reject (`policy/tests/`), and the
  fixtures were mutation-checked: reverting the policy under test makes the
  corresponding case fail.
- Every shell script parses under bash 3.2.57 (`/bin/bash -n`, the version
  macOS ships, which `shellcheck` alone does not stand in for).
- `actionlint` reports the CI workflow clean.
- **Every pinned image digest resolves to a `linux/arm64` image, and every tag
  written beside it belongs to that digest.** Checked 2026-08-19 against
  ghcr.io, quay.io, and Docker Hub over HTTPS, with no Docker daemon: for each
  entry the tag's index was fetched and the pinned digest confirmed as one of
  its children, then the digest's own config blob was read for its `os` and
  `architecture`. All five report `linux/arm64`. This is the substance of
  `tests/contract/03-images.bats`'s first test, which still cannot run here
  because `require_arm64` calls `docker buildx imagetools inspect`. The
  registry answered the same question by a different route. That is not the
  same as having run the test.

**A passing dry-run does not prove the rendered values are the intended ones.**
It proves the chart rendered. `CLAUDE.md`'s evidence rules record the two real
defects that survived several review rounds on this branch for exactly this
reason.

