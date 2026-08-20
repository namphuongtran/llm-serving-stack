# Screenshots

Ten images belong in the [Software Architecture Document](../README.md).
**Seven exist, captured 2026-08-20 from a real cluster. Three do not, and each
one says why.**

## How these were produced, because it changes how you should read them

Two different methods, and the difference matters:

| Method | Images | What it means |
|---|---|---|
| **Headless browser** against the live UI | 1, 2, 8, 9 | A real screenshot of the real page, taken with Playwright and Chromium against a port-forward (or, for 8, against github.com) |
| **Rendered terminal capture** | 4, 6, 7 | The command was run for real and its output captured to a file. That file is then rendered as a terminal window. **The text is never edited** - it is the verbatim output, laid out in a monospace frame so it reads at screenshot size |

Neither method invents anything. If you need to re-check a claim in one of these
images, run the command beside it rather than trusting the picture.

## What exists

| # | File | Shows | Captured |
|---|---|---|---|
| 1 | `01-argocd-applications.png` | Argo CD Applications list. Sidebar reads `Synced 16` | 2026-08-20 |
| 2 | `02-grafana-dashboard.png` | The "LLM serving" dashboard under real traffic: TTFT p50/p95, requests waiting and running, throughput, batching, context high-watermark | 2026-08-20 |
| 4 | `04-401-then-200.png` | 401 with no token, 401 with a forged token, 200 with a real JWT serving `ornith-9b` | 2026-08-20 |
| 6 | `06-replicas-two-nodes.png` | Two predictor replicas on two different nodes, PDB allowing 1 disruption, both `InferenceService` objects Ready | 2026-08-20 |
| 7 | `07-keda-scale-up.png` | KEDA scaling on queue depth. **Read the third pod's STATUS** | 2026-08-20 06:14:49Z |
| 8 | `08-ci-runs.png` | The CI run history: nine runs, five green and four red | 2026-08-20 |
| 9 | `09-prometheus-targets.png` | Prometheus scraping `llm-predictors` 3/3 UP, plus the gateway and Tempo | 2026-08-20 |

Two of these are not the picture the plan asked for, and both are kept as they
came out:

- **Image 7 does not show a successful scale-up.** KEDA set `spec.replicas: 3`,
  and the third pod is `Pending` on node `<none>`. It can never schedule:
  `maxReplicaCount: 3` and `maxSkew: 1` with `DoNotSchedule` cannot both hold on
  two worker nodes. The image is evidence of a real finding rather than of the
  feature working. [`docs/STATUS.md`](../../STATUS.md), "The first load test",
  has the scheduler's own message.
- **Image 8 was named `08-ci-green.png` in the plan, and it is not green.** Four
  of the nine runs failed. It was renamed rather than retaken, because retaking
  it until it looked green is the exact thing this repository forbids.

## What does not exist, and why

| # | File | Blocked by |
|---|---|---|
| 3 | `03-chat-streaming.png` | `tools/chat.sh` returned `Internal Server Error.` on **6 of 6** attempts spread over 20 minutes. Not a scripting problem: Authorino logged `UNAVAILABLE` (gRPC 14) at the matching timestamps, which the gateway renders as HTTP 500. See finding 2 in [`docs/STATUS.md`](../../STATUS.md) |
| 5 | `05-429-quota.png` | The free tier is 500 tokens per 60s and llama.cpp reports 0.55 tokens/s here, so the quota is out of reach locally. A long prompt should have reached it, because the counter reads `usage.total_tokens` and prompt tokens count too. That attempt hit the same HTTP 500 as image 3 |
| 10 | `10-bench-summary.png` | `bench/run.sh` was still running when this file was written. It also generated the load that produced the 500s above, which is itself a finding |

**These three are not "todo later" items.** Two of them are blocked by a defect
this repository now has a record of, and one is blocked by a limit it already
documented. Capturing them requires fixing or waiting out finding 2, not trying
harder with a screenshot tool.

## The commands

Every image below can be reproduced. Run the command, then capture.

### 1. Argo CD

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
# open http://127.0.0.1:8080, user 'admin'
```

**Read the caption you write carefully.** All sixteen were green on 2026-08-20
while the gateway served `/v1/models` to a caller with no token. The image proves
Argo CD is satisfied; it does not prove the platform works.

### 2. Grafana

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80 &
# http://127.0.0.1:3000, admin/admin, dashboard "LLM serving"
```

Generate traffic first or every panel is empty. Allow the panels a full minute to
render: a first attempt at 15 seconds produced a screenshot with every panel
blank and the query spinner still turning, which would have been mistaken for a
broken dashboard.

### 3. A streaming answer

```bash
task chat -- "Explain sync waves in two sentences."
```

Currently returns `Internal Server Error.` under any concurrent load. Note that
`tools/chat.sh` **exits 0** when it does, which is a defect in the script.

### 4. 401, then 200

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 http://llm.localtest.me/v1/models
TOKEN="$(./tools/token.sh)"
curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 \
  -H "authorization: Bearer $TOKEN" http://llm.localtest.me/v1/models
```

Use `./tools/token.sh`, not `task token`: the script prints one token on stdout
and nothing else. **Never put the token itself in the frame.**

### 5. 429

```bash
CLIENT=llm-tier-free task chat -- "Write a long answer about Kubernetes."
```

If it does not reproduce, capture it from the CI job's log instead and name the
run in the caption.

### 6. Two replicas, two nodes

```bash
kubectl -n llm get pods -l serving.kserve.io/inferenceservice=ornith-9b -o wide
kubectl -n llm get pdb ornith-9b
```

The `NODE` column must show two different workers.

### 7. KEDA scaling

```bash
kubectl -n llm get scaledobject,hpa,deploy/ornith-9b-predictor
```

Under load in a second terminal:

```bash
SCENARIOS=bench/scenarios/04-concurrency-sweep.json ./bench/run.sh
```

Check `kubectl -n llm describe pod <the new one>` before believing a scale-up:
`spec.replicas` reaching 3 is not the same as a third pod serving traffic.

### 8. CI runs

```bash
gh run list --branch main --limit 10
```

Include the run numbers in the caption. A CI result is a dated measurement.

### 9. Prometheus targets

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# http://127.0.0.1:9090/targets
```

Use `waitUntil: 'domcontentloaded'` if you script this. The page polls forever,
so `networkidle` never fires and the capture times out.

### 10. Benchmark summary

```bash
SCENARIOS=bench/scenarios/01-short.json ./bench/run.sh
python3 bench/summarise.py bench/results/<dated-directory>
```

Include the date directory name in the frame. **A benchmark number without its
date is invalid** in this repository, and a screenshot is no exception.

## When you capture a missing one

1. Save the PNG here under the file name in the table.
2. Replace the `> **Screenshot owed (2026-08-20):**` line in the document that
   owns it with the image and a caption carrying the capture date.
3. Move its row from "does not exist" to "what exists".
4. If it still cannot be produced, update the reason with today's date. Do not
   remove the row: a missing image with a stated reason is a record, and a
   removed one is amnesia.
