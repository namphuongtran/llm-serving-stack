# Runtime: vLLM (cloud)

The engine for phase 2 and phase 3: continuous batching, paged attention, prefix
caching, and the KV cache events that cache-aware routing depends on.

Same `InferenceService` shape as the local runtime. Only the runtime reference
and the resource requests change, through an overlay.
