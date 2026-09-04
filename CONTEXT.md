# Context: llm-serving-stack

A Kubernetes LLM inference platform, built layer by layer. Infrastructure only:
YAML, shell, and a small Python benchmark harness.

## This file is a pointer, not a glossary

**The glossary of record is [`docs/sad/12-glossary.md`](docs/sad/12-glossary.md).**

That file already carries every domain term, in three sections: LLM serving,
Platform, and the evidence vocabulary. It names the document of record for each
entry rather than restating it.

This file exists because the agent-skills setup
([`docs/agents/domain.md`](docs/agents/domain.md)) tells tools to read
`CONTEXT.md` before exploring. It deliberately defines nothing, because a second
glossary would be a second home for a fact, and one home per fact is the rule
this repository is built on. Add a term to `docs/sad/12-glossary.md`, never here.

## Read in this order

1. [`README.md`](README.md) - what this is.
2. [`docs/STATUS.md`](docs/STATUS.md) - what has actually been observed, as
   opposed to written down. It is the count of record for the acceptance
   criteria, and it moves in both directions.
3. [`docs/sad/12-glossary.md`](docs/sad/12-glossary.md) - the vocabulary.
4. [`docs/adr/`](docs/adr/) - the decisions. Append-only: a changed decision
   gets a new ADR, and the old one stays.

## The vocabulary that matters most here

Not definitions, which live in the glossary, but a warning about which words
this repository uses precisely and which it refuses to blur:

- **Proven, unproven, doubted, untried, and blocked are five different states**,
  each with its own marker. `docs/sad/12-glossary.md` has the table. Mixing them
  up is the defect that vocabulary exists to prevent.
- **A number without the date it was measured is invalid.** Re-measure rather
  than quoting one forward.
- **Engine, runtime, and predictor are three things.** The engine is the process
  serving the API. The `ServingRuntime` supplies it and may name no model. The
  `InferenceService` binds a model to an engine, and that binding belongs to an
  overlay, never to `models/*/base/`.

## The four boundaries

Breaking one is a design change, not a fix. They are stated in full in
[`CLAUDE.md`](CLAUDE.md): the model is a variable, the engine is swappable,
metrics are normalised into `llmstack:`, and delivery is pull based.
