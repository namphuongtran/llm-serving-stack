# First run on real hardware: design

Date: 2026-08-19.

## Status

Approved in conversation on 2026-08-19. Not yet executed. No command in this
document has been run.

## Why this exists

`CLAUDE.md` states that this repository is code-complete and unrun. No
manifest, script, or test has been observed against a live cluster. Every
number in `docs/` is either absent or marked `Unmeasured`.

This design covers one thing: the first run of `task local:up` on real
hardware, with the real model, and what we write down afterwards.

The output of this work is evidence, not features. No feature is added here.

## What "done" means

The user chose the demanding target on 2026-08-19: the full stack, every
layer, and real inference from the 5.6 GB Ornith-9B model. Not a reduced
model, and not the delivery path alone.

Real inference is already asserted by the existing suite. It does not need a
new test. `tests/contract/01-openai-api.bats` asserts that `POST
/v1/chat/completions` returns a non-empty message, that streaming returns more
than one chunk and terminates with `[DONE]`, and that the response reports
token usage.

## What is on this machine

Read on 2026-08-19, on the machine `versions.yaml` `meta.machine` describes as
"Apple M4, arm64, 32 GB".

| Fact | Value | Command that read it |
|---|---|---|
| Physical memory | 32.0 GB | `sysctl -n hw.memsize` |
| Logical CPUs | 10 | `sysctl -n hw.ncpu` |
| Free disk, internal volume | 304 GiB | `df -h /System/Volumes/Data` |
| Docker Desktop | installed at `/Applications/Docker.app`, daemon not running | `docker context ls`, `docker version` |
| Docker VM disk | `Docker.raw`, sparse, 460 GB ceiling, 37 GB used | `ls -lh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` |
| Rancher Desktop, OrbStack, colima, k3d | none installed | `ls -d /Applications/...`, `command -v` |
| Tools `preflight.sh` requires | all nine present. `kind` 0.32.0, `task` 3.53.1, `yq` v4.53.3, `jq` 1.7.1, `bats` 1.14.0 | `command -v` and `--version` on each |

`kind` 0.32.0 is the version whose release notes `versions.yaml`
`kubernetes.kind_node` quotes for its node image pin. `task` 3.53.1 is the
version `CLAUDE.md` warns about for the `: ` parsing trap.

## The arithmetic that shapes the plan

Declared memory requests, read from the manifests on 2026-08-19. The predictor
sizing is `runtimes/llamacpp-arm64/servingruntime.yaml:74-75`, which requests
8Gi and limits 12Gi.

The local overlay runs the 9B model at two replicas, not one.
`models/ornith-9b/overlays/local/patch-resources.yaml:8` sets `minReplicas:
2`. `models/ornith-9b/overlays/local/scaledobject.yaml:31-32` sets
`minReplicaCount: 2` and `maxReplicaCount: 3`.

| Workload | Replicas | Request each | Total |
|---|---|---|---|
| `ornith-9b` predictor | 2 | 8 Gi | 16 Gi |
| `fallback-small` predictor | 1 | 1 Gi | 1 Gi |
| Keycloak | 1 | 512 Mi | 512 Mi |
| Prometheus | 1 | 512 Mi | 512 Mi |
| OTel Collector | 1 | 128 Mi | 128 Mi |
| KEDA | 1 | 128 Mi | 128 Mi |
| Pushgateway, TTFT prober, gateway helper, fetch-weights init containers | | | about 192 Mi |
| **Declared total, steady state** | | | **about 18.4 Gi** |

Two gaps in that table, stated plainly.

First, it counts only what this repository declares. cert-manager, the four
Istio charts, KServe, Kuadrant, Kyverno, Argo CD, Grafana, kube-state-metrics,
node-exporter, and the Prometheus operator take chart defaults that nobody has
read. Their total is unknown.

Second, a request is not usage. llama.cpp maps a 5.6 GB file. What it actually
resides at is unknown.

> **Unmeasured (2026-08-19):** the resident memory of this stack at steady
> state. Run `docker stats --no-stream` against the three kind node containers
> once the cluster is up, and record the sum.

`tests/smoke/07-autoscaling.bats` drives the predictor above two replicas on
purpose. At three replicas the predictor requests alone are 24 Gi. That is the
whole VM allocation named in "Setup" below, with nothing left for the platform,
the three kubelets, or the VM kernel. So run 2 is expected to be tight at best.

`.github/workflows/ci.yml:150-152` already records the same shape of problem
on a smaller machine:

