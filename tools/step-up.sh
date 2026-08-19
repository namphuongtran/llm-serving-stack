#!/usr/bin/env bash
# Bring the stack up ONE LAYER AT A TIME, measuring what each layer costs and
# stopping before the machine is wedged.
#
# Why this exists. Until 2026-08-19 this repository had exactly two ways to
# install: `task local:up`, which creates the cluster and hands everything to
# Argo CD in one shot, and the nine `platform/NN-*/install.sh` scripts, which
# are ordered but unmeasured. Neither answers the question a person with a
# laptop actually asks first, which is "how far can I get before Docker runs
# out". This script answers that, and writes down the numbers so the answer has
# a date on it.
#
# What this is NOT. It is not a third install path. Every step below either
# runs an existing `install.sh` or applies an existing manifest, so nothing here
# can drift away from the two tracked paths. Two steps call `kubectl apply`
# directly, `model` and `security`, and those are the two with no imperative
# script anywhere - see STEP TABLE below. (`cluster` is a third non-script step,
# but it runs `kind create cluster`, not an apply.)
#
# Bash 3.2.57 (the version macOS ships) is the floor, per CLAUDE.md: no
# mapfile, no readarray, no associative arrays, no ${v,,}.
set -euo pipefail
cd "$(dirname "$0")/.."

# k() and KUBECTL_CONTEXT, sourced at top level for the same reason
# bench/run.sh:7-13 gives: a bare `kubectl` targets whatever context is
# current, which on the machine this was written on was `docker-desktop`.
# shellcheck source=tests/lib/helpers.bash
source tests/lib/helpers.bash

LOG="docs/deployment-log.tsv"
STOP_PCT="${STOP_PCT:-85}"     # stop when node containers exceed this % of Docker's memory
DATE="$(date +%Y-%m-%d)"

# Every platform/*/install.sh uses BARE kubectl, so each one targets whatever
# context is current rather than KUBECTL_CONTEXT. That is the repository's own
# choice for the imperative path, and it is fine when the operator has just run
# `kind create cluster`, which sets the context. It is not fine when they have
# not. Since this script drives those scripts, it checks once, here, rather than
# letting nine scripts each assume it.
#
# The `cluster` step is exempt: it is what creates the context.
assert_context() {
  local current
  current="$(kubectl config current-context 2>/dev/null || true)"
  [ "$current" = "$KUBECTL_CONTEXT" ] || {
    printf 'step-up: current context is "%s", expected "%s".\n' "$current" "$KUBECTL_CONTEXT" >&2
    printf 'Every platform/*/install.sh uses bare kubectl, so running now would\n' >&2
    printf 'install into the wrong cluster. Fix with:\n' >&2
    printf '  kubectl config use-context %s\n' "$KUBECTL_CONTEXT" >&2
    exit 1
  }
}

# ---------------------------------------------------------------------------
# STEP TABLE
#
# Two fields per line, separated by a tab: the step id, then the command.
# The order is the sync-wave order in clusters/local-kind/apps/, which is the
# order Argo CD would use. Confirmed against that directory on 2026-08-19.
#
# gateway-api-crds is a real script, platform/10-istio/gateway-api-crds.sh, and
# it is NOT called by platform/10-istio/install.sh. Only .github/workflows/ci.yml
# calls it (lines 175 and 296), immediately before the istio install. So an
# operator following the imperative path by running the nine install.sh scripts
# in order gets no Gateway API CRDs at all, and the istio layer then fails with
# `no matches for kind "Gateway"`. Naming it as its own step here is the point:
# the ordering requirement was previously known only to CI.
#
# Two steps below are NOT an install.sh, because nothing imperative covers them.
# They exist only as Argo CD Applications:
#   model     clusters/local-kind/apps/90-model-local.yaml
#   security  clusters/local-kind/apps/90-security.yaml
# ---------------------------------------------------------------------------
steps() {
  printf '%s\n' \
    "cluster	kind create cluster --config prereqs/kind-cluster.yaml" \
    "gateway-api-crds	./platform/10-istio/gateway-api-crds.sh" \
    "cert-manager	./platform/00-cert-manager/install.sh" \
    "istio	./platform/10-istio/install.sh" \
    "kyverno	./platform/12-kyverno/install.sh" \
    "keycloak	./platform/15-keycloak/install.sh" \
    "kserve	./platform/20-kserve/install.sh" \
    "kuadrant	./platform/25-kuadrant/install.sh" \
    "observability	./platform/30-observability/install.sh" \
    "keda	./platform/40-keda/install.sh" \
    "argocd	./platform/50-argocd/install.sh" \
    "model	kustomize build models/ornith-9b/overlays/local | k apply -f -" \
    "security	k apply -f security/oidc/"
}

