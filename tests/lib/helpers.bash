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
