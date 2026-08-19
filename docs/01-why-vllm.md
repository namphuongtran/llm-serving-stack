# Why an inference engine

Status: not written yet. This document is written while the layer is built, in
phase 2.

## The question this answers

Why not serve the model with plain transformers, one request at a time?

## Notes to fill in

- What breaks if this layer is removed.
- What it costs to run.
- The one thing that surprised me while building it.

## Measurement tool, built ahead of this document (2026-08-19)

Task 11 built `bench/run.sh`, `bench/harness.py`, and `bench/summarise.py`:
an engine-agnostic harness against the OpenAI-compatible endpoint, so the
same four scenarios in `bench/scenarios/` run unchanged against llama.cpp
here in phase 1 and against vLLM once phase 2 swaps the runtime. No result
exists yet; see `bench/results/README.md` for the first `Unmeasured` entry
and the exact command that produces one.
