# ADR 0001: Record architecture decisions

- Date: 2026-08-17
- Status: accepted

## Context

This repository exists to be understood, not only to run. Six months from now
the question will not be "what does this manifest do", which the manifest
answers, but "why this component and not the obvious alternative", which nothing
answers unless it is written down.

Upstream projects here move fast. KServe changed its LLM story between v0.15 and
v0.17. llm-d entered the CNCF Sandbox in March 2026. Some documentation pages
disagree with release notes about version numbers. A decision that is correct
today may be wrong in a year, and the only way to tell is to have recorded why it
was made.

## Decision

Every non-obvious choice gets an ADR in `docs/adr/`, numbered, with: context,
options considered, the decision, the cost accepted, and the evidence with the
date it was read.

ADRs are append-only. A changed decision is a new ADR that supersedes the old
one. The old one is not edited, because the reasoning that was true at the time
is part of the record.

Two rules follow from the repository's evidence standard:

1. A claim in an ADR names its source. A version number without a source is not
   admissible.
2. A measured number carries the date it was measured and the hardware it ran on.

## Consequences

Writing them costs time. In return, a decision can be revisited on its merits
rather than re-argued from scratch, and a reader can tell the difference between
a choice that was reasoned and one that was inherited.
