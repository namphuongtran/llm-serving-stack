#!/usr/bin/env bash
# Fails before anything is installed, with a message that says what to do.
set -euo pipefail

fail() { printf 'preflight: %s\n' "$1" >&2; exit 1; }

for t in kubectl helm kind task yq jq bats kustomize docker; do
  command -v "$t" >/dev/null || fail "missing tool: $t (brew install $t)"
done

docker info >/dev/null 2>&1 || fail "docker is not running"

cpus=$(docker info --format '{{.NCPU}}')
mem_gib=$(docker info --format '{{.MemTotal}}')
mem_gib=$((mem_gib / 1073741824))
[ "$cpus" -ge 8 ] || fail "docker has $cpus cpus, need 8 (Docker Desktop > Settings > Resources)"
[ "$mem_gib" -ge 19 ] || fail "docker has ${mem_gib}GiB, need 20 (Docker Desktop > Settings > Resources)"

arch=$(uname -m)
[ "$arch" = "arm64" ] || printf 'preflight: warning: arch is %s, this plan assumes arm64\n' "$arch"

printf 'preflight: ok (%s cpus, %sGiB, %s)\n' "$cpus" "$mem_gib" "$arch"
