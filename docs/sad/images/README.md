# Screenshots

Ten images belong in the [Software Architecture Document](../README.md).
**All ten exist, captured 2026-08-20 from a real cluster.**

Taking them found five defects, recorded in [`docs/STATUS.md`](../../STATUS.md).
Four of the images show a failure rather than the feature they were meant to
illustrate, and all four are kept that way.

## How these were produced, because it changes how you should read them

| Method | Images | What it means |
|---|---|---|
| **Headless browser** against the live UI | 1, 2, 8, 9 | A real screenshot of the real page, taken with Playwright and Chromium against a port-forward, or against github.com for image 8 |
| **Rendered terminal capture** | 3, 4, 5, 6, 7, 10 | The command was run for real and its output written to a file. That file is then rendered in a monospace frame. **The text is never edited**: it is the verbatim output, laid out so it reads at screenshot size |

Neither method invents anything. To re-check a claim in one of these images, run
the command beside it rather than trusting the picture.

## The ten

| # | File | Shows | Captured |
|---|---|---|---|
| 1 | `01-argocd-applications.png` | Argo CD Applications list. Sidebar reads `Synced 16` | 2026-08-20 |
| 2 | `02-grafana-dashboard.png` | The "LLM serving" dashboard under real traffic: TTFT p50/p95, requests waiting and running, throughput, batching, context high-watermark | 2026-08-20 |
| 3 | `03-chat-streaming.png` | `task chat` streaming a real answer through the gateway | 2026-08-20 06:53Z |
| 4 | `04-401-then-200.png` | 401 with no token, 401 with a forged token, 200 with a real JWT serving `ornith-9b` | 2026-08-20 |
| 5 | `05-429-quota.png` | The free tier's budget spent in one request: `usage.total_tokens=552`, then 429 | 2026-08-20 06:55Z |
| 6 | `06-replicas-two-nodes.png` | Two predictor replicas on two different nodes, PDB allowing 1 disruption, both `InferenceService` objects Ready | 2026-08-20 |
| 7 | `07-keda-scale-up.png` | KEDA scaling on queue depth. **Read the third pod's STATUS** | 2026-08-20 06:14:49Z |
| 8 | `08-ci-runs.png` | The CI run history: nine runs, five green and four red | 2026-08-20 |
| 9 | `09-prometheus-targets.png` | Prometheus scraping `llm-predictors` 3/3 UP, plus the gateway and Tempo | 2026-08-20 |
| 10 | `10-bench-summary.png` | One benchmark scenario, 31 errors in 40 requests | 2026-08-20 06:52Z |

## The four that show a failure

- **Image 7 is not a successful scale-up.** KEDA set `spec.replicas: 3` and the
  third pod is `Pending` on node `<none>`. It can never schedule:
  `maxReplicaCount: 3` and `maxSkew: 1` with `DoNotSchedule` cannot both hold on
  two worker nodes. Finding 1.
- **Image 8 was to be named `08-ci-green.png`, and it is not green.** Four of the
  nine runs failed. Renamed rather than retaken, because retaking it until it
  looked green is the exact thing this repository forbids.
- **Image 10 is a failed benchmark.** 31 of 40 requests errored, 19 with HTTP
  401, because the run outlived its own access token. Finding 5.
- **Image 5 exists only because taking it disproved a claim.** Four files here
  said the free tier was unreachable on this engine. It is reachable in two
  requests. Finding 4.

## What blocked the last three, which was itself the finding

Images 3, 5, and 10 were blocked for about twenty minutes. `tools/chat.sh`
returned `Internal Server Error.` on 6 of 6 attempts while `bench/run.sh` was
running, and Authorino logged `UNAVAILABLE` at the matching timestamps. All three
were captured once the benchmark stopped, image 3 on the first attempt.

**Do not read "captured on the first attempt" as "works reliably".** It works
when nothing else is using the cluster. Finding 2 is the record.

## The commands

Every image can be reproduced. Run the command, then capture.

### 1. Argo CD

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
# open http://127.0.0.1:8080, user 'admin'
```

**Read the caption carefully.** All sixteen were green on 2026-08-20 while the
gateway served `/v1/models` to a caller with no token. The image proves Argo CD
is satisfied; it does not prove the platform works.

### 2. Grafana

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80 &
# http://127.0.0.1:3000, admin/admin, dashboard "LLM serving"
```

Generate traffic first or every panel is empty. Allow the panels a full minute:
a first attempt at 15 seconds produced a capture with every panel blank and the
query spinner still turning, which would have read as a broken dashboard.

### 3. A streaming answer

```bash
task chat -- "Reply with exactly: hello from the gateway."
```

Run it on a quiet cluster. Under concurrent load it returns
`Internal Server Error.` and **exits 0**, which is a defect in `tools/chat.sh`.

### 4. 401, then 200

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 http://llm.localtest.me/v1/models
TOKEN="$(./tools/token.sh)"
curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 \
  -H "authorization: Bearer $TOKEN" http://llm.localtest.me/v1/models
```

Use `./tools/token.sh`, not `task token`: the script prints one token on stdout
and nothing else. **Never put the token itself in the frame.**

### 5. The 429

Not by generating 500 tokens, which this engine cannot do inside a 60-second
window. `usage.total_tokens` includes prompt tokens, so **one long prompt spends
the budget**:

```bash
TOKEN="$(./tools/token.sh llm-tier-free)"
PROMPT=$(python3 -c "print('Explain Kubernetes sync waves and Argo CD ordering in detail. ' * 45)")
BODY=$(python3 -c "
import json
print(json.dumps({'model':'ornith-9b','max_tokens':1,'messages':[{'role':'user','content':'''$PROMPT'''}]}))")
for i in 1 2 3; do
  curl -s -w '\n%{http_code}\n' --max-time 180 -X POST http://llm.localtest.me/v1/chat/completions \
    -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d "$BODY" \
    | tail -2
done
```

Request 1 returns 200 with `usage.total_tokens` above 500. Request 2 returns 429.

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

Check `kubectl -n llm describe pod <the new one>` before believing a scale-up.
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
python3 bench/summarise.py --dir bench/results/<dated-directory>
```

Note `--dir`: it is a required named argument, not positional. `bench/run.sh`
also writes `summary.md` into that directory itself.

Include the date directory name in the frame. **A benchmark number without its
date is invalid** in this repository, and a screenshot is no exception. Read the
Errors section before the latency figures.

## Replacing one

1. Save the PNG here under the same file name, so the documents that embed it
   need no change.
2. Update its row in the table above with the new capture date.
3. If a re-capture shows something different from the caption in the document
   that embeds it, change the caption. Do not keep a caption that the current
   image no longer supports.
