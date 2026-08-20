# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A Kubernetes LLM inference platform, built layer by layer, on `kind` locally and
on GPU nodes later. It is infrastructure only: YAML, shell, and a small Python
benchmark harness. It builds no container image of its own.

Read `README.md` first for what this is, then `docs/STATUS.md` for what has
actually been checked. `docs/STATUS.md`'s "What is unproven" and "What is
proven" sections carry the nine phase 1 acceptance criteria in full, with the
command that settles each one, and the sharp limit on what holds. Those two
sections lived in `README.md` until 2026-08-20 and moved unchanged.

`docs/sad/` is the architecture document: arc42 section order, C4 diagrams,
twelve short files. It introduces no decision. Where it disagrees with an ADR,
it is the bug, and where it disagrees with `docs/STATUS.md` about what has run,
`docs/STATUS.md` wins.

`docs/superpowers/` holds the design spec and the build plan. **It is a local
working document and is not in git** (`.gitignore`), so a clone does not get
it. Where it is cited below, the citation is marked. Anything in it that has to
survive belongs in an ADR (`docs/adr/`), in `docs/sad/`, in `README.md`, or in
a code comment.

## Current state, and why it matters for every claim you write

The repository was **run for the first time on 2026-08-19**. Until that day this
paragraph said "code-complete and unrun", and the build machine genuinely could
not spare the memory Docker needs for `kind`. Raising Docker Desktop's allocation
from 7.7 GiB to 23.2 GiB was the only change that unblocked it.

What that run settles, and what it does not:

- All thirteen layers came up on a 3-node `kind` cluster, and the service
  answered a real request. That run settled two of the nine acceptance criteria.
  Four of nine hold as of 2026-08-20; `docs/STATUS.md` is the count of record.
  The count moved in both directions that day - read it, do not assume it rises.
- It used the **imperative path** (`platform/NN-*/install.sh`), not
  `task local:up`. Two things it needs were applied by hand: the CoreDNS manifest
  and the model overlay.
- `docs/deployment-walkthrough.md` is the account, with a dated number for every
  layer, and `docs/deployment-log.tsv` is the raw log. `tools/step-up.sh` repeats
  the run one layer at a time with a memory guard.

**The pull-based path ran on 2026-08-20**, three times, and CI ran for the first
time the same day. Criterion 1 was settled on run 4, `task local:down && task
local:up` in 17m09s with exit 0 and no manual step. Read "The pull-based path" in
`docs/deployment-walkthrough.md` before touching `clusters/local-kind/`, because
runs 1 to 3 are why run 4 was clean.

- Run 3 **exited 0** with all sixteen Applications `Synced` and `Healthy`, and
  the gateway served `/v1/models` to a caller with no token. Read that sentence
  twice before trusting a green Argo CD anywhere in this repository. The Kuadrant
  operator had started before the Gateway API CRDs existed, caches that, and
  refuses every policy until restarted by hand; nothing crashed, so nothing
  restarted it.
- So `task local:up` now ends with `clusters/local-kind/verify-serving.sh`, which
  asserts the request path: 401 without a token, then 200 with a real JWT. Do not
  weaken that to "not 200" - 503 is the fail-closed case and would satisfy it.
- Run 2 reached a working service through Argo CD but exited non-zero, on
  Applications that could never report Synced or Healthy.
- Eighteen defects came out of those three runs and none was visible from the
  imperative path. The two worth knowing before you edit anything here: Argo CD
  applies **client-side** by default, which writes each manifest into a
  262144-byte annotation, and five of these fifteen charts ship CRDs larger than
  that; and an Application that fails to read its git path still reports
  `health.status: Healthy`, which broke both the acceptance check and sync-wave
  ordering.
- So `.status.health.status` is not evidence that an Application did anything.
  `clusters/local-kind/wait-for-sync.sh` is the check, and it reads sync status,
  counts the children against the directory, and requires every Application green
  in the same sample.
