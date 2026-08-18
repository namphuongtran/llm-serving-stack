setup() {
  load '../lib/helpers'
  BASE="http://llm.localtest.me"
}

chat() { # chat <token> <max_tokens>
  curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/chat/completions" \
    -H "authorization: Bearer $1" -H 'content-type: application/json' \
    -d "{\"model\":\"ornith-9b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":$2}"
}

@test "no token is rejected with 401" {
  run bash -c "curl -s -o /dev/null -w '%{http_code}' $BASE/v1/models"
  [ "$output" = "401" ]
}

@test "a forged token is rejected with 401" {
  run bash -c "curl -s -o /dev/null -w '%{http_code}' -H 'authorization: Bearer not.a.jwt' $BASE/v1/models"
  [ "$output" = "401" ]
}

@test "a valid token is accepted" {
  token=$(get_token llm-tier-pro)
  run chat "$token" 16
  [ "$output" = "200" ]
}

@test "the free tier is cut off with 429 once its token budget is spent" {
  token=$(get_token llm-tier-free)
  code=200
  for i in $(seq 1 40); do
    code=$(chat "$token" 64)
    [ "$code" = "429" ] && break
  done
  [ "$code" = "429" ]
}

@test "the pro tier still works after the free tier is limited" {
  token=$(get_token llm-tier-pro)
  run chat "$token" 16
  [ "$output" = "200" ]
}
