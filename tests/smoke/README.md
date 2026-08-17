# Smoke tests

End to end, in order:

1. Obtain a JWT from Keycloak.
2. Stream a chat completion and assert tokens arrive.
3. Call without a JWT and assert 401.
4. Exceed the token quota and assert 429.
