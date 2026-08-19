setup() { load '../lib/helpers'; }

# CORRECTED 2026-08-19, on the first run this suite ever had. It queried
# `/realms/llm` and read `.issuer` from it. That endpoint returns Keycloak's realm
# info document, whose keys are account-service, public_key, realm, token-service,
# and tokens-not-before - there is no `issuer` field, so `jq -r .issuer` printed
# `null` and the equality check could never pass. Read from the live response,
# which is HTTP 200 and 585 bytes.
#
# `issuer` lives on the DISCOVERY document, and that is also the document
# Authorino fetches, so asserting it here checks the same fact the AuthPolicy
# depends on.
@test "the discovery document self-reports the shared hostname as its issuer" {
  run bash -c "curl -sf http://llm.localtest.me/realms/llm/.well-known/openid-configuration | jq -r .issuer"
  [ "$status" -eq 0 ]
  [ "$output" = "http://llm.localtest.me/realms/llm" ]
}

@test "JWKS endpoint returns at least one signing key" {
  run bash -c "curl -sf http://llm.localtest.me/realms/llm/protocol/openid-connect/certs | jq '.keys | length'"
  [ "$output" -ge 1 ]
}

# jwt_payload (tests/lib/helpers.bash) handles the base64url alphabet and the
# missing padding that `base64 -d` alone gets wrong; see its comment. No
# `2>/dev/null` here either - a decode failure must be visible, not swallowed.
@test "free tier client gets a token carrying tier=free" {
  run bash -c "source tests/lib/helpers.bash && jwt_payload \"\$(get_token llm-tier-free)\" | jq -r .tier"
  [ "$status" -eq 0 ]
  [ "$output" = "free" ]
}

@test "pro tier client gets a token carrying tier=pro" {
  run bash -c "source tests/lib/helpers.bash && jwt_payload \"\$(get_token llm-tier-pro)\" | jq -r .tier"
  [ "$status" -eq 0 ]
  [ "$output" = "pro" ]
}

# THE POD-SIDE VIEW. Added 2026-08-19, after a live cluster returned 401 for
# every valid token while every test above passed.
#
# The tests above all ask from the HOST. Authorino asks from a POD, and it must
# fetch the issuer's discovery document itself before it can verify anything.
# `llm.localtest.me` is a public name resolving to 127.0.0.1, so inside a pod it
# meant the pod, and Authorino logged:
#   dial tcp [::1]:80: connect: connection refused
#   -> UNAUTHENTICATED, "missing openid connect configuration"
# platform/10-istio/coredns-rewrite.yaml is the fix. This test is the guard, and
# it is written from the pod side on purpose: a host-side check cannot see this
# class of failure at all.
#
# --attach is required with --rm; without it kubectl refuses the command outright
# and the test would fail for the wrong reason.
@test "the issuer resolves to the gateway from inside the cluster" {
  # Assert WHICH address, not merely that resolution succeeds. The first version
  # of this test asserted only that `getent hosts` exited 0, and a mutation run on
  # 2026-08-19 showed that passes with the rewrite REMOVED: without it the name
  # still resolves, via the upstream forwarder, to 127.0.0.1. The test was
  # satisfied by the wrong answer, which is the exact defect class this suite
  # exists to catch.
  gw="$(k -n istio-system get svc llm-istio -o jsonpath='{.spec.clusterIP}')"
  [ -n "$gw" ] || fail "gateway Service llm-istio has no ClusterIP"

  run k -n kube-system run identity-dns-probe-$$ --rm --attach --restart=Never --quiet \
    --image=curlimages/curl:8.21.0@sha256:56bc0130aabaada5c04bb18d8d7f75e7a78fbcaa38ad44e1811c8c7720606d84 \
    --command -- sh -c "getent hosts ${API_HOST} | grep -q '^${gw} '"
  [ "$status" -eq 0 ] || fail "$API_HOST does not resolve to the gateway ($gw) in-cluster; Authorino will 401 every valid token. Output: $output"
}

@test "a pod can fetch the OIDC discovery document, which is what Authorino does" {
  # The assertion runs INSIDE the pod and the test reads only the exit code.
  # Reading $output here was flaky: with --rm --attach, kubectl sometimes cannot
  # attach ("falling back to streaming logs") and --rm deletes the pod before the
  # logs are captured, leaving $output empty on a healthy cluster. The exit code
  # does not have that race - verified 2026-08-19, 0 when the name resolves and 2
  # when it does not.
  #
  # grep -q on the issuer string, so this fails both when discovery is
  # unreachable AND when it reports an issuer the AuthPolicy would reject.
  run k -n kube-system run identity-oidc-probe-$$ --rm --attach --restart=Never --quiet \
    --image=curlimages/curl:8.21.0@sha256:56bc0130aabaada5c04bb18d8d7f75e7a78fbcaa38ad44e1811c8c7720606d84 \
    --command -- sh -c "curl -sf --max-time 15 http://${API_HOST}/realms/llm/.well-known/openid-configuration | grep -q '\"issuer\":\"http://${API_HOST}/realms/llm\"'"
  [ "$status" -eq 0 ] || fail "in-cluster OIDC discovery failed, or reported an issuer the AuthPolicy does not expect. Authorino would 401 every token. Output: $output"
}
