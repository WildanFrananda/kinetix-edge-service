# CLAUDE.md — kinetix-edge-service

The design of record is `kinetix-infrastructure/docs/EDGE-SERVICE.md` §10 (X14). This file holds the decisions the
code states but cannot explain. The gate is `bin/dev sh bin/ci`, then `bin/dev sh bin/mutate`.

## A session is a hash keyed by the cookie's SHA-256

The cookie is 32 bytes from `resty.random` (strong), base64url, 43 characters; Redis never sees it. A value that is not
43 base64url characters, or a cookie name sent twice, reads as no cookie: a second copy (a sibling host cannot set a
`__Host-` cookie, but a browser extension or a bug can) must never decide which session is used. The hash is
written in `MULTI`/`EXEC` with its `PEXPIRE`, so no key exists without a TTL. Partial updates (`last_seen`, the
refreshed tokens) touch only their fields: rewriting the whole session could put back a refresh token a concurrent
refresh just spent, and the next refresh would be read as reuse and end the family.

## The seller web's cookie persists, the backoffice's does not

§10 names the attributes; it does not name `Max-Age`. The backoffice cookie has none, so it dies with the browser
(the strict app). The seller web's carries `Max-Age` = the absolute lifetime (30 days), or the 7-day idle limit would
mean nothing once the browser closed. Redis decides validity either way.

## Reading the session is not using it

`GET /bff/session` reports and never extends the idle TTL or refreshes: an app that polls it would otherwise keep a
backoffice session alive for its whole 8 hours. Every `/bff/api` call is a use, and extends the TTL to
`min(idle, absolute end - now)`. The absolute end is enforced twice, by that bound and by a check on every lookup.

## One refresh per session, and the late claimer re-reads

Under 60 s left, a request claims `edge:refresh:<sha256>` with `SET NX PX 15000`. The lock outlives the worst identity
call (connect 1 s + send 2 s + read 5 s). The winner re-reads the session after claiming and refreshes only if it is
still stale, so a request that read the session before another worker renewed it never presents the spent token.
Waiters poll every 25 ms for up to 9 s, then read the session: renewed → use it; gone → `SESSION_ENDED`; still stale →
503. A refresh whose answer is lost after identity rotated (a read timeout) leaves a spent token in Redis; the next
refresh is reuse and ends the family. Nothing better is possible without identity's help.

## What a refresh answer means

200 with a pair → stored. 400/401/403 or any other refusal → the session is deleted, 401 `SESSION_ENDED`. A 200 that
cannot be read is also the end, because identity already spent the old token. Unreachable, 5xx, 429, and the client
refusals `UNKNOWN_CLIENT`, `CLIENT_REQUIRED`, `CLIENT_PROOF_*` → 503 and the session is kept: a misconfigured
`IDENTITY_CLIENTS` must not sign every user out. A refreshed role the app does not admit ends the session and logs it
out at identity.

## The role gate, and why the seller web takes no enrolment

The role comes from identity's answer (`user.role`), at sign-in and at every refresh. A refused role is logged out at
identity with the pair just issued. An enrolment answer carries no role, but identity gives one only to an admin
without a second factor, so the seller web (no admin) refuses it with `ROLE_REFUSED`; the enrolment token cannot be
logged out (identity's logout takes an access token) and expires in 600 s. A pending sign-in is bound to its kind and
app: an enrolment cannot answer `/bff/2fa/verify`, and using the wrong endpoint ends it.

## Outages are 503, and logout too

Redis is opened before identity is asked, so an unreachable store refuses a sign-in without spending an attempt on the
account's counter. Logout with identity unreachable answers 503 and keeps the session: "signed out" would be a definite
answer the edge could not give. Identity's 401/403 at logout means the tokens are already dead, so the session is
deleted. Once identity has revoked the tokens (204, 401 or 403), a Redis failure deleting the session still answers
204 with both cookies expired (2026-10-27): the user is signed out; the leftover hash dies with its TTL, and its
access token works only where a service checks the signature alone, for the rest of its 15 minutes. Any Redis error
closes the connection instead of pooling it: a connection left inside `MULTI`, or with a late reply in flight, would
poison the next request. An error reply (`NOPERM`, `OOM`, `READONLY`) is a failure too: `lua-resty-redis` returns
`false, err` for it, not `nil`, and until 2026-10-27 `redis_store` read it as success.

## A session crossing its absolute end mid-request has ended

`lookup` checks the absolute end, then `touch` computes the TTL from it a moment later. A session that crossed the end
in between is ended exactly as `lookup` would end it (deleted, counted, its tokens revoked) and answered 401
`SESSION_ENDED` with the cookie expired; 503 is kept for a write Redis refused (2026-10-27).

## The tokens of a session the edge ends without a logout are revoked

A session a new sign-in or sign-up replaces, and one `lookup` finds past its absolute end, is deleted and its refresh
family logged out at identity (2026-10-27). That runs in an `ngx.timer` after the request, so it never delays or
refuses the new sign-in; every outcome is counted (`kinetix_edge_session_revocations_total`: `revoked`,
`already_revoked`, `failed`) and a failure is logged. identity's logout takes a live access token, so a session with
under 60 s left is refreshed first and the new pair logged out; a refresh identity refuses means the family is already
dead. Known limit: a session Redis expires by its TTL (idle, or the absolute end the TTL is bounded by) is never seen
again, so its family lives until identity's refresh token expires. Only `lookup` racing that TTL, or a clock skew,
reaches the absolute-end path.

## Sign-up on the seller web

`POST /bff/register` (seller web only, 2026-10-27) takes identity's `RegisterUserInputDto` (`email`, `password`;
identity v1.3.1 checks 12 characters and 72 bytes) and calls identity directly as `/bff/login` does: `X-Kinetix-Client`,
the browser's address alone. identity's 201 carries a token pair, so the session starts through the same
`start_session` as a sign-in (role gate, fixation, cookie) and the answer is `201` with the session view. identity's
409 is `EMAIL_TAKEN`; its 400 is `INVALID_REQUEST` with identity's validation messages relayed in `message`, so the
form can say what to fix; 429 and outages map as at sign-in. `/api/v1/auth/register` under `/bff/api` stays refused.