- Criterion 4 moved from untested to **untestable on this engine**: the free tier
  is 500 tokens per 60s window and llama.cpp reports 0.55 tokens per second here,
  which is 33 tokens per window. That is a limits decision, not a test bug.

**The lesson to carry, not just the status.** That run found seven defects which
four separate static review passes over the whole repository had all missed: a
file mode, a bash 3.2 array expansion, two dead label selectors, and three tests
that passed while the thing they named was broken. Rendering is not admission,
admission is not scheduling, and a passing test is not a working system. When you
can run something, run it.

`docs/STATUS.md`'s "What is unproven" section is the tracked account. Update it
whenever you change what is or is not verified. Do not write that something
works because it renders. See "Evidence rules" below.

`docs/UNVERIFIED.md` is a longer working account of the same thing. It is a
local working document and is not in git (`.gitignore`), so do not cite it
from a tracked file, and do not put a fact there that has no tracked home.

## Commands

```bash
task preflight        # tools, Docker CPU/memory, and the eight helm repo aliases
task helm:repos       # add and update every helm repo the install scripts assume
task local:up         # kind cluster -> Argo CD -> root-app -> every layer by sync wave
task local:down       # delete the cluster
task test:smoke       # bats tests/smoke
task test:contract    # bats tests/contract
task lint             # kustomize build every model overlay, reject empty version pins
task policy           # kyverno test policy/tests (no cluster needed)
task bench            # every scenario, into a dated bench/results/ directory
task drill:recovery   # delete namespace llm, let Argo CD rebuild, measure time to first token
task --list-all       # includes the stubs
```

Run one test file: `bats tests/smoke/06-auth-quota.bats`. Run one bats test by
name: `bats -f "<name substring>" tests/smoke/06-auth-quota.bats`.

Run one benchmark scenario: `SCENARIOS=bench/scenarios/01-short.json ./bench/run.sh`.

`task local:status` and `task drill:drain` are stubs. They print what they
would do. Everything else runs a real command.

`task token` and `task chat` are real as of 2026-08-19. `task chat -- "your
prompt"` streams one answer through the gateway, so the request passes the
AuthPolicy and the TokenRateLimitPolicy on its way. `CLIENT=llm-tier-free task
chat` is how you watch the quota cut you off.

### Checks that need no cluster

These are the only checks that can pass today. Run them before you claim a
change is sound.

```bash
task lint
task policy
kustomize build models/ornith-9b/overlays/local
helm template <name> <chart> --version <v> -f <values>   # then READ the rendered output
/bin/bash -n <script>                                    # macOS bash 3.2, not shellcheck
actionlint .github/workflows/ci.yml
```

## Architecture

Request path: client -> Istio Gateway (`istio-system/llm`, Gateway API) ->
HTTPRoute in namespace `llm` -> Kuadrant `AuthPolicy` and
`TokenRateLimitPolicy` -> KServe `InferenceService` predictor pod -> engine
container serving the OpenAI API.

| Directory | Role |
|---|---|
| `platform/NN-*/` | One cluster component per directory, numbered by install order, each with `install.sh` and a README |
| `clusters/local-kind/apps/` | The same components as Argo CD Applications, ordered by `argocd.argoproj.io/sync-wave` |
| `runtimes/<engine>/` | One `ServingRuntime` per engine. No model fact may appear here |
| `models/<model>/base/` | `InferenceService` plus `model.yaml`, the model as a variable |
| `models/<model>/overlays/` | `local`, `ci`, `cost-saving`, `gpu-single`, `gpu-multi` |
| `security/oidc/` | `AuthPolicy` and `TokenRateLimitPolicy` |
| `policy/` | Kyverno policies, plus `policy/tests/` fixtures used by CI and `task policy` |
| `bench/` | `run.sh`, `harness.py`, `summarise.py`, scenarios, dated results |
| `tests/smoke`, `tests/contract` | bats suites, sharing `tests/lib/helpers.bash` |
| `tools/` | Small client scripts a human runs. `token.sh` and `chat.sh` back `task token` and `task chat`. Both source `tests/lib/helpers.bash` for the grant rather than reimplementing it, as `bench/run.sh` already does |

