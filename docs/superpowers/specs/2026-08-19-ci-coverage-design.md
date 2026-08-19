# Proving the stack in CI, not on the development machine

Date: 2026-08-19.

## Status

Approved in conversation on 2026-08-19. **Implemented the same day, in commit
`7e32940`.** Nothing in it has run against a cluster.

**Every line number in this document refers to the state before `7e32940`.**
The change moved most of them. Several cited passages no longer exist, because
this design replaced them: `.github/workflows/ci.yml:150` said "The runner has
4 vCPU", and `:112` said "seven aliases". Resolve any citation here with
`git show 7e32940^:<file>`, not against the working tree.

That is a property of a design document, not a defect in it. A design states
what it found and what it intends to change. Rewriting its citations after the
fact would erase the before state it exists to record.

Supersedes `2026-08-19-first-run-measurement-design.md`, which planned the same
proving work on the development machine. The owner of that machine declined to
give Docker Desktop 24 GiB. Nothing in this design runs on that machine.

## Why this exists

`CLAUDE.md` states this repository is code-complete and unrun. That is not
quite true of everything: `.github/workflows/ci.yml` already creates a real
`kind` cluster and runs six suites against a real model.

The gap is narrower and sharper than "nothing has run". Six of the thirteen
smoke suites have never run anywhere, on any machine.

| Suite | Runs today | Why not |
|---|---|---|
| `01-wave0`, `02-gateway`, `03-identity`, `04-kserve`, `06-auth-quota`, `tests/contract/` | smoke job | |
| `00-cluster` | nowhere | No reason. The CI cluster already has three nodes. |
| `11-policy` | nowhere | No Kyverno installer exists. |
| `05-observability` | nowhere | CI installs no Prometheus. |
| `10-gitops` | nowhere | Needs Argo CD with every Application Healthy. |
| `07-autoscaling`, `08-availability`, `09-bench`, `12-recovery` | nowhere | Need extra replicas, node drains, or sustained load. |

This design closes three of those six, on GitHub's hardware, and states plainly
why the other three stay open.

## Two defects this work fixes

**1. `platform/12-kyverno/install.sh` does not exist.**

`CLAUDE.md` states the convention: every platform layer exists twice, once as
`platform/NN-*/install.sh` and once as an Argo CD Application in
`clusters/local-kind/apps/`. Kyverno exists only as
`clusters/local-kind/apps/12-kyverno.yaml`. There is no imperative path.

The consequence is that CI cannot install Kyverno, so `tests/smoke/11-policy.bats`
runs nowhere, so the three policies in `policy/` have never guarded a live
namespace. `task policy` runs `kyverno test policy/tests`, which evaluates
fixtures, not admission.

**2. The `kyverno` Helm repo alias is missing from every list that names the
aliases.**

`Taskfile.yml` `helm:repos` adds seven aliases: jetstack, istio, kedacore,
prometheus-community, open-telemetry, kuadrant, argo. `prereqs/preflight.sh:21-28`
checks those same seven. Neither includes kyverno.

This is a regression against the original plan.
`docs/superpowers/plans/2026-08-17-phase-1-local-stack.md:144` names
`helm repo add kyverno https://kyverno.github.io/kyverno`. It was dropped in
implementation.

Verified 2026-08-19: `curl -sI https://kyverno.github.io/kyverno/index.yaml`
returns HTTP 200, and `yq -r '.entries.kyverno[].version'` on that index
contains `3.8.2`, which is the version both `versions.yaml` `charts.kyverno`
and `clusters/local-kind/apps/12-kyverno.yaml` `targetRevision` name.

Five files state the number seven and must change together: `Taskfile.yml:42`,
`Taskfile.yml:47`, `prereqs/preflight.sh:21`, `CLAUDE.md:27`, and
`.github/workflows/ci.yml:112`. A sixth, the 2026-08-17 design document at line
427, records a dated measurement of seven URLs and is left alone, because
editing a dated measurement to match today would destroy the record.

## What changes

### Change 1: run `00-cluster.bats` in the smoke job

Add it to the existing `bats` invocation. No new install. The cluster already
has three nodes, because `.github/workflows/ci.yml:84` passes
`prereqs/kind-cluster.yaml` to `helm/kind-action@v1`.

This suite also asserts `versions.yaml` has no empty pins, which the `lint` job
already checks by another route. That overlap is accepted, not removed.

### Change 2: add Kyverno, and prove the policies live

1. Write `platform/12-kyverno/install.sh`, following the shape of
   `platform/40-keda/install.sh`: read the chart version from `versions.yaml`,
   `helm upgrade --install`, `--wait`.
2. Apply `policy/*.yaml` from the same script. Not `policy/`. The glob matters:
   `.github/workflows/ci.yml` already records that Kyverno CLI v1.18.2 loads
   zero rules from the directory form, because `policy/` also holds a README
   and a subdirectory.
