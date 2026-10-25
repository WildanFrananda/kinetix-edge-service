# kinetix-edge-service

The estate's programmable application edge: OpenResty running Lua generated from Teal, behind the gateway
(`kinetix-infrastructure/docs/EDGE-SERVICE.md`). This version serves one case, **X14, the browser token handler**
for the backoffice and seller web applications (§10 there), plus health and metrics. Tokens never reach
JavaScript: the browser holds an opaque `HttpOnly` cookie, Redis holds identity's tokens, and identity stays the
only issuer.

## Routes

On port `8080`, plain HTTP on the Docker network. The gateway sends only `/bff/...` on the two application hosts.

| Method | Path | What it does |
| --- | --- | --- |
| `GET` | `/bff/session` | `{ authenticated, role, principalId, expiresAt }`, never a token; reading it does not extend the session |
| `POST` | `/bff/login` | `{ email, password }` → a session, or `{ mfaRequired: true }`, or (backoffice) `{ mfaEnrolmentRequired: true }` |
| `POST` | `/bff/2fa/verify` | `{ code }` → a session, from the pending challenge |
| `POST` | `/bff/2fa/setup` | the secret and QR URL to show, from the pending enrolment |
| `POST` | `/bff/2fa/enable` | `{ code }` → `{ enabled: true }`; the user then signs in again |
| `POST` | `/bff/logout` | logs out at identity with the refresh token, deletes the session, expires both cookies (`204`) |
| any of `GET HEAD POST PUT PATCH DELETE` | `/bff/api/<path>` | forwarded to `${EDGE_API_UPSTREAM}/api/<path>` with the session's bearer; identity's throttled routes (`/api/v1/auth`, `/api/v1/couriers`) go to `${IDENTITY_HTTP_URL}` directly |
| `GET` | `/health` | the process |
| `GET` | `/health/ready` | Redis answers `PING` as the edge user |

On port `9145`: `GET /metrics`.

Every answer carries `Cache-Control: no-store`. Every error is `{ error, message, requestId }`:

| Status | `error` |
| --- | --- |
| 400 | `INVALID_REQUEST`, `CLIENT_ADDRESS_REQUIRED` |
| 401 | `SIGN_IN_REFUSED`, `CODE_REFUSED`, `SIGN_IN_REQUIRED`, `SESSION_REQUIRED`, `SESSION_ENDED` |
| 403 | `CSRF_REFUSED`, `ROLE_REFUSED` |
| 404, 405 | `NOT_FOUND`, `METHOD_NOT_ALLOWED` (with `Allow`) |
| 409 | `TWO_FACTOR_ALREADY_ENABLED` |
| 413, 414, 415, 431 | `PAYLOAD_TOO_LARGE`, `URI_TOO_LONG`, `JSON_REQUIRED`, `HEADERS_TOO_LARGE` |
| 429 | `SIGN_IN_DELAYED`, `TOO_MANY_REQUESTS` (identity's, with its `Retry-After`) |
| 500, 502 | `INTERNAL_ERROR`, `IDENTITY_FAILED` |
| 503 | `SESSION_STORE_UNAVAILABLE`, `IDENTITY_UNAVAILABLE`, `API_UNAVAILABLE` |

## Applications

| App | Client name to identity | Roles | Idle / absolute | Cookie |
| --- | --- | --- | --- | --- |
| backoffice | `backoffice` | `admin` | 15 min / 8 h | browser-session (no `Max-Age`) |
| seller web | `seller-web` | `seller`, `customer` | 7 days / 30 days | `Max-Age` = 30 days |

The policy is code: `config/apps.tl`, `config/lifetimes.tl`, `config/timing.tl`, `config/forwarding.tl`.

## Configuration

Every variable is required; `.env.example` documents each. `EDGE_REDIS_HOST`, `EDGE_REDIS_PORT`, `EDGE_REDIS_USER`,
`EDGE_REDIS_PASSWORD`, `IDENTITY_HTTP_URL`, `EDGE_API_UPSTREAM`, `KINETIX_BACKOFFICE_HOST`, `KINETIX_SELLER_HOST`, and
`KINETIX_SERVICE_VERSION` (baked from the build argument of that name).

The Redis ACL user the edge needs, exactly (the integration suite runs under it):

```
user edge on >PASSWORD ~edge:* resetchannels -@all +auth +ping +get +set +del +hset +hgetall +pexpire +multi +exec
```

Keys: `edge:session:<sha256 of the cookie>` (hash, idle TTL), `edge:pending:<sha256>` (hash, identity's challenge or
enrolment lifetime), `edge:refresh:<sha256>` (string, 15 s single-flight lock). Every key has a TTL.

## Metrics

`kinetix_http_requests_total{method,route,status}`, `kinetix_http_request_duration_seconds{method,route}`,
`kinetix_build_info{service="kinetix-edge-service",version}`, and, pre-published at zero:
`kinetix_edge_sessions_started_total{app}`, `kinetix_edge_sessions_ended_total{app,reason}`,
`kinetix_edge_refreshes_total{app,outcome}`, `kinetix_edge_csrf_refusals_total{app,reason}`,
`kinetix_edge_dependency_failures_total{dependency}`. `route` is the route template (`/bff/api/{path}`), never a raw
path.

## Everything runs in Docker

```sh
bin/dev sh bin/check         # tl check on every file, no any, no comments, 120 columns
bin/dev sh bin/build         # check, then generate build/lua (the service) and build/test
bin/dev sh bin/unit          # busted under resty
bin/dev sh bin/integration   # real OpenResty with the generated Lua, real Redis under the edge's ACL, fakes
bin/dev sh bin/ci            # build, unit, integration: the gate CI runs
bin/dev sh bin/mutate        # every security check mutated once; each must turn a test red
bin/dev down
```

`toolchain/Dockerfile` is the pinned OpenResty fat image plus `bin/install-toolchain` (Teal 0.24.8, busted 2.3.0,
lua-resty-http 0.18.0 and their dependencies, each checksummed). The production `Dockerfile` compiles with the same
script and runs the generated Lua on the same OpenResty build, as `edge` (uid 10001).

## Layout

```text
src/http/       routes, policies, sessions, sign-in, forwarding
src/adapters/   Redis, identity, HTTP, metrics, logging, environment
src/types/      one record or enum per file
config/         the policy, as code
declarations/   Teal declarations for OpenResty's API and the libraries used
nginx/          nginx.conf
tests/          unit, integration (fakes, scenarios), mutation
bin/            dev, check, build, unit, integration, test, ci, mutate, install-toolchain
```
