# Screenshots this document owes

Ten images belong in the [Software Architecture Document](../README.md). **None
exists yet**, because every one of them can only be captured from a running
cluster.

This file is the work list. Each row names the command that produces the image,
the file name to save it under, and the document that will embed it.

> **Screenshot owed (2026-08-20):** all ten. Capture them after
> `task local:up` succeeds and `bats tests/` has run, then replace the marker in
> each document with the image.

## Before you start

```bash
task preflight
task local:up
task test:smoke
```

Save every image as PNG in this directory, using the file name in the table.
Crop to the relevant panel or terminal region. Do not include a token, a
password, or a `kubeconfig` path in the frame.

## The ten images

| # | File name | Shows | Embedded in |
|---|---|---|---|
| 1 | `01-argocd-applications.png` | All sixteen Argo CD Applications `Synced` and `Healthy` | [05-building-blocks](../05-building-blocks.md) |
| 2 | `02-grafana-dashboard.png` | The "LLM serving" dashboard under real traffic | [08-crosscutting-concepts](../08-crosscutting-concepts.md) |
| 3 | `03-chat-streaming.png` | `task chat` streaming an answer through the gateway | [06-runtime-view](../06-runtime-view.md) |
| 4 | `04-401-then-200.png` | 401 with no token, then 200 with a real JWT | [06-runtime-view](../06-runtime-view.md) |
| 5 | `05-429-quota.png` | 429 after the free tier's budget is spent | [06-runtime-view](../06-runtime-view.md) |
| 6 | `06-replicas-two-nodes.png` | Two predictor replicas on two different nodes | [07-deployment-view](../07-deployment-view.md) |
| 7 | `07-keda-scale-up.png` | KEDA moving the predictor from 2 to 3 replicas | [06-runtime-view](../06-runtime-view.md) |
| 8 | `08-ci-green.png` | Four green CI jobs on `ubuntu-24.04-arm` | [10-quality-requirements](../10-quality-requirements.md) |
| 9 | `09-prometheus-targets.png` | Prometheus scraping the predictor's `/metrics` | [08-crosscutting-concepts](../08-crosscutting-concepts.md) |
| 10 | `10-bench-summary.png` | `bench/summarise.py` output for one scenario | [10-quality-requirements](../10-quality-requirements.md) |

## The commands

### 1. Argo CD, sixteen Applications green

Argo CD's UI is never exposed through the gateway in phase 1, so reach it with a
port-forward. `server.insecure=true` is set for exactly this reason.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
# open http://127.0.0.1:8080, user 'admin', paste the password
```

Capture the Applications list with every tile `Synced` and `Healthy`. A terminal
alternative, if the UI is unavailable:

```bash
kubectl -n argocd get applications -o wide
```

**Read the caption you write carefully.** All sixteen were green on 2026-08-20
while the gateway served `/v1/models` to a caller with no token. The image proves
Argo CD is satisfied; it does not prove the platform works.

### 2. Grafana, the LLM serving dashboard

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80 &
# open http://127.0.0.1:3000, user 'admin', password 'admin'
# dashboard: "LLM serving"
```

Generate traffic first, or every panel is empty:

```bash
for i in 1 2 3 4 5; do task chat -- "Write two sentences about sync waves."; done
```

The panels worth having in frame are "Do users experience it as slow? TTFT p50
and p95", "Are we about to saturate? requests waiting and running", and
"Throughput: output tokens per second".

### 3. A streaming answer

```bash
task chat -- "Explain sync waves in two sentences."
```

### 4. 401, then 200

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 http://llm.localtest.me/v1/models
TOKEN="$(./tools/token.sh)"
curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 \
  -H "authorization: Bearer $TOKEN" http://llm.localtest.me/v1/models
```

Use `./tools/token.sh` rather than `task token` when capturing into a variable.
The script prints one token on stdout and nothing else; `task` adds its own
lines around it.

Expect `401` then `200`. **Do not put the token itself in the frame.**

### 5. 429, quota exceeded

```bash
CLIENT=llm-tier-free task chat -- "Write a long answer about Kubernetes."
```

The free tier is 500 tokens per 60-second window. On the local engine llama.cpp
reports 0.55 tokens per second, which is 33 tokens per window, so **this may not
reproduce locally**. If it does not, capture it from the CI job's log instead and
name the run in the caption. That limitation is measured, not a bug; see
[`docs/STATUS.md`](../../STATUS.md).

### 6. Two replicas, two nodes

```bash
kubectl -n llm get pods -l serving.kserve.io/inferenceservice=ornith-9b -o wide
```

The `NODE` column must show two different workers. If both are on one node, the
`topologySpreadConstraints` are not doing their job and the image would record a
defect rather than the design.

### 7. KEDA scaling up

```bash
kubectl -n llm get scaledobject,hpa,deploy/ornith-9b-predictor -w
```

Put it under load in a second terminal:

```bash
SCENARIOS=bench/scenarios/04-concurrency-sweep.json ./bench/run.sh
```

Capture the moment `READY` moves from `2/2` to `3/3`.

### 8. CI green

```bash
gh run list --limit 5
gh run view <run-id>
```

Capture the four jobs `lint`, `policy`, `smoke`, and `observability` on
`ubuntu-24.04-arm`. Include the run number in the caption, because a CI result is
a dated measurement.

### 9. Prometheus scraping the predictor

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# open http://127.0.0.1:9090/targets and find the PodMonitor target for ornith-9b
```

A useful second frame, showing normalisation actually working:

```bash
curl -s --get http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=llmstack:requests_waiting' | jq .
```

### 10. Benchmark summary

```bash
SCENARIOS=bench/scenarios/01-short.json ./bench/run.sh
python3 bench/summarise.py bench/results/<dated-directory>
```

Include the date directory name in the frame. **A benchmark number without its
date is invalid** in this repository, and a screenshot is no exception.

## When you have them

1. Save each PNG here with the file name from the table.
2. In the document that owns it, replace the
   `> **Screenshot owed (2026-08-20):**` line with the image and a caption
   carrying the date it was captured.
3. Delete that row from this table.
4. If an image cannot be produced, say why here, in this file, with the date. Do
   not remove the row silently: a missing image with a stated reason is a record,
   and a removed one is amnesia.
