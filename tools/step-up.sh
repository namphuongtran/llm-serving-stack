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
# can drift away from the two tracked paths. The three steps that call
# `kubectl apply` directly are the three that have no imperative script at all -
# see STEP TABLE below.
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
  docker info --format '{{.MemTotal}}' | awk '{printf "%d", $1/1048576}'
}

# Sum of resident memory across every container whose name starts with the
# cluster name. kind names them <cluster>-control-plane, <cluster>-worker, ...
node_mem_used_mib() {
  local total=0 line val unit
  for line in $(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null \
                | grep "^${CLUSTER}-" | sed 's/.*|//' | awk '{print $1}'); do
    val="$(printf '%s' "$line" | sed 's/[A-Za-z]*$//')"
    unit="$(printf '%s' "$line" | sed 's/^[0-9.]*//')"
    case "$unit" in
      GiB|GB) val="$(awk -v v="$val" 'BEGIN{printf "%d", v*1024}')" ;;
      MiB|MB) val="$(awk -v v="$val" 'BEGIN{printf "%d", v}')" ;;
      KiB|kB) val="$(awk -v v="$val" 'BEGIN{printf "%d", v/1024}')" ;;
      B|"")   val=0 ;;
    esac
    total=$((total + val))
  done
  printf '%d' "$total"
}

pod_count()     { k get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' '; }
not_ready()     { k get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' | wc -l | tr -d ' '; }

# Pods the scheduler could not place. This is the signal that matters most:
# it is the difference between "slow" and "will never finish".
insufficient() {
  k get events -A --field-selector reason=FailedScheduling -o json 2>/dev/null \
    | jq -r '[.items[] | select(.message | test("Insufficient (memory|cpu)"))] | length' 2>/dev/null \
    || printf '0'
}

CLUSTER="$(yq -r '.name' prereqs/kind-cluster.yaml)"

# ---------------------------------------------------------------------------
# The guard. Called AFTER each step. Exits non-zero when continuing would be
# a waste of the operator's time, and says which of the two reasons it is.
# ---------------------------------------------------------------------------
guard() {
  local limit used pct unplaced
  limit="$(docker_mem_limit_mib)"
  used="$(node_mem_used_mib)"
  pct=$((used * 100 / limit))
  unplaced="$(insufficient)"

  printf '  memory  %s MiB of %s MiB (%s%%)\n' "$used" "$limit" "$pct"
  printf '  pods    %s total, %s not running\n' "$(pod_count)" "$(not_ready)"

  if [ "$unplaced" -gt 0 ]; then
    printf '\nSTOP: %s pod(s) cannot be scheduled for Insufficient memory or cpu.\n' "$unplaced" >&2
    printf 'This is a hard wall, not slowness. Raise Docker Desktop memory, or stop here.\n' >&2
    k get events -A --field-selector reason=FailedScheduling \
      -o custom-columns=NS:.metadata.namespace,OBJ:.involvedObject.name,MSG:.message \
      --no-headers 2>/dev/null | head -5 >&2
    return 1
  fi

  if [ "$pct" -ge "$STOP_PCT" ]; then
    printf '\nSTOP: node containers are at %s%% of Docker memory (threshold %s%%).\n' "$pct" "$STOP_PCT" >&2
    printf 'The next layer would likely start evicting. Raise Docker memory, or stop here.\n' >&2
    printf 'Override with STOP_PCT=95 if you want to push further on purpose.\n' >&2
    return 1
  fi
  return 0
}

record() {
  [ -f "$LOG" ] || printf 'date\tstep\tseconds\tpods\tnot_ready\tmem_used_mib\tmem_limit_mib\tpct\tresult\n' > "$LOG"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DATE" "$1" "$2" "$(pod_count)" "$(not_ready)" \
    "$(node_mem_used_mib)" "$(docker_mem_limit_mib)" \
    "$(( $(node_mem_used_mib) * 100 / $(docker_mem_limit_mib) ))" "$3" >> "$LOG"
}

done_steps() { [ -f "$LOG" ] && awk -F'\t' 'NR>1 && $9=="ok" {print $2}' "$LOG" || true; }

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
    record "$id" "$elapsed" "failed"
    printf '\nstep %s FAILED after %ss. Recorded in %s.\n' "$id" "$elapsed" "$LOG" >&2
    exit 1
  fi
  elapsed=$((SECONDS - started))
  printf '    done in %ss\n' "$elapsed"
  record "$id" "$elapsed" "ok"
  guard
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
    guard || true
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
