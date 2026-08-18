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

@test "free tier client gets a token carrying tier=free" {
  run bash -c "source tests/lib/helpers.bash && get_token llm-tier-free | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .tier"
  [ "$output" = "free" ]
}

@test "pro tier client gets a token carrying tier=pro" {
  run bash -c "source tests/lib/helpers.bash && get_token llm-tier-pro | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .tier"
  [ "$output" = "pro" ]
}
