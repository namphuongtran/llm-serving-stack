# Contract tests

Asserts the engine contract from the design spec, so that swapping engines is
safe:

- `GET /v1/models` shape.
- `POST /v1/chat/completions`, streaming and non-streaming.
- Readiness reports true only after weights are loaded.
- `/metrics` exposes the minimum required series.
