#!/usr/bin/env python3
"""Measures an OpenAI-compatible endpoint. Engine agnostic on purpose: the same
harness runs against llama.cpp on a laptop and vLLM on GPU nodes."""
import argparse, json, statistics, threading, time, urllib.request

def build_prompt(approx_tokens, shared_prefix_tokens=0, seed=0):
    # Roughly 0.75 words per token. Exactness does not matter; reproducibility does.
    prefix = " ".join(["context"] * int(shared_prefix_tokens * 0.75))
    unique = " ".join([f"w{seed}-{i}" for i in range(int((approx_tokens - shared_prefix_tokens) * 0.75))])
    return (prefix + " " + unique).strip()

def one_request(base, token, model, prompt, max_tokens):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(
        f"{base}/v1/chat/completions", data=body,
        headers={"content-type": "application/json", "authorization": f"Bearer {token}"})
    started = time.perf_counter()
    ttft, last, gaps, chunks, usage = None, None, [], 0, None
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data: "):
                    continue
                payload = line[6:]
                if payload == "[DONE]":
                    break
                now = time.perf_counter()
                if ttft is None:
                    ttft = now - started
                else:
                    gaps.append(now - last)
                last = now
                chunks += 1
                try:
                    obj = json.loads(payload)
                    if obj.get("usage"):
                        usage = obj["usage"]
                except json.JSONDecodeError:
                    pass
        return {"ok": True, "ttft": ttft, "itl": gaps, "chunks": chunks,
                "total": time.perf_counter() - started, "usage": usage}
    except Exception as exc:                      # network, 4xx, 5xx, timeout
        # This is the case that matters most: a 429 from the rate limiter, a
        # 503 while a rollout is in progress, a connection reset mid-stream.
        # None of those may crash the harness, and none of them may vanish
        # silently either - a throughput number computed only from the
        # requests that happened to succeed is not the endpoint's throughput,
        # it is a nicer number than the endpoint's throughput.
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}",
                "total": time.perf_counter() - started}

def run(base, token, model, scenario, concurrency):
    n = scenario["num_prompts"]
    prompts = [build_prompt(scenario["prompt_tokens"],
                            scenario.get("shared_prefix_tokens", 0), i) for i in range(n)]
    results, lock, index = [], threading.Lock(), {"i": 0}

    def worker():
        while True:
            with lock:
                i = index["i"]
                index["i"] += 1
            if i >= n:
                return
            r = one_request(base, token, model, prompts[i], scenario["max_tokens"])
            with lock:
                results.append(r)

    started = time.perf_counter()
    threads = [threading.Thread(target=worker) for _ in range(concurrency)]
    for t in threads: t.start()
    for t in threads: t.join()
    wall = time.perf_counter() - started

    ok = [r for r in results if r["ok"]]
    failed = [r for r in results if not r["ok"]]
    def pct(values, q):
        if not values: return None
        s = sorted(values)
        return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]
    out_tokens = sum((r["usage"] or {}).get("completion_tokens", r["chunks"]) for r in ok)
    # Every distinct error message, with its count, so a rate-limited run
    # reads as "36 x 429" instead of one opaque number in an errors column.
    error_counts = {}
    for r in failed:
        error_counts[r["error"]] = error_counts.get(r["error"], 0) + 1
    return {
        "concurrency": concurrency,
        "requests": n,
        "errors": len(failed),
        "error_counts": error_counts,
        "wall_seconds": round(wall, 3),
        "ttft_p50": pct([r["ttft"] for r in ok if r["ttft"]], 0.50),
        "ttft_p95": pct([r["ttft"] for r in ok if r["ttft"]], 0.95),
        "itl_p95": pct([g for r in ok for g in r["itl"]], 0.95),
        "output_tokens": out_tokens,
        "output_tokens_per_second": round(out_tokens / wall, 2) if wall else None,
        "first_error": next((r["error"] for r in failed), None),
    }

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--scenario", required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--token", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    with open(a.scenario) as fh:
        scenario = json.load(fh)
    levels = scenario.get("concurrency_levels", [scenario.get("concurrency", 1)])
    report = {"scenario": scenario, "runs": [run(a.base_url, a.token, a.model, scenario, c) for c in levels]}
    with open(a.out, "w") as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report["runs"], indent=2))
