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

# require_arm64 <image ref> — fails when no linux/arm64 manifest exists
require_arm64() {
  docker buildx imagetools inspect "$1" 2>/dev/null | grep -q 'linux/arm64'
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
