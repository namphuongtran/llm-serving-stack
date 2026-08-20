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
  local src="$1" file tmp="" rc out started attempt=0
  started=$SECONDS

  if [ "$src" = "-" ]; then
    # A full template ending in X's, not `mktemp -t apply-retry`. BSD mktemp on
    # macOS accepts a bare prefix; GNU coreutils on the CI runners rejects it
    # with "too few X's in template".
    tmp="$(mktemp "${TMPDIR:-/tmp}/apply-retry.XXXXXX")" || return 1
    file="$tmp"
    cat > "$file"
  else
    file="$src"
  fi

  # No `trap ... RETURN`: zsh, which is what macOS gives a human sourcing this
  # by hand, has no such signal and prints an error. Clean up explicitly.
  while :; do
    attempt=$((attempt + 1))
    set +e
    out="$(kubectl apply -f "$file" 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      [ "$attempt" -eq 1 ] || echo "apply_retry: $src succeeded on attempt $attempt" >&2
      [ -z "$tmp" ] || rm -f "$tmp"
      return 0
    fi

    # A webhook that answered and said no. Never retry this.
    case "$out" in
      *"denied the request"*)
        printf '%s\n' "$out" >&2
        echo "apply_retry: admission denied, not retrying - this is a finding, not a race" >&2
        [ -z "$tmp" ] || rm -f "$tmp"
        return "$rc"
        ;;
    esac

    # A webhook that could not be reached. Retry until the wall clock runs out.
    case "$out" in
      *"failed calling webhook"*|*"no endpoints available"*)
        if [ $((SECONDS - started)) -ge "$APPLY_RETRY_TIMEOUT" ]; then
          printf '%s\n' "$out" >&2
          echo "apply_retry: webhook still unreachable after ${APPLY_RETRY_TIMEOUT}s, $attempt attempts" >&2
          [ -z "$tmp" ] || rm -f "$tmp"
          return "$rc"
        fi
        [ "$attempt" -gt 1 ] || echo "apply_retry: webhook not reachable yet, retrying $src" >&2
        sleep 2
        ;;
      *)
        printf '%s\n' "$out" >&2
        [ -z "$tmp" ] || rm -f "$tmp"
        return "$rc"
        ;;
    esac
  done
}
