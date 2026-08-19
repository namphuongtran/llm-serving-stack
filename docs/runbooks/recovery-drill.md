# Runbook: the recovery drill

## The command

```bash
task drill:recovery
# or directly:
./bench/recovery-drill.sh
```

Deletes the `llm` namespace, waits for every Argo CD Application to report
`Healthy` again, polls `GET /v1/models` through the gateway as a readiness
gate, then issues one streaming `POST /v1/chat/completions` and times the
arrival of its first `data:` chunk.

Two numbers are written to `bench/results/<date>-recovery/result.json`, plus
`summary.md`:

| Field | What it is |
|---|---|
| `seconds_to_first_token` | Namespace delete to the first streamed `data:` chunk. This is the recovery time objective |
| `seconds_to_models_endpoint` | Namespace delete to the first successful `GET /v1/models`. The readiness gate, kept because it is useful, but it is not a token |

Corrected 2026-08-19. The script used to record the `/v1/models` poll time
under the name `seconds_to_first_token`, which measured no token at all:
`/v1/models` answers as soon as the server is listening, before any weight has
been through a forward pass. The name and the measurement now agree.

## The measured number

> **Unmeasured (2026-08-19):** the recovery time itself. No cluster exists in
> this authoring pass (the human's machine cannot spare the memory Docker
> needs for a `kind` cluster alongside this stack), so `./bench/recovery-drill.sh`
> has not been run. Once a cluster exists, run it once and record the number
> here with its date. Do not quote a number forward from a different machine
> or a different day; re-run it.

## Where the time actually goes

This breakdown is reasoning from the manifests and Task 12's own rebuild
notes (`docs/07-why-gitops.md`), not a measurement. Four stages, in order:

1. **Namespace deletion.** `kubectl delete namespace llm --wait=true` waits
   for every object in the namespace to finish terminating, including the
   `fetch-weights` init container's `emptyDir` volume and the predictor's
   `terminationGracePeriodSeconds: 120` grace period
   (`models/ornith-9b/overlays/local/patch-resources.yaml`). Expected to be
   the smallest stage, on the order of seconds to a couple of minutes,
   bounded by that grace period.
2. **Argo CD detects and resyncs.** `model-local` and `security-oidc`
   (`clusters/local-kind/apps/90-model-local.yaml`,
   `90-security.yaml`) are the two Applications that owned anything in `llm`.
   Both carry `syncPolicy.automated.selfHeal: true`. Drift caused by a
   resource disappearing from the live cluster (this drill's case) is
   detected through Argo CD's own resource watch cache, not through its
   three-minute git-polling interval (`timeout.reconciliation`, confirmed
   against Argo CD's own FAQ, 2026-08-19) - that interval governs how often
   it checks git for new commits, a different question from how fast it
   notices a namespace it already knows about is gone. No cluster exists
   here to time that detection, so this stays a reasoned lower bound, not a
   number.
3. **Weight download.** The `fetch-weights` init container
   (`models/ornith-9b/base/inferenceservice.yaml`'s sibling patches) pulls
   `ornith-1.0-9b-Q4_K_M.gguf` from Hugging Face - about 5.6 GB
   (`models/ornith-9b/base/model.yaml`, `model.local.approx_size_gb`). This is
   expected to be the dominant cost: at a typical home broadband download
   speed this alone is minutes, not seconds, and it repeats in full on every
   recovery because nothing in phase 1 caches the weight between pod
   lifetimes (the `emptyDir` volume is deleted with the pod that held it).
4. **Weight load.** llama.cpp `mmap`s and validates the GGUF file before its
   `/health` endpoint turns ready (the readiness probe KServe's contract
   requires, `runtimes/llamacpp-arm64/servingruntime.yaml`). Expected to be
   real but smaller than the download for a file already resident on local
   disk.

## The single change that would most reduce it

Cache the weight file across pod lifetimes instead of re-downloading it from
Hugging Face on every recovery. `versions.yaml`'s `kserve.charts_available`
already names the mechanism KServe ships for exactly this,
`kserve-localmodel-crd` / `kserve-localmodel-resources` (a node-local model
cache), and explicitly defers it: "Not needed for a single laptop-sized model
in phase 1." The recovery drill is the scenario where that deferral has a
real, paid cost - stage 3 above repeats in full on every recovery specifically
because there is no cache to hit. Adopting it (or, more simply, a
`hostPath`-backed cache directory checked before the Hugging Face download
runs) would turn the dominant stage of this drill into a local disk read.
