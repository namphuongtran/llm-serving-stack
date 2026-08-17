# Overlay: ci

GitHub arm64 runners have 4 vCPU and no GPU. This overlay swaps in a model of
roughly 0.5B parameters so the smoke test finishes in reasonable time.

It exists to prove the wiring, not the model quality.