> The runner has 4 vCPU, so the observability, autoscaling, availability, and
> benchmark suites are deliberately excluded here: kube-prometheus-stack plus
> KEDA plus two replicas of even the 0.5B CI model do not fit alongside
> everything the smoke job above already installs

Two replicas of a 0.5 GB model did not fit there. This run asks for two
replicas of a 5.6 GB model.

## Two traps this design plans around

**Trap 1: kind nodes are expected to over-report memory capacity.** Each kind
node is a container inside one Linux VM. A container with no memory limit
reads the host's memory, so each of the three nodes is expected to report the
whole VM's memory as its own capacity. If that holds, the scheduler believes
there is roughly three times the memory that exists. Pods will be placed, not
left `Pending`, and the Linux out-of-memory killer inside the VM is what stops
them. So the expected failure symptom is `OOMKilled`, not `Pending`.

> **Unverified (2026-08-19):** that kind reports VM memory per node on this
> setup. Check it at stop 3 by comparing `kubectl get nodes -o
> jsonpath='{.items[*].status.capacity.memory}'` against `docker info --format
> '{{.MemTotal}}'`. If the three node capacities each equal the VM total, the
> trap is real. If they do not, this paragraph is wrong and must be rewritten.

**Trap 2: requests will not protect the run.** This follows from trap 1. Do not
read a successful schedule as proof that the memory fits.

## Decision: kind on Docker Desktop, not k3s

Recorded because the question was raised on 2026-08-19 and settled.

k3s is lighter than kubeadm. The weight it saves is on the control plane. The
weight blocking this run is the predictor, which requests 16 Gi across two
replicas. That is 87 percent of the 18.4 Gi declared total, and k3s does not
change it.

Three further points.

1. k3s does not require Rancher Desktop. k3d runs k3s inside Docker, the same
   way kind runs kubeadm inside Docker. The real comparison is kind against
   k3d.
2. On macOS both kind and k3d run inside a Linux VM. That cost is paid either
   way.
3. Switching costs CI parity. `.github/workflows/ci.yml:82` uses
   `helm/kind-action@v1`. If local runs k3d and CI runs kind, a local pass
   stops predicting a CI pass. It would also change
   `prereqs/kind-cluster.yaml`, `Taskfile.yml:76,78,83`, and
   `tests/contract/03-images.bats:26-38`, and it would require disabling the
   Traefik ingress k3s installs by default.

> **Unmeasured (2026-08-19):** the memory either kind or k3d uses on this
> machine. Neither has ever run here. Any claimed saving would be invented.

**Decision rule.** If run 1 below succeeds, the k3s question is closed and no
change is made. If it fails on memory, record the shortfall, then compare it
against a measured k3d saving before changing anything.

## Setup

No repository file changes before the run. The point of the run is to find out
what is true. Changing code first would mean guessing.

| Setting | Value | Reason |
|---|---|---|
| Docker Desktop memory | 24 GiB | `prereqs/preflight.sh:17` requires at least 19. 24 GiB is the largest slice that leaves 8 GB for macOS. |
| Docker Desktop CPUs | 8 | `prereqs/preflight.sh:16` requires at least 8. The machine has 10. Two stay with macOS. |
| Docker Desktop disk | default | 304 GiB free on the internal volume. `Docker.raw` is sparse with a 460 GB ceiling. |
| kind cluster | unchanged, three nodes | `tests/smoke/00-cluster.bats:3` asserts three nodes exist. `tests/smoke/08-availability.bats:14` asserts two replicas land on different nodes. One node breaks both. |
| Model | unchanged, Ornith-9B Q4_K_M, 5.6 GB | This is the chosen target. |

## Run order

Two runs. Run 2 starts only if run 1 passes. Stop at the first failure and
record it. Do not work around a failure inside the run, because the failure is
the finding.

### Run 1: steady state

| Stop | Action | Pass condition |
|---|---|---|
| 1 | Start Docker Desktop with the settings above | `docker info` reports at least 8 CPUs and at least 19 GiB |
| 2 | `task helm:repos`, then `task preflight` | preflight prints `ok` |
| 3 | `task local:cluster` | three nodes Ready. Also record node capacity against VM total, to settle trap 1. |
| 4 | `task local:up` | every Argo CD Application reports Healthy inside the 30 minute wait |
| 5 | Suites below | pass and fail counts per file |

