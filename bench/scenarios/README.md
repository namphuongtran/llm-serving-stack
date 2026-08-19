# Benchmark scenarios

Four workloads, each answering a different question:

1. Short prompt, short output. Latency sensitivity.
2. Long prompt (about 8k tokens), short output. Prefill cost.
3. Shared prompt prefix across requests. What cache-aware routing buys.
4. Concurrency sweep at 1, 4, 16, 64. Where saturation begins.

Measured with `bench/harness.py`, a standard-library-only harness against the
public OpenAI-chat endpoint, so the same tool works against llama.cpp here in
phase 1 and against vLLM once phase 2 swaps the runtime.
