# ADR 0008: bf16 weights arrive through KServe's storage initializer

- Date: 2026-09-04
- Status: accepted
- Reverses a decision recorded only in a code comment, in
  `models/ornith-9b/base/inferenceservice.yaml`. No ADR is superseded.

## Context

Every overlay in this repository omits `storageUri`, and the omission is
deliberate and carefully explained. The comment in
`models/ornith-9b/base/inferenceservice.yaml` records that the key must be
absent rather than empty, because KServe's guard is `sourceURI != nil` and an
empty string is a non-nil pointer
(`pkg/controller/v1beta1/inferenceservice/components/predictor.go:116` at tag
v0.20.0, read 2026-08-19).

That comment gives one surviving reason, in its own words:

> the storage-initializer expects a model REPOSITORY to copy, and this
> repository fetches one named GGUF file with an init container that verifies
> its sha256. There is nothing for the initializer to do

An earlier reason, a mount-path collision at `/mnt/models`, was corrected on
2026-08-20 and no longer applies. So exactly one reason holds today, and it is a
statement about phase 1's artefact, not about the initializer.

Phase 2 changes that artefact. `models/ornith-9b/base/model.yaml` records the
bf16 build as "about 19 GB", against 5.6 GB for the Q4_K_M GGUF file. The bf16
build is a Hugging Face repository: several safetensors shards, a config, and a
tokenizer. It is exactly the thing the storage initializer exists to copy.

## Options

| Option | Verdict |
|---|---|
| Write a second `fetch-weights` init container that pulls a whole repository | Rejected. It reimplements a multi-file downloader KServe already ships, and the new code would be exercised once |
| Let vLLM download from Hugging Face itself at container start | Rejected. It hides the download inside the engine container, so a failed or slow fetch looks like a slow start, behind the readiness probe |
| Set `storageUri` in the `gpu-single` overlay and let the initializer run | Chosen |

## Decision

The `gpu-single` overlay sets `storageUri` on the predictor and lets KServe
inject the storage initializer. Every other overlay continues to omit the key,
unchanged, for the reason quoted above.

The stated reason for omitting `storageUri` expires here rather than transfers.
Phase 2 has a model repository, so "there is nothing for the initializer to do"
stops being true.

> **Untried (2026-09-04):** the exact `storageUri` scheme for a Hugging Face
> repository has not been confirmed against KServe v0.20.0's own source or
> documentation. `hf://ornith-ai/Ornith-1.0-9B` is the intended form and is a
> guess until read. Confirm it before the first GPU run, from the pinned tag's
> storage-initializer source, not from memory.

## Cost accepted

**Per-file sha256 verification is lost.** Phase 1 verifies its one GGUF file
against a hash recorded in `model.yaml`, obtained two ways on 2026-08-19. The
storage initializer offers no equivalent per-file check here. The integrity
guarantee drops to whatever Hugging Face and TLS provide. This is a real
reduction and it is accepted because writing a verifying multi-file downloader
is a larger risk than the one it removes.

**The overlays stop being thin patches of one shape.** Until now every overlay
differed from the base in values. `gpu-single` differs in mechanism: it invites
a container the others suppress. Anyone reasoning about one overlay from
another will be wrong about this.

## Evidence

- `models/ornith-9b/base/inferenceservice.yaml`, the `storageUri` comment block,
  read 2026-09-04. It carries the `sourceURI != nil` guard, the upstream file
  and line, the 2026-08-20 correction, and the surviving reason quoted above.
- `models/ornith-9b/base/model.yaml`, read 2026-09-04: "bf16 is about 19 GB and
  needs a GPU; local runs the Q4_K_M quantisation", and
  `local.approx_size_gb: 5.6`.
