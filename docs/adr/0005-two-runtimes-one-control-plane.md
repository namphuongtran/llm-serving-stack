# ADR 0005: Two engines, one control plane

- Date: 2026-08-17
- Status: accepted

## Context

Development happens on an Apple M4 with 32 GB of memory and no GPU. Production
will be GPU nodes. The natural wish is to run the same engine in both places.

Three measurements make that impossible without a source build:

1. `kserve/huggingfaceserver` publishes `linux/amd64` only. Queried on Docker Hub
   on 2026-08-17, both `:latest` and `:v0.20.0` return a single `linux/amd64`
   platform entry. On an arm64 machine the predictor pod cannot pull a usable
   image.
2. Rosetta 2 does not implement AVX, AVX2, or AVX512. The x86 CPU build of vLLM
   depends on those instructions, so emulation ends in an illegal instruction,
   not in slow success.
3. vLLM does support arm64 CPUs, but there is no prebuilt wheel or image. It must
   be built from source.

## Options

| Option | Verdict |
|---|---|
| Emulate amd64 locally | Not viable. No AVX under Rosetta 2 |
| Build vLLM for arm64 from source | Viable but expensive to build and maintain; kept as an optional time-boxed spike, not a dependency |
| Two engines behind one contract | Chosen |

## Decision

Run `ghcr.io/ggml-org/llama.cpp:server` locally and vLLM in the cloud, behind an
explicit engine contract. The image was verified on 2026-08-17 to publish
`linux/amd64`, `linux/arm64`, and `linux/s390x`, and it speaks the OpenAI API.

The contract has four parts: the OpenAI HTTP surface, readiness that is true only
after weights load, Prometheus metrics with a required minimum set, and an OTLP
traces endpoint.

Everything above the engine is identical in both environments: gateway, policies,
identity, KServe resources, autoscaling, telemetry, high availability,
benchmarking, and CI.

This is not a compromise made to work around a laptop. It is the point.
`ServingRuntime` exists so that the engine is a plug-in rather than a foundation,
and a repository that has actually swapped engines has proved that property
instead of claiming it.

## Cost accepted

Engine-specific metrics differ. Prefix cache hit rate and KV cache utilisation
exist in vLLM only. Prometheus recording rules normalise what both engines
provide into an `llmstack:` namespace, and dashboards read only that namespace.
Panels that cannot be filled locally state why, rather than showing an empty
graph.

A deeper consequence: cache-aware routing cannot be demonstrated in phase 1 at
all. The endpoint picker learns cache state from ZMQ events emitted by vLLM pods,
and llama.cpp does not emit them. That capability starts in phase 2.

## Evidence

- Docker Hub registry manifest query, 2026-08-17: `kserve/huggingfaceserver`
  `:latest` and `:v0.20.0` expose `linux/amd64` only.
- GHCR registry manifest query, 2026-08-17: `ghcr.io/ggml-org/llama.cpp:server`
  exposes `linux/amd64`, `linux/arm64`, `linux/s390x`.
- docker/for-mac issue 7137 and Apple developer forum threads: Rosetta 2 does not
  support AVX, AVX2, or AVX512.
- vLLM CPU installation documentation: on aarch64 there are no prebuilt wheels or
  images, so vLLM must be built from source; the CPU backend builds with the Arm
  Compute Library through oneDNN.
- KServe control-plane architecture page: the scheduler tracks KV cache blocks
  via ZMQ events from vLLM pods.