step_ids()  { steps | cut -f1; }
step_cmd()  { steps | awk -F'\t' -v id="$1" '$1==id {print $2}'; }

# ---------------------------------------------------------------------------
# Measurement.
#
# `docker stats` on the kind node containers, NOT `kubectl top`. kind does not
# install metrics-server, so `kubectl top` returns "Metrics API not available"
# on a fresh cluster - checked on this machine, 2026-08-19. The node containers
# are ordinary Docker containers, so their real resident memory is readable
# from the daemon with no in-cluster component at all.
# ---------------------------------------------------------------------------
docker_mem_limit_mib() {
  # `docker info` prints 0 on stdout and its error on stderr when the daemon is
  # down, so a caller that divides by this gets "division by 0" from bash and the
  # operator sees a shell error instead of "Docker is not running". Confirmed by
  # running `./tools/step-up.sh measure` with Docker stopped, 2026-08-20. Callers
  # must treat 0 as "cannot measure"; sample() below does.
  docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1/1048576}'
}

# Sum of resident memory across the kind node containers.
#
# Returns 1 when it measured NOTHING, which is not the same as measuring zero and
# is the whole point of the exit code. `docker stats` failing, printing nothing,
# or printing only containers from some other cluster all used to return a bare
# `0`, and 0 passes every threshold, so the guard said "continue" precisely when
# it could not see. Confirmed 2026-08-20 by pointing CLUSTER at a name no
# container has: used came back 0 and the guard was happy.
#
# `-(control-plane|worker[0-9]*)$` and not a bare `-` prefix. A prefix match also
# catches a SECOND cluster whose name extends this one: with
# llm-serving-stack-control-plane at 1GiB and llm-serving-stack-2-control-plane at
# 4GiB, the prefix form summed both and reported 5120 MiB instead of 1024 - a
# fivefold over-count and a false STOP.
node_mem_used_mib() {
  local total=0 seen=0 line val unit
  for line in $(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null \
                | grep -E "^${CLUSTER}-(control-plane|worker[0-9]*)\|" | sed 's/.*|//' | awk '{print $1}'); do
    val="$(printf '%s' "$line" | sed 's/[A-Za-z]*$//')"
    unit="$(printf '%s' "$line" | sed 's/^[0-9.]*//')"
    case "$unit" in
      # GiB and GB are NOT the same, and treating them alike overstated by 7%:
      # 6.9GB became 7065 MiB where the truth is 6580, which moved a reading from
      # 84% to 89% and crossed the default STOP_PCT. docker stats normally emits
      # the binary units, so the decimal branches are defensive.
      GiB) val="$(awk -v v="$val" 'BEGIN{printf "%d", v*1024}')" ;;
      GB)  val="$(awk -v v="$val" 'BEGIN{printf "%d", v*1000000000/1048576}')" ;;
      MiB) val="$(awk -v v="$val" 'BEGIN{printf "%d", v}')" ;;
      MB)  val="$(awk -v v="$val" 'BEGIN{printf "%d", v*1000000/1048576}')" ;;
      KiB) val="$(awk -v v="$val" 'BEGIN{printf "%d", v/1024}')" ;;
      kB)  val="$(awk -v v="$val" 'BEGIN{printf "%d", v*1000/1048576}')" ;;
      B|"") val=0 ;;
      # Reachable, not theoretical: docker stats prints `--` for a container that
      # is created, paused, or restarting. Without this the raw text reached
      # $(( )) and aborted the whole run with a bash syntax error.
      *)   val=0 ;;
    esac
    total=$((total + val))
    seen=$((seen + 1))
  done
  printf '%d' "$total"
  [ "$seen" -gt 0 ]
}