3. Add `platform/12-kyverno/README.md`, because every other layer has one.
4. Add the `kyverno` alias to `Taskfile.yml` `helm:repos` and to the
   `preflight.sh` loop, and correct the count in the five places named above.
5. In the smoke job, install Kyverno **before** the model deploy, and add the
   `kyverno` repo to that job's deliberate subset of aliases.
6. Add `tests/smoke/11-policy.bats` to the smoke job's `bats` invocation.

**This change can turn the smoke job red, and that is the point.** With Kyverno
admission-live and installed before `kustomize build models/ornith-9b/overlays/ci
| kubectl apply -f -`, the CI model must satisfy all three policies for the
first time. If it does not, the job fails and we have found a real defect.

> **Untried (2026-08-19):** whether the CI overlay satisfies
> `disallow-floating-tags`, `require-labels`, and `require-resource-limits`
> under live admission. It has only ever been checked by `kyverno test
> policy/tests` against fixtures, which is a different thing.

### Change 3: add an `observability` job

A separate job with its own cluster, so a failure here does not hide a smoke
failure.

It installs what the smoke job installs, plus
`platform/30-observability/install.sh`, plus the CI model. It runs
`tests/smoke/05-observability.bats` only.

It does not install KEDA, Argo CD, or Kuadrant. `05-observability.bats` needs
Prometheus, the OTel Collector, and a predictor emitting `llamacpp:*` series.
It needs none of those three.

> **Untried (2026-08-19):** whether kube-prometheus-stack, the OTel Collector,
> Pushgateway, and one replica of the 0.49 GB CI model fit on a
> `ubuntu-24.04-arm` runner. `.github/workflows/ci.yml:150-152` records that
> the same stack plus KEDA plus **two** replicas did not. This job has one
> replica and no KEDA. If it fails, the failure is the measurement, and it gets
> recorded rather than worked around.

### Change 4: check sync waves without a cluster

`tests/smoke/10-gitops.bats` asserts that every Argo CD Application declares a
sync wave. It reads them from a live cluster, so it runs nowhere.

The same property is readable from `clusters/local-kind/apps/*.yaml` with no
cluster. Add that as a new step in the `lint` job, and as a new task in
`Taskfile.yml`.

This is an addition, not an edit. `tests/smoke/10-gitops.bats` is not changed.
The two checks assert the same property about two different things: one about
the files in git, one about the objects in a cluster. Only the first can run
today.

### Change 5: make CI record its own size

Add a first step to each cluster job that prints `nproc`, `free -h`, and
`df -h`.

`.github/workflows/ci.yml:150` states "The runner has 4 vCPU" as a bare
comment. This turns it into a dated measurement in the run log, and it gives
the memory figure, which nobody has recorded.

### Change 6: rewrite the exclusion comment and update `docs/UNVERIFIED.md`

The comment at `.github/workflows/ci.yml:150-155` names four excluded suites as
a group. Rewrite it to name each remaining excluded suite with its own reason:

| Suite | Reason it stays out |
|---|---|
| `07-autoscaling` | Drives the predictor to three replicas. |
| `08-availability` | Needs two replicas on separate nodes, plus a node drain. |
| `09-bench` | Needs sustained load. |
| `12-recovery` | Deletes and rebuilds namespace `llm` under Argo CD. |
| `10-gitops` | Test 1 requires every Application Healthy, which is the whole stack. Test 3 is already `skip`ped in the file. |

Record the same in `docs/UNVERIFIED.md`.

## What stays unproven, stated plainly

- **The 5.6 GB Ornith-9B model.** CI proves the 0.49 GB Qwen model. Nothing
  here runs the real one.
- **Autoscaling, availability, benchmarks, and recovery.**
- **`10-gitops` test 1**, every Application Synced and Healthy.
- **Any number about the development machine.** Nothing in this design measures
  it.

An option named but not chosen: GitHub sells larger runners. They cost money
and could carry the 9B model. This design does not use them.

## How we know it worked

The evidence is the CI run itself, and it is dated by the run.

1. The smoke job runs eight suites plus `tests/contract/`, up from six.
2. The smoke job log shows Kyverno installed and the three policies applied.
3. The observability job either passes `05-observability.bats` or fails with a
   recorded reason.
4. The lint job fails if any Application file loses its sync wave.
5. Each cluster job log opens with the runner's CPU, memory, and disk.

## Verification available before pushing

No cluster is needed for these, and they are the only checks that can pass
before CI runs:

```
task lint
task policy
/bin/bash -n platform/12-kyverno/install.sh
actionlint .github/workflows/ci.yml
task --list
```

`task --list` matters because `CLAUDE.md` records that go-task 3.53.1 breaks
the whole file on a `: ` inside a command string.

## What this design does not do

- It does not change any replica count, resource request, model, or engine.
- It does not change the `kind` node count or the container runtime.
- It does not weaken a policy or narrow a test to make a job green.
- It does not add Open WebUI, Tempo, Loki, or a database for Keycloak. Those
  remain deferred.
