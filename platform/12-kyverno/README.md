# 12 Kyverno

Sync wave 1.

Installs the policy engine and applies the three `ClusterPolicy` objects in
`policy/`. Wave 1 puts it ahead of KServe (wave 2) and the model overlay
(wave 4), because a policy that arrives after the workload it governs has
governed nothing.

The policies themselves live in `policy/`, not here. This directory installs
the engine and applies them, the same split `platform/40-keda/` uses for the
`ScaledObject` it does not own.

## Why this directory was added late

Until 2026-08-19 Kyverno existed only as
`clusters/local-kind/apps/12-kyverno.yaml`. It was the one platform layer with
no imperative half, which breaks the convention `CLAUDE.md` states.

The cost was not cosmetic. CI installs platform layers by running their
`install.sh` scripts, so with no script there was no way to get Kyverno into a
CI cluster. `tests/smoke/11-policy.bats` therefore ran nowhere, and the three
policies had never rejected anything at admission on any cluster.

`task policy` was, and still is, the only check that runs. It runs
`kyverno test policy/tests` against synthetic fixtures. That proves the rules
match what they claim to match. It does not prove that admission is wired up,
that the webhook answers, or that this repository's own manifests survive it.

## Two copies to keep in step

`clusters/local-kind/apps/12-kyverno.yaml` carries `targetRevision: 3.8.2`
written in literally, because an Argo CD Application cannot read
`versions.yaml`. This script reads `charts.kyverno` from `versions.yaml`.
Changing the version means changing both.

The Application also lists `policy/` as a second source, so Argo CD applies the
same three files this script applies.
