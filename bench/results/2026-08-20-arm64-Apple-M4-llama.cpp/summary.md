# Benchmark run 2026-08-20

- **date**: 2026-08-20
- **machine**: arm64-Apple-M4
- **engine_image**: ghcr.io/ggml-org/llama.cpp:server-b10481@sha256:5be603b8cbf1ee9e078232ae5e1d02794e7540e210299b53bac04cbc6debc77b
- **model**: ornith-1.0-9b-Q4_K_M.gguf
- **replicas**: 2

| scenario | conc | reqs | errors | TTFT p50 (s) | TTFT p95 (s) | ITL p95 (s) | out tok/s |
|---|---|---|---|---|---|---|---|
| short-prompt-short-output | 4 | 40 | 31 | 186.494 | 199.852 | 29.684 | 0.210 |

## Errors

- **short-prompt-short-output** (concurrency 4): 19 x `HTTPError: HTTP Error 401: Unauthorized`
- **short-prompt-short-output** (concurrency 4): 9 x `HTTPError: HTTP Error 500: Internal Server Error`
- **short-prompt-short-output** (concurrency 4): 3 x `HTTPError: HTTP Error 503: Service Unavailable`

## Questions each scenario answers

- **short-prompt-short-output**: How responsive is a small interactive request?
