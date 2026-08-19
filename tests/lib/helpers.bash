# Shared assertions for every bats suite.
export KUBECTL_CONTEXT="kind-llm-serving-stack"
export API_HOST="llm.localtest.me"

k() { kubectl --context "$KUBECTL_CONTEXT" "$@"; }

# wait_for <seconds> <description> <command...>
wait_for() {
  local timeout="$1"; local what="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "timed out after ${timeout}s waiting for: $what" >&2
      return 1
    fi
    sleep 3
  done
}

# require_arm64 <image ref> — fails when no linux/arm64 manifest exists.
#
# A tag reference (e.g. repo:server) usually resolves to a manifest LIST: the
# plain `imagetools inspect` output prints one "Platform: linux/arm64" line
# per architecture, so grepping that text works.
#
# A digest reference (e.g. repo@sha256:...) — which is how every image in
# versions.yaml is pinned — resolves to a single manifest. Plain
# `imagetools inspect` output for a single manifest has no Platform: line at
# all to grep for, so that same grep silently reports "not arm64" for every
# correctly pinned arm64 image. `--format '{{json .Image}}'` avoids this: for
# a single manifest it returns the image config directly, with a top-level
# "architecture" field; for a manifest list with more than one real platform
# it returns an object keyed by "os/arch" (e.g. "linux/arm64") instead.
require_arm64() {
  local ref="$1"
  local json
  json=$(docker buildx imagetools inspect --format '{{json .Image}}' "$ref" 2>/dev/null) || return 1
  jq -e '
    if has("architecture") then .architecture == "arm64"
    else has("linux/arm64")
    end
  ' >/dev/null 2>&1 <<<"$json"
}

# jwt_payload <jwt> - prints the decoded payload (the middle segment) as JSON.
#
# A JWT payload is base64URL and unpadded (RFC 7515 section 2). Two things
# follow, and tests/smoke/03-identity.bats got both wrong before 2026-08-19:
#
#   1. `base64 -d` decodes standard base64. The base64url alphabet swaps
#      `+`/`/` for `-`/`_`, so any token whose payload happens to contain one
#      of those characters decodes to garbage.
#   2. Without padding, `base64 -d` silently drops the trailing bytes of the
#      last group. Confirmed on this machine, 2026-08-19: an unpadded payload
#      encoding `{"tier": "free", "sub": "a?b>c~d"}` came back as
#      `{"tier": "free", "sub": "a?b>c~d"` - the closing brace gone, so the
#      `jq` that follows fails to parse. The old test hid both failures
#      behind `2>/dev/null` and then compared an empty string.
#
# `jq -R 'split(".")[1] | @base64d'` is not a fix either: jq 1.7.1's @base64d
# rejects the base64url alphabet outright ("string ... is not valid base64
# data"), checked on this machine the same day. So the alphabet is translated
# and the padding restored here, and the result is piped to jq as normal JSON.
jwt_payload() {
  local payload
  payload="$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')"
  case $((${#payload} % 4)) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  printf '%s' "$payload" | base64 -d
}

# get_token <client-id> — client credentials grant, prints the access token.
# The client secret is read from the environment, never from git.
get_token() {
  local client="$1"
  local secret_var="KC_SECRET_${client//-/_}"
  local secret="${!secret_var:-devsecret}"
  curl -sf -X POST "http://${API_HOST}/realms/llm/protocol/openid-connect/token" \
    -d grant_type=client_credentials \
    -d "client_id=${client}" \
    -d "client_secret=${secret}" | jq -r .access_token
}