pod_count()     { k get pods -A --no-headers 2>/dev/null | grep -c . || true; }
not_ready()     { k get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' | grep -c . || true; }

# Pods the scheduler could not place, RIGHT NOW.
#
# This used to count `kubectl get events --field-selector reason=FailedScheduling`
# with no time bound. Kubernetes keeps events for about an hour, so one transient
# Insufficient memory during a rollout tripped the guard on every later step for
# that hour, telling the operator to raise Docker memory when nothing was wrong.
# Pending pods are the state that actually matters.
#
# `|| true` on the count, not on the pipeline, because `grep -c` exits 1 on zero
# matches. The empty-string case is handled by sample(): `jq`-style pipelines
# exit 0 and print nothing when their input is empty, and `[ "" -gt 0 ]` is a
# syntax error that `set -e` does not catch inside an `if`.
unplaced_pods() {
  local out
  out="$(k get pods -A --field-selector status.phase=Pending -o json 2>/dev/null \
         | jq -r '[.items[] | select(.status.conditions[]? | select(.reason=="Unschedulable"))] | length' 2>/dev/null)" \
    || return 1
  # A non-numeric or empty answer means the pipeline broke, not that nothing is
  # unschedulable. The old form ended in `|| true`, which reported "zero
  # unschedulable pods" when jq was missing or the JSON shape changed - confirmed
  # 2026-08-20 with a jq shim exiting 127 against three genuinely unschedulable
  # pods: the guard said nothing was wrong and continued.
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}


# The kind cluster name, read from the same config the `cluster` step applies, so
# the container-name prefix cannot drift from what kind actually creates.
CLUSTER="$(yq -r '.name' prereqs/kind-cluster.yaml)"

# ---------------------------------------------------------------------------
# sample() takes ONE measurement and puts it in globals. Both guard() and
# record() read those globals rather than measuring again.
#
# This matters for more than tidiness. Until 2026-08-20 guard() measured, printed
# its numbers, and then record() measured AGAIN - twice, in fact, since it called
# node_mem_used_mib and docker_mem_limit_mib once for the column and once more
# inside the percentage arithmetic. So one step produced up to three different
# readings, the operator saw one and the log kept another. That is how
# docs/deployment-walkthrough.md came to quote 17811 MiB for a step whose logged
# value is 17855: both were real, seconds apart, and neither was wrong. A number
# that cannot be traced to one sample is not a measurement.
#
# Returns 1 when the environment cannot be measured at all, so callers can say so
# instead of dividing by zero.
# ---------------------------------------------------------------------------
sample() {
  S_LIMIT=0; S_USED=0; S_PCT=0; S_PODS=0; S_NOTREADY=0; S_UNPLACED=0

  S_LIMIT="$(docker_mem_limit_mib)"
  if [ -z "$S_LIMIT" ] || [ "$S_LIMIT" -le 0 ] 2>/dev/null; then
    S_LIMIT=0; return 1
  fi

  # Docker answering does NOT mean the cluster answers. The case that matters:
  # node containers alive and eating memory while the control plane has been
  # OOM-killed. That is exactly the wall this guard exists to find, and without
  # this check it read as "0 pods, 0 not running" and returned green - confirmed
  # 2026-08-20 with the API server refusing connections.
  require_cluster >/dev/null 2>&1 || return 1

  S_USED="$(node_mem_used_mib)" || return 1
  S_PCT=$((S_USED * 100 / S_LIMIT))
  S_PODS="$(pod_count)"
  S_NOTREADY="$(not_ready)"
  S_UNPLACED="$(unplaced_pods)" || return 1
  return 0
}


# ---------------------------------------------------------------------------
# The guard. Reads the sample taken by sample(). Exits non-zero when continuing
# would waste the operator's time, and says which of the reasons it is.
# ---------------------------------------------------------------------------
guard() {
  printf '  memory  %s MiB of %s MiB (%s%%)\n' "$S_USED" "$S_LIMIT" "$S_PCT"
  printf '  pods    %s total, %s not running\n' "$S_PODS" "$S_NOTREADY"

  if [ "$S_UNPLACED" -gt 0 ]; then
    printf '\nSTOP: %s pod(s) are Pending and Unschedulable.\n' "$S_UNPLACED" >&2
    printf 'This is a hard wall, not slowness. Raise Docker Desktop memory, or stop here.\n' >&2
    k get pods -A --field-selector status.phase=Pending \
      -o custom-columns=NS:.metadata.namespace,POD:.metadata.name --no-headers 2>/dev/null | head -5 >&2
    return 1
  fi

  if [ "$S_PCT" -ge "$STOP_PCT" ]; then
    printf '\nSTOP: node containers are at %s%% of Docker memory (threshold %s%%).\n' "$S_PCT" "$STOP_PCT" >&2
    printf 'The next layer would likely start evicting. Raise Docker memory, or stop here.\n' >&2
    printf 'Override with STOP_PCT=95 if you want to push further on purpose.\n' >&2
    return 1
  fi
  return 0
}

record() {
  [ -f "$LOG" ] || printf 'date\tstep\tseconds\tpods\tnot_ready\tmem_used_mib\tmem_limit_mib\tpct\tresult\n' > "$LOG"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DATE" "$1" "$2" "$S_PODS" "$S_NOTREADY" "$S_USED" "$S_LIMIT" "$S_PCT" "$3" >> "$LOG"
}

# The LAST row for each step decides, not any row. `$9=="ok"` over every row
# meant a step recorded ok on Monday and failed today still counted as done, so
# `next` and `all` skipped it. The tracked log already holds four failed-then-ok
# pairs, so both orders occur in practice.
#
# No `|| true` on the awk: a log that cannot be read is not the same as a log with
# no ok rows, and swallowing that made every step look undone.
done_steps() {
  [ -f "$LOG" ] || return 0
  awk -F'\t' 'NR>1 {last[$2]=$9} END {for (s in last) if (last[s]=="ok") print s}' "$LOG"
}

is_done() {
  local s
  for s in $(done_steps); do [ "$s" = "$1" ] && return 0; done
  return 1
}

run_step() {
  local id cmd started elapsed
  id="$1"
  cmd="$(step_cmd "$id")"
  [ -n "$cmd" ] || { printf 'step-up: no such step: %s\n' "$id" >&2; exit 1; }

  [ "$id" = "cluster" ] || assert_context

  printf '\n=== step %s\n    %s\n' "$id" "$cmd"
  started=$SECONDS
  if ! eval "$cmd"; then
    elapsed=$((SECONDS - started))
    sample || true
    record "$id" "$elapsed" "failed"
    printf '\nstep %s FAILED after %ss. Recorded in %s.\n' "$id" "$elapsed" "$LOG" >&2
    exit 1
  fi
  elapsed=$((SECONDS - started))
  printf '    done in %ss\n' "$elapsed"

  # ONE sample, then both the log row and the printed guard read it. The number
  # the operator sees and the number the log keeps are now the same number.
  #
  # If it cannot be measured, say so and STOP. Recording "ok" here was wrong on
  # two counts, both introduced and both found on 2026-08-20. It returned 0, so
  # the `all` loop carried on to the next layer with the guard switched off - and
  # stopping before the machine wedges is this script's only job. And it wrote a
  # row of zeros into a tracked file, indistinguishable from a real measurement of
  # an idle cluster. This repository's rule is that an undated number is invalid;
  # a number that was never measured at all is worse.
  if ! sample; then
    printf '    cannot measure - Docker or the cluster did not answer\n' >&2
    record "$id" "$elapsed" "unmeasured"
    return 1
  fi

  # guard BEFORE record, so the verdict lands in the log. The other order meant a
  # step that tripped the STOP was written as `ok`, and re-running `all` then
  # skipped that layer with its guard never re-evaluated. Confirmed 2026-08-20
  # with a forced STOP: three steps recorded ok, and the second invocation
  # skipped all three.
  if guard; then
    record "$id" "$elapsed" "ok"
    return 0
  fi
  record "$id" "$elapsed" "stopped"
  # Exit 3, not 1, so a deliberate stop is distinguishable from a step that
  # failed. Both were exit 1, which left task and CI unable to tell "the guard
  # protected you" from "the install broke".
  exit 3
}

usage() {
  cat <<'EOF'
tools/step-up.sh — bring the stack up one layer at a time, with a memory guard.

  list            show every step, and which are already recorded ok
  next            run the next step that is not recorded ok, then measure
  all             run `next` repeatedly until a step fails or the guard stops
  <step-id>       run exactly that step (re-runs it even if already ok)
  measure         measure now without installing anything

Environment:
  STOP_PCT=85     stop when node containers exceed this % of Docker memory

Every run appends a dated row to docs/deployment-log.tsv. Numbers in this
repository are invalid without the date they were measured, so the log is the
record and a comment is not.
EOF
}

case "${1:-list}" in
  list)
    printf '%-18s %s\n' "STEP" "STATUS"
    for id in $(step_ids); do
      if is_done "$id"; then printf '%-18s ok\n' "$id"; else printf '%-18s -\n' "$id"; fi
    done
    ;;
  measure)
    if sample; then
      guard || true
    else
      printf 'step-up: cannot measure. The Docker daemon did not answer, so\n' >&2
      printf 'there is no memory limit to compare against and no cluster to query.\n' >&2
      printf 'Start Docker Desktop and try again.\n' >&2
      exit 1
    fi
    ;;
  next)
    for id in $(step_ids); do
      if ! is_done "$id"; then run_step "$id"; exit 0; fi
    done
    printf 'every step is already recorded ok in %s\n' "$LOG"
    ;;
  all)
    for id in $(step_ids); do
      is_done "$id" && continue
      run_step "$id"
    done
    printf '\nall steps completed. Log: %s\n' "$LOG"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    run_step "$1"
    ;;
esac