## The seller web's merchant socket

`GET /bff/ws/v1/matching/merchant[/websocket]` (seller web only, 2026-10-27) checks, in order: a WebSocket upgrade
(426), `Origin` equal to the app's origin, absent included (403 `CSRF_REFUSED`: a browser always sends one, and a
cross-site page could otherwise open the socket with the cookie), a usable session, refreshed first as on `/bff/api`,
and a role in the app's `merchant_socket_roles` (403 `SELLER_REQUIRED`, the session kept: an applicant may use the
app, not the socket). Then `ngx.exec` hands the request to `@merchant_socket`, which proxies to `EDGE_API_UPSTREAM`
with `Host` the upstream's own (as the API forwarder sends it; the gateway's internal twin matches `Host:
kinetix-api-gateway`), the browser's headers off except the handshake's own, `Sec-WebSocket-Protocol: phoenix,
base64url.bearer.phx.<token>`, and no `Origin`: Phoenix 1.8.16's `check_origin` passes a request without one, and
matching admits only the API host. A JWT is `A-Z a-z 0-9 . - _`, whose base64 has none of `+ / - _`, so base64url and
the standard alphabet Phoenix decodes (`Base.decode64!/2`) agree. The browser is answered `phoenix` only if it offered
it (a browser fails a handshake naming a subprotocol it did not offer); whatever the upstream answered is dropped, so
the token never comes back. Idle timeouts are 90 s, above Phoenix's 60 s heartbeat window. `EDGE_API_UPSTREAM` must be
`http://`: nginx would not verify a TLS upstream here, and the API forwarder has no trust store either. Known limit:
matching checks the token once, at the upgrade, so an open socket outlives a logout or a session's end until it
closes.

## Two-factor refusals carry a code

identity's `2fa/verify` refusals are `401 { error, message }` (2026-10-27): `WRONG_CODE` is `CODE_REFUSED` and keeps
the pending sign-in; `CHALLENGE_EXHAUSTED`, `CHALLENGE_SPENT` and `CHALLENGE_INVALID` are `SIGN_IN_REQUIRED`, the
pending record deleted and its cookie expired. Any other 401, from an identity without the codes, keeps the old
mapping (`CODE_REFUSED`), so the edge may deploy first.

## Forgery checks come first

The order is route, method, app by host name, browser address, the route offered on that app (else 404), CSRF, JSON
body, then Redis. `OPTIONS` counts as state-changing (no CORS is answered). A non-JSON body is 415 `JSON_REQUIRED`,
counted as a CSRF refusal with reason `content_type`.

## The app is the host name; the origin is configured per face

The gateway preserves the browser's `Host`. The seller web has one host (`KINETIX_SELLER_HOST`, origin `https://` +
host). The backoffice has a list of origins, `KINETIX_BACKOFFICE_ORIGINS` (2026-10-28, infra `docs/BACKOFFICE.md` §10):
in production its onion service (`http://<address>.onion`) and the WireGuard fallback (`https://<tunnel address>`), in
the lab `https://backoffice.localhost:8443`. Each origin is a face of the one backoffice app, the same name, client,
roles, enrolment and lifetimes, so a session is a backoffice session whichever face started it; the `__Host-` cookie
keeps each face's sessions to its own host anyway. A request is matched to a face by host name without the port, and
its `Origin` must equal that face's origin exactly: an onion request carrying the tunnel's origin is a forgery.

`http://` is accepted only for a `.onion` host. Tor Browser treats an onion over http as a secure context, so the
`Secure` cookie still holds; anywhere else http would send the cookie in clear text, so start-up refuses it. Start-up
also refuses a host named twice (by name: the port does not tell faces apart) and one the seller web uses. A refused
entry is named by its position, never by its value, and the `configured` log line counts the faces instead of naming
them: the onion address stays out of the logs.

