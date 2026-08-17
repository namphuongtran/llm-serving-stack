# Admission policies

The same policies run in CI and in the cluster, so a manifest cannot pass review
and then fail at apply time.

Initial rules: resource limits required, floating image tags rejected (digests
only), required labels present.
