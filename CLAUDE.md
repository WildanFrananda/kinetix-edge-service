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
deleted. Any Redis error closes the connection instead of pooling it: a connection left inside `MULTI`, or with a late
reply in flight, would poison the next request.

## Forgery checks come first

The order is route, method, app by host name, browser address, CSRF, JSON body, then Redis. `OPTIONS` counts as
state-changing (no CORS is answered). A non-JSON body is 415 `JSON_REQUIRED`, counted as a CSRF refusal with reason
`content_type`.

## The app is the host name; the origin is the configured host

The gateway preserves the browser's `Host`: `backoffice.wildanfrananda.my.id` in production, `backoffice.localhost:8443`
in the lab. The app is matched by host name without the port; the expected `Origin` is `https://` + the configured
host, port included. So the two hosts must differ by name, and start-up refuses two that differ only by port.

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
and the backoffice host is behind the staff gate at the gateway before the edge is reached. `/api/v1/users` and
`/api/v1/sellers` are not throttled by identity and stay on the gateway; a throttle added there moves them onto the list.
Everything else goes to the gateway's internal listener, where the twin appends the edge's address, so a per-address
limit in another service sees the edge.

## What is forwarded

Request headers are a list (`config/forwarding.tl`); everything else stays behind, `Cookie`, `Authorization` and every
`X-Kinetix-*` included. `Host` is the upstream URL's own. The path is nginx's normalized `$uri` with each segment
re-escaped, so a decoded `%2F` becomes a separator and the refusal list sees exactly what is sent. identity's
token-issuing routes (login, register, refresh, logout, `2fa/verify`, courier registration) are refused with 404: a
forwarded answer must never hand a token to JavaScript. `Set-Cookie`, hop-by-hop and cache headers are dropped.

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
run as `nobody` when the master is root, and could not read a 0700 `mktemp` directory.
