#!/usr/bin/env bash
# What `task token` runs. Prints one access token on stdout and nothing else,
# so it composes - TOKEN="$(./tools/token.sh)".
#
# The grant is get_token in tests/lib/helpers.bash, sourced rather than
# reimplemented. bench/run.sh and bench/recovery-drill.sh already source that
# helper for the same reason, so a client script reaching into it is the
# established pattern here, not a new one. One implementation of the grant,
# not three.
#
# Why this is a script and not inline in Taskfile.yml: go-task 3.53.1 rejects
# a colon followed by a space inside a cmds string, and
# `-H "Authorization: Bearer ..."` contains one. Confirmed on this machine
# 2026-08-19 - a Taskfile carrying that header fails `task --list` for the
# whole file with "invalid keys in command", not just for the one task.
set -euo pipefail
cd "$(dirname "$0")/.."

CLIENT="${1:-llm-tier-pro}"

# The realm defines exactly these two clients, both service accounts with a
# hardcoded `tier` claim (platform/15-keycloak/realm-export.json). Checking
# here turns a typo into one clear line instead of a curl that returns
# `{"error":"invalid_client"}` and a token of `null`.
case "$CLIENT" in
  llm-tier-free|llm-tier-pro) ;;
  *)
    echo "unknown client - $CLIENT" >&2
    echo "the realm defines llm-tier-free and llm-tier-pro" >&2
    exit 1
    ;;
esac

source tests/lib/helpers.bash

TOKEN="$(get_token "$CLIENT" || true)"

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "no access token returned for $CLIENT" >&2
  echo "check that Keycloak answers at http://${API_HOST}/realms/llm" >&2
  echo "and that the client secret is right - get_token reads" >&2
  echo "KC_SECRET_${CLIENT//-/_} from the environment and falls back to devsecret" >&2
  exit 1
fi

# The realm sets accessTokenLifespan: 900, so this token is valid for 15
# minutes. Fetch a new one rather than storing this anywhere.
printf '%s\n' "$TOKEN"
