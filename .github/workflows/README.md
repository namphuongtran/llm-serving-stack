# CI

Runs on `ubuntu-24.04-arm`, which is the same architecture as the development
Mac. Steps: lint, policy, multi-arch build, sign and generate an SBOM, kind smoke
test, dependency update pull requests.

Runners have 4 vCPU and no GPU. Tests needing a GPU run as Jobs inside the cloud
cluster instead.
