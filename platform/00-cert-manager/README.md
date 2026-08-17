# 00 cert-manager

Sync wave 0.

Issues the certificates that admission webhooks need. KServe webhooks and
LeaderWorkerSet both depend on it, so it installs before them.

Nothing here is specific to LLM serving. It is first because everything else
assumes it exists.