Run 1 suites: `tests/smoke/00-cluster.bats`, `01-wave0`, `02-gateway`,
`03-identity`, `04-kserve`, `05-observability`, `06-auth-quota`, `10-gitops`,
`11-policy`, and all of `tests/contract/`.

Stop 3 also proves the pinned `kindest/node` digest pulls on arm64, which
`versions.yaml` states plainly was never confirmed against a running cluster.

Stop 4 includes the 5.6 GB model download, which happens in the
`fetch-weights` init container inside the 30 minute wait
(`Taskfile.yml`, `local:up`).

### Run 2: under load

Only if run 1 passes. Suites: `tests/smoke/07-autoscaling.bats`,
`08-availability`, `09-bench`, `12-recovery`.

These push the predictor to three replicas. Run 2 failing is an expected
outcome, not a defect.

## Measurements

Every measurement is recorded with the date it was taken and the command that
produced it, per the evidence rules in `CLAUDE.md`.

| What | Command |
|---|---|
| Real memory per node | `docker stats --no-stream` on the three kind node containers |
| Node capacity as the scheduler sees it | `kubectl get nodes -o jsonpath='{.items[*].status.capacity.memory}'` |
| Memory by namespace | port-forward Prometheus, then query `sum(container_memory_working_set_bytes) by (namespace)` |
| Wall clock for the whole install | `time task local:up` |
| Model download duration | `kubectl -n llm logs <predictor-pod> -c fetch-weights` |
| Restarts and kills | `kubectl get pods -A`, and `kubectl get events -A --field-selector reason=OOMKilling` |
| Test results | bats output, per file |

`kubectl top` is not used. kind ships no metrics-server, and
`docs/05-why-keycloak.md` already anticipates its absence.

## What changes in the repository afterwards

Only the files the evidence actually reaches.

- `docs/UNVERIFIED.md`, its "Unproven: every dated measurement still owed"
  section.
- `prereqs/preflight.sh`. The 19 GiB floor at line 17 is a guess. A
  measurement replaces it. No disk check exists at all, and this run will show
  what disk the install consumes. Line 17 also disagrees with itself: the test
  is `-ge 19` while the message it prints says "need 20".
- `versions.yaml`. Its `kubernetes.kind_node` comment states that no cluster
  was created and so this is not the image a running cluster reported. Stop 3
  changes that.
- `docs/05-why-keycloak.md` and every other document carrying an `Unmeasured`
  or `Untried` marker this run resolves.
- `CLAUDE.md`, where "code-complete and unrun" stops being true.

## Failure branches

| Symptom | Reading | Action |
|---|---|---|
| Preflight fails on memory or CPU | Docker Desktop did not take the setting | Fix the setting. Not a finding. |
| Pods `Pending` | Real scheduling shortfall | Record the pod and its request. Contradicts trap 1, so rewrite that section. |
| Pods `OOMKilled` | The VM ran out of real memory | Record `docker stats` at that moment. This number decides the k3s question. |
| `fetch-weights` init container fails | The download or its sha256 check failed | Record the log. This is a model pin problem, not a memory problem. |
| `local:up` times out at 30 minutes | An Application never went Healthy | Record which one, and its condition message. |
| Run 1 passes, run 2 fails on memory | The stack works. Scaling does not fit this machine. | Record it as a measured constraint. |

Do not lower `minReplicaCount`, shrink a resource request, or narrow a test to
make a red result go green. `CLAUDE.md` forbids editing a document to make a
checker pass, and the same rule applies to editing a manifest to make a test
pass.

## Open questions this run may settle

**The `cost-saving` overlay disagrees with itself.** Rendering it on
2026-08-19 with `kustomize build models/ornith-9b/overlays/cost-saving` gives
`ScaledObject.minReplicaCount: 0` while `InferenceService/ornith-9b` keeps
`minReplicas: 2`. `models/ornith-9b/overlays/cost-saving/kustomization.yaml`
patches only the ScaledObject.

> **Unverified (2026-08-19):** which value wins on the predictor Deployment,
> and therefore whether this overlay scales to zero at all. This is recorded,
> not fixed. Settle it only if the overlay is actually needed.

## What this design does not do

- It does not add a feature.
- It does not change the engine, the model, the node count, or any replica
  count.
- It does not switch container runtime or Kubernetes distribution.
- It does not make `task token` or `task chat` real. Those remain stubs.
- It does not add Open WebUI, Tempo, or Loki, and it does not add a database
  to Keycloak. Those are three separate pieces of work, raised on 2026-08-19
  and deliberately deferred until something has been observed to run.
