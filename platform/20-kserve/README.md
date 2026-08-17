# 20 KServe

Sync wave 2.

The control plane for models. It turns one custom resource into a Deployment, a
Service, routes, probes, and an init container that downloads the model.

Standard deployment mode, not Knative. Gateway API enabled explicitly, because
KServe still defaults `enableGatewayApi` to false.

Phase 1 and 2 use `InferenceService`. Phase 3 moves to `LLMInferenceService`.