Four boundaries hold the design together. Breaking one is a design change, not
a fix.

1. **The model is a variable.** Changing models touches `models/<model>/` and
   nothing else. A model name must never appear in `runtimes/`.
2. **The engine is swappable.** Everything above the engine is engine
   independent. `tests/contract/` exists to keep it that way.
3. **Metrics are normalised.** Engine series are recorded into an `llmstack:`
   namespace by `platform/30-observability/recording-rules.yaml`. Dashboards,
   alerts, and the KEDA trigger read only `llmstack:*`, never a raw vLLM or
   llama.cpp series name.
4. **Delivery is pull based.** `task local:up` applies exactly two things by
   hand: Argo CD itself, and `clusters/local-kind/root-app.yaml`. Everything
   else arrives as an Argo CD Application.

### Two install paths for the same components

Each platform layer exists twice: as `platform/NN-*/install.sh` (imperative,
used by CI and by hand) and as an Argo CD Application in
`clusters/local-kind/apps/` (declarative, used by `task local:up`). An Argo CD
Application is one git object and cannot read a values file from this
repository, so chart values and image digests are copied inline into the
Application. **Changing a value or a digest means changing both copies.** Grep
for the old string.

### Local engine constraint

`kserve/huggingfaceserver` publishes `linux/amd64` only, and Rosetta 2 does not
implement AVX. So the local engine is llama.cpp on arm64, and vLLM waits for
phase 2. This is why `tests/lib/helpers.bash` carries `require_arm64`, and why
CI runs on `ubuntu-24.04-arm`.

## Conventions

- **`versions.yaml` is the source of truth for every version, digest, and
  chart.** Every entry carries the date it was read and the command that read
  it. Never change a version without updating its `read` date. Known
  duplicated copies: `.github/workflows/ci.yml` writes `kustomize` and
  `kyverno_cli` in literally (it cannot read the file before installing `yq`),
  and Argo CD Applications carry rendered digests.
- **Images are pinned by digest, never by a tag.** `policy/disallow-floating-tags.yaml`
  enforces this in namespace `llm`, including for throwaway test fixtures.
- **Scripts must parse under bash 3.2.57**, the version macOS ships. No
  `mapfile`, no `readarray`, no `${v,,}`. Check with `/bin/bash -n`.
- **No `: ` inside a `Taskfile.yml` command string.** go-task 3.53.1 reads a
  colon followed by a space as command shorthand, even inside quotes, and
  breaks `task --list` for the whole file. Use ` - ` instead.
- Comments in this repository explain *why*, and cite the file, line, or
  command that establishes the fact. Match that density when you edit.
- ADRs in `docs/adr/` are append-only. A changed decision gets a new ADR that
  supersedes the old one. The old one stays.

## Evidence rules

This repository is stricter than the default. The rules are stated in
`README.md` and `docs/STATUS.md`, and enforced throughout the documents.

- **A number without the date it was measured is invalid.** Re-measure. Do not
  quote a number forward.
- **A passing dry-run does not prove the rendered values are the intended
  ones.** It proves the chart rendered. Check a values change by rendering the
  chart and reading the value out of the output, not by reading the values
  file back.

  This is not hypothetical. Two real defects survived several review rounds on
  this branch, and both were found on 2026-08-19 only by reading rendered
  output instead of source:

  - `platform/20-kserve/values-kserve.yaml` set the chart's `gateway` key
    while KServe reads `kserveGateway`. Every dry-run passed. The rendered
    ConfigMap carried a Gateway this repository never creates.
  - `clusters/local-kind/apps/30-observability.yaml` let Argo CD default the
    Helm release name to the Application name. Every dry-run passed. The
    rendered Service was `observability-kube-prometh-prometheus`, not the
    `kube-prometheus-stack-prometheus` that two consumers here name, plus a
    third reference in this file. "Four" was the number written when this was
    recorded and it was never counted; `git grep -l kube-prometheus-stack-prometheus`
    returns three files on 2026-08-19, one of which is this one.
