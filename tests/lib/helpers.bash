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
