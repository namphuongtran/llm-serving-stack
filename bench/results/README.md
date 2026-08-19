# Benchmark results

One directory per measurement, named by date and machine, for example
`2026-08-17-m4-llamacpp/`.

Every result records the date, the hardware, image digests, and engine
arguments. A number without a date is treated as invalid in this repository, and
old numbers are re-measured rather than quoted forward.

## First run

> **Unmeasured (2026-08-19):** the first full four-scenario measurement
> against `ornith-9b` on llama.cpp, run `task bench` once a cluster exists.

No `kind` cluster runs on this machine (Task 10 and Task 11 were written
without one; see `.superpowers/sdd/2026-08-17-phase-1-local-stack/batch-d-report.md`).
`bench/run.sh`, `bench/harness.py`, and `bench/summarise.py` are complete and
were exercised against a synthetic dead endpoint to confirm the harness
records connection errors instead of crashing or discarding them; no request
in this repository's history has reached a real `ornith-9b-predictor`. Do not
treat the absence of a result directory here as a bug: it is the honest state
until `task bench` runs against a live cluster.
