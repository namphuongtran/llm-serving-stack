# Admission policies

The same policies run in CI and in the cluster, so a manifest cannot pass review
and then fail at apply time.

Initial rules: resource limits required, floating image tags rejected (digests
only), required labels present.

Installed in-cluster by the Argo CD Application
`clusters/local-kind/apps/12-kyverno.yaml` (wave 1, ahead of everything these
policies govern). Verified offline, without a cluster, with
`task policy` / `kyverno test policy/tests`: `policy/tests/` carries synthetic
Pod and Deployment fixtures and the expected pass/fail outcome for each rule,
because evaluating these policies against this repository's own model
overlays is vacuous (a model overlay renders `InferenceService`,
`ServingRuntime`, and `HTTPRoute` - none of the kinds these policies match -
KServe generates the actual Pod and Deployment at runtime).
