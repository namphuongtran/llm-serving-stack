# Benchmark scenarios

Four workloads, each answering a different question:

1. Short prompt, short output. Latency sensitivity.
2. Long prompt (about 8k tokens), short output. Prefill cost.
3. Shared prompt prefix across requests. What cache-aware routing buys.
4. Concurrency sweep at 1, 4, 16, 64. Where saturation begins.

Measured with vLLM `benchmark_serving` in OpenAI-chat mode, so the same tool
works against llama.cpp and vLLM.