## The browser's address is the last X-Forwarded-For entry

The gateway is the edge's only peer and appends the address it saw; nothing before it is read, and an unusable last
entry is 400, never a fallback to an earlier one. Identity is called directly with that address alone, so identity's
one trusted hop is the edge.

## identity's throttled routes skip the gateway

identity counts `@nestjs/throttler` buckets per address behind exactly one trusted hop. Through the gateway's twin it
would see `<browser>, <edge>` and key every web user on the edge's address, one shared bucket. So `/bff/api` paths
under `forwarding.identity_paths` (`/api/v1/auth`, `/api/v1/couriers`: the controllers carrying `ThrottlerGuard`) go
straight to `IDENTITY_HTTP_URL` with the browser's address as the only `X-Forwarded-For` entry, the session's bearer,
the request id and the app's `X-Kinetix-Client`. The token-issuing routes stay refused before this choice. On this path
Kong's `jwt` plugin does not run: identity verifies every token itself (`JwtAuthGuard` is global, revocation included),
and the backoffice is reached only through its onion (client authorization at Tor) or the gateway's staff gate. `/api/v1/users` and
`/api/v1/sellers` are not throttled by identity and stay on the gateway; a throttle added there moves them onto the list.
Everything else goes to the gateway's internal listener, where the twin appends the edge's address, so a per-address
limit in another service sees the edge.

## What is forwarded

Request headers are a list (`config/forwarding.tl`); everything else stays behind, `Cookie`, `Authorization` and every
`X-Kinetix-*` included. `Host` is the upstream URL's own. The path is nginx's normalized `$uri` with each segment
re-escaped, so a decoded `%2F` becomes a separator and the refusal list sees exactly what is sent. identity's
token-issuing routes (login, register, refresh, logout, `2fa/verify`, courier registration) are refused with 404: a
forwarded answer must never hand a token to JavaScript. `Set-Cookie`, hop-by-hop and cache headers are dropped.

A state change with no body (the backoffice's approve and reject, `POST /api/v1/sellers/{id}/verify` and the like) is
forwarded with an empty body and `Content-Length: 0`. Until 2026-10-29 the forwarder turned an empty body into `nil`,
and lua-resty-http 0.18.0 refuses `nil` for `POST`, `PUT` and `PATCH` before it connects ("Request body is nil but POST
method expects a body"); the refusal came back as `reached = false`, so every such call was answered 503
`API_UNAVAILABLE` within milliseconds, an outage that was the edge's own fault. Found when the backoffice's first
approve was pressed in the lab. `forwarding_spec.tl` sends all four methods without a body.

## Logs and metrics

One JSON line per request to stderr (method, route template, status, duration, request id, app, and an 8-hex prefix of
the cookie's SHA-256). No body, cookie, token, email, password or code is ever logged; the integration harness greps
the edge's log for every cookie value it received and for the fakes' tokens, emails and codes. `service` is a label
only on `kinetix_build_info` (`kinetix-edge-service`), as in every service: Prometheus sets it per target, and an
exposed `service` label would collide with it.

## Teal here

Data shapes are one record or enum per file in `src/types`; a module's own record (`local record sessions`) is its
namespace. `x is integer` compiles to `math.type`, which LuaJIT lacks; `bin/build` refuses generated Lua that calls it.
nginx's own refusals (400, 413, 414, 494, 500) each have a named location that passes its status: inside an `=`
error page, `ngx.status` is 0 for a request refused before the content phase.

## The toolchain

Every rock is pinned by version and SHA-256 in `bin/install-toolchain`, the one script the toolchain image, the
production build and GitLab run. LuaRocks.org was compromised between July and August 2026 (its September report found
no altered package); the base image's LuaRocks is 3.13, past the 3.12 fix for loading bytecode as a rockspec. Teal's
and lua-resty-http's sources were compared with their GitHub tags when pinned.

## Tests

Integration runs the production `nginx.conf` and the generated Lua in real OpenResty, one scenario at a time on 8080:
`main`, `short` (a compiled `tests/integration/overrides/config/lifetimes.lua` copied over the real one in that
scenario's prefix only) and `redis_down`; then start-up refusals and the log scan. Redis runs with the ACL above,
provisioned from `redis_store.commands`. The fakes (`tests/integration/fakes`) answer identity's real shapes, Nest's
`{ statusCode, message, error, traceId }` refusals included. The harness's directories are `chmod 755`: nginx workers
run as `nobody` when the master is root, and could not read a 0700 `mktemp` directory. The fake API serves matching's
merchant socket with `resty.websocket.server`, which echoes every offered subprotocol back: the harshest upstream for
the token-leak check; the log scan also looks for the base64url form of each token a socket test saw. A Redis failure
after identity's logout is made with `ACL SETUSER edge -del` (no `reset`, which would touch pooled connections).
