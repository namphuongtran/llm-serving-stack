# Cluster: local-kind

Argo CD app-of-apps for the local machine. Sync waves encode install order, so
ordering is declared rather than remembered.

Pull-based delivery is not a preference here, it is a requirement: GitHub cannot
reach a kind cluster running on a laptop.
