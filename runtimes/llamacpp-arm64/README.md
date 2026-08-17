# Runtime: llama.cpp (arm64, local)

A `ServingRuntime` wrapping `ghcr.io/ggml-org/llama.cpp:server`, which publishes
an arm64 image and speaks the OpenAI API.

This exists because `kserve/huggingfaceserver` is published for amd64 only, and
Rosetta 2 does not implement AVX, so an emulated x86 vLLM build cannot run on an
Apple Silicon machine.

Limitation to keep in mind: llama.cpp does not emit the KV cache events the
endpoint picker consumes. Cache-aware routing therefore begins in phase 2, on
vLLM.
