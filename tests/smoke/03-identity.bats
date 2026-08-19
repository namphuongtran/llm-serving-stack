setup() { load '../lib/helpers'; }

@test "issuer is reachable and self-reports the shared hostname" {
  run bash -c "curl -sf http://llm.localtest.me/realms/llm | jq -r .issuer"
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
