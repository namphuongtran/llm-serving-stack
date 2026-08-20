#!/usr/bin/env bash
# Shared by the install scripts. Source it, do not execute it.
#
# `helm --wait` and `kubectl rollout status` do not wait for an admission
# webhook to be reachable, so the next `kubectl apply` can fail with
# `connection refused` milliseconds later. Four CI runs died this way on
# 2026-08-20; docs/STATUS.md, "The webhook readiness race", is the record.
#
# apply_retry retries ONLY that. A policy denial fails immediately, because a
# rejected manifest is a finding this repository wants to see.

# Seconds to keep retrying a webhook that is not answering yet.
: "${APPLY_RETRY_TIMEOUT:=180}"

# usage: apply_retry <file>        apply one file
#        cmd | apply_retry -       apply stdin (buffered, so a retry can re-read it)
apply_retry() {
  local src="$1" file rc out started attempt=0
  started=$SECONDS

  if [ "$src" = "-" ]; then
    file="$(mktemp -t apply-retry)"
    # shellcheck disable=SC2064
    trap "rm -f '$file'" RETURN
    cat > "$file"
  else
    file="$src"
  fi

  while :; do
    attempt=$((attempt + 1))
    set +e
    out="$(kubectl apply -f "$file" 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      [ "$attempt" -eq 1 ] || echo "apply_retry: $src succeeded on attempt $attempt" >&2
      return 0
    fi

    # A webhook that answered and said no. Never retry this.
    case "$out" in
      *"denied the request"*)
        printf '%s\n' "$out" >&2
        echo "apply_retry: admission denied, not retrying - this is a finding, not a race" >&2
        return "$rc"
        ;;
    esac

    # A webhook that could not be reached. Retry until the wall clock runs out.
    case "$out" in
      *"failed calling webhook"*|*"no endpoints available"*)
        if [ $((SECONDS - started)) -ge "$APPLY_RETRY_TIMEOUT" ]; then
          printf '%s\n' "$out" >&2
          echo "apply_retry: webhook still unreachable after ${APPLY_RETRY_TIMEOUT}s, $attempt attempts" >&2
          return "$rc"
        fi
        [ "$attempt" -gt 1 ] || echo "apply_retry: webhook not reachable yet, retrying $src" >&2
        sleep 2
        ;;
      *)
        printf '%s\n' "$out" >&2
        return "$rc"
        ;;
    esac
  done
}
