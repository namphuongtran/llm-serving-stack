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

# Every platform/*/install.sh names its chart by repo alias, so a present
# `helm` binary is not enough: without these aliases the first install script
# dies with "Error: repo <name> not found". `task helm:repos` adds all eight
# (and `task local:up` depends on it); this check is what makes a missing one
# fail here, with the fix named, instead of halfway through an install.
#
# kyverno joined the list on 2026-08-19, when platform/12-kyverno/install.sh
# was written. Before that the policy engine had no imperative installer, so
# nothing here needed the alias.
missing_repos=""
for repo in jetstack istio kedacore prometheus-community open-telemetry kuadrant argo kyverno; do
  helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$repo" || missing_repos="$missing_repos $repo"
done
[ -z "$missing_repos" ] || fail "missing helm repos:$missing_repos (run: task helm:repos)"

arch=$(uname -m)
[ "$arch" = "arm64" ] || printf 'preflight: warning: arch is %s, this plan assumes arm64\n' "$arch"

printf 'preflight: ok (%s cpus, %sGiB, %s)\n' "$cpus" "$mem_gib" "$arch"
