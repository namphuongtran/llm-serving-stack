# Model: Ornith-1.0-9B, base

Environment-agnostic `InferenceService`. It names the model and nothing about
where it runs.

Ornith-1.0-9B was chosen for learning: MIT licensed, about 19 GB in bf16, with
quantised builds small enough for a laptop.

The model is a variable, not a constant. Switching models must touch only this
directory.
