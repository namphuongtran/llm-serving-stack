# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A Kubernetes LLM inference platform, built layer by layer, on `kind` locally and
on GPU nodes later. It is infrastructure only: YAML, shell, and a small Python
benchmark harness. It builds no container image of its own.

Read `README.md` and `docs/superpowers/specs/2026-08-17-llm-serving-stack-design.md`
first. The spec is authoritative for the phase 1 acceptance criteria.

## Current state, and why it matters for every claim you write

The repository is **code-complete and unrun** (as of 2026-08-19). No manifest,
script, or test has been observed against a live cluster. The build machine
cannot spare the memory Docker needs for `kind`.

`docs/UNVERIFIED.md` is the reconciled account of what is unproven. Update it
whenever you change what is or is not verified. Do not write that something
works because it renders. See "Evidence rules" below.

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

`task token`, `task chat`, `task local:status`, and `task drill:drain` are
stubs. They print what they would do. Everything else runs a real command.

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
`README.md` and enforced throughout the documents.

- **A number without the date it was measured is invalid.** Re-measure. Do not
  quote a number forward.
- **A passing dry-run does not prove the rendered values are the intended
  ones.** It proves the chart rendered. Two real defects survived several
  review rounds this way, both recorded in `docs/UNVERIFIED.md`. Check a values
  change by rendering the chart and reading the value out of the output.
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

**CI is where this repository proves things.** The development machine cannot
spare the memory, so every suite that runs at all runs here. Six of thirteen
smoke suites ran nowhere before 2026-08-19; three of them run now. See
`docs/superpowers/specs/2026-08-19-ci-coverage-design.md` and the CI coverage
section of `docs/UNVERIFIED.md`.

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
