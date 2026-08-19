#!/usr/bin/env python3
"""Turns a result directory into a markdown table. The environment is printed
above the numbers, because a number without its environment is not a result."""
import argparse, glob, json, os

p = argparse.ArgumentParser(); p.add_argument("--dir", required=True)
d = p.parse_args().dir

with open(os.path.join(d, "env.json")) as fh:
    env = json.load(fh)

print(f"# Benchmark run {env['date']}\n")
for k, v in env.items():
    print(f"- **{k}**: {v}")
print("\n| scenario | conc | reqs | errors | TTFT p50 (s) | TTFT p95 (s) | ITL p95 (s) | out tok/s |")
print("|---|---|---|---|---|---|---|---|")

def f(x):
    return "n/a" if x is None else (f"{x:.3f}" if isinstance(x, float) else str(x))

result_paths = sorted(p for p in glob.glob(os.path.join(d, "*.json")) if not p.endswith("env.json"))
error_details = []  # (scenario name, concurrency, {message: count})

for path in result_paths:
    with open(path) as fh:
        report = json.load(fh)
    name = report["scenario"]["name"]
    for r in report["runs"]:
        print(f"| {name} | {r['concurrency']} | {r['requests']} | {r['errors']} | "
              f"{f(r['ttft_p50'])} | {f(r['ttft_p95'])} | {f(r['itl_p95'])} | {f(r['output_tokens_per_second'])} |")
        if r["errors"]:
            error_details.append((name, r["concurrency"], r.get("error_counts") or {}))

# A run with zero errors reports throughput as a clean measurement. A run
# with errors folded silently into the same column reports a throughput
# number that quietly excludes every request that failed - which is a lie
# by omission for a rate-limited endpoint. So every distinct error message
# gets its own line here, with its count, next to the scenario and
# concurrency level it happened at.
if error_details:
    print("\n## Errors\n")
    for name, conc, counts in error_details:
        for message, count in sorted(counts.items(), key=lambda kv: -kv[1]):
            print(f"- **{name}** (concurrency {conc}): {count} x `{message}`")
else:
    print("\nNo request errors in this run.")

print("\n## Questions each scenario answers\n")
for path in result_paths:
    with open(path) as fh:
        s = json.load(fh)["scenario"]
    print(f"- **{s['name']}**: {s['question']}")