- **Never edit a document to make a checker pass.** Fix the checker, or record
  the finding as real.
- Mark anything not yet observed with `> **Unmeasured (<date>):**` or
  `**Untried (<date>):**`, and name the command that would produce the number.

## CI

`.github/workflows/ci.yml` has four jobs on `ubuntu-24.04-arm`: `lint`,
`policy`, `smoke`, and `observability`. `smoke` and `observability` each create
their own real `kind` cluster and run a deliberate subset of the suites. The
runner is small, so autoscaling, availability, benchmark, and recovery are
excluded on purpose. Each remaining exclusion is named with its own reason in
the workflow itself. Read those comments before you add a step.

**CI is no longer the only place this repository proves things.** That sentence
held while the development machine could not spare the memory for `kind`; on
2026-08-19 it could, and the stack ran locally end to end. Both matter now, and
they catch different classes of defect. Two examples from that day: the KServe
install script died on bash 3.2 locally and CI could never have seen it, because
GitHub runners have bash 5; and the `helm/kind-action` cluster-name default
breaks every suite in CI while the local path is unaffected. Run both.

Six of thirteen smoke suites ran nowhere before 2026-08-19; three of them run in
CI now, and `tools/step-up.sh` plus a local cluster covers more. The CI
workflow's own comments are the tracked account, including four `Untried`
records. The design behind it,
`docs/superpowers/specs/2026-08-19-ci-coverage-design.md`, is a local working
document and is not in git.

**CI first actually ran on 2026-08-20.** Until then nothing had triggered it: the
workflow runs on `pull_request` and on `push` to `main`, and `main` held an
unrelated project, so pushing a branch triggered nothing. Fast-forwarding `main`
started run `32315429345`.

What it settled. `lint` and `policy` pass. Both cluster jobs create a real `kind`
cluster and install the whole platform successfully on `ubuntu-24.04-arm`, so the
runner size is not the problem. Both then failed **in the test suites**, and both
failures were defects in tests rather than in the platform:

- a test asserted on the output of `kubectl run --rm -i`, which kubectl does not
  reliably produce - it falls back to streaming logs when it cannot attach, and
  `--rm` can delete the pod first. It still exits 0.
- an unbounded loop of unbounded `curl` calls hung the `smoke` job for 39 minutes
  until `timeout-minutes: 45` killed it. A count is not a bound when each
  iteration can take arbitrarily long.

The lesson for anything you add here: **give every request a `--max-time` and
every loop a wall clock**, and never assert on the stdout of a `--rm` pod.

The `Record the runner size` step in each cluster job prints `nproc`,
`free -h`, and `df -h`. Quote those, dated by the run, rather than repeating
a vCPU count from a comment.

Note two traps the workflow comments record. `kyverno apply policy/` loads zero
rules because `policy/` also holds a README and a subdirectory: use
`policy/*.yaml`. `platform/12-kyverno/install.sh` avoids the same trap by
applying one file at a time. And applying the policies to rendered model
overlays reports `pass: 0, fail: 0`, because an overlay renders no Pod or
Deployment; `kyverno test policy/tests` is the step that exercises the rules
offline, and the `smoke` job's live Kyverno install is what exercises them at
admission.

## Working notes

`.superpowers/sdd/2026-08-17-phase-1-local-stack/` holds the task briefs,
per-batch reports, and review diffs from the phase 1 build. `progress.md` is
the ledger, including the rulings made where two tasks touched one file. Read
the relevant report before you re-open a decision that looks wrong.

**That directory is not in git**, and was never tracked. `.gitignore` names it
so it stays out of `git status`. So this pointer resolves on the machine the
phase 1 build ran on, and nowhere else. A fresh clone does not get it. When a
decision recorded only there matters to someone else, copy the reasoning into
an ADR, a spec, or a code comment, which are the three places this repository
keeps decisions that have to survive.
