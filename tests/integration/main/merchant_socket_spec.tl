local base64 = require("ngx.base64")
local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")
local socket = require("tests.support.socket")
local type OpenedSocket = require("tests.support.types.opened_socket")
local type SocketEcho = require("tests.support.types.socket_echo")

local function seen_upstream(opened: OpenedSocket): SocketEcho
   local data, kind, failure = opened.connection:recv_frame()
   check.equal(kind, "text", "the upstream's first frame (" .. tostring(failure) .. ")")

   local decoded = cjson.decode(data)
   check.truthy(decoded is cjson.Document, "the upstream's echo")

   return decoded as SocketEcho
end

local function encoded(token: string): string
   local value = base64.encode_base64url(token)
   client.observe_secret(value)

   return value
end

local function metric(name: string): number
   local text = client.call(scenario.metrics_url, "GET", "/metrics", {}, nil).body
   for line in string.gmatch(text, "[^\n]+") do
      if string.sub(line, 1, #name + 1) == name .. " " then
         return tonumber(string.sub(line, #name + 2))
      end
   end

   return nil
end

local function upgrades(outcome: string): number
   return metric("kinetix_edge_socket_upgrades_total{app=\"seller-web\",outcome=\"" .. outcome .. "\"}")
end

describe("the seller web's merchant socket", function()
   local cookie: string = nil

   before_each(function()
      fake.reset()
      redis_admin.flush()
      cookie = flows.session(flows.session_cookie("seller-web", "seller@example.test"))
   end)

   it("proxies a seller's upgrade with the session's token in the subprotocol, never showing it", function()
      local token = encoded(fake.issued("access"))
      local before = upgrades("upgraded") or 0
      local request_id = client.request_id()

      local opened = socket.open(
         socket.path .. "?vsn=2.0.0",
         { cookie = cookie, protocols = { "phoenix" }, request_id = request_id }
      )
      check.equal(opened.status, 101, "switched")
      check.equal(opened.headers["sec-websocket-protocol"], "phoenix", "the subprotocol the browser offered")
      check.excludes(opened.raw, token, "no token in the handshake answer")
      check.excludes(opened.raw, "bearer", "no bearer entry in the handshake answer")
      check.excludes(opened.raw, "fake-access", "no access token in the handshake answer")
      check.absent(opened.headers["set-cookie"], "no cookie from upstream")

      local seen = seen_upstream(opened)
      check.equal(seen.path, "/ws/v1/matching/merchant/websocket", "the gateway's path")
      check.equal(seen.query, "vsn=2.0.0", "the query passes")
      check.equal(seen.headers["sec-websocket-protocol"], "phoenix, base64url.bearer.phx." .. token, "the token")
      check.absent(seen.headers["origin"], "no Origin, so Phoenix's check_origin passes")
      check.equal(seen.headers["host"], "127.0.0.1:18002", "the upstream's own host")
      check.equal(seen.headers["x-forwarded-for"], scenario.browser_address, "the browser's address alone")
      check.equal(seen.headers["x-forwarded-proto"], "https", "the browser's scheme")
      check.equal(seen.headers["x-request-id"], request_id, "request id")
      check.equal(seen.headers["upgrade"], "websocket", "an upgrade")
      check.absent(seen.headers["cookie"], "no cookie upstream")
      check.absent(seen.headers["authorization"], "no Authorization upstream")

      opened.connection:send_text("ping")
      local echoed = opened.connection:recv_frame()
      check.equal(echoed, "echo:ping", "frames pass both ways")
      opened.connection:close()

      check.at_least(upgrades("upgraded"), before + 1, "counted")
   end)

   it("answers no subprotocol unless the browser offered phoenix, and replaces whatever it offered", function()
      local token = encoded(fake.issued("access"))

      local bare = socket.open(socket.path, { cookie = cookie })
      check.equal(bare.status, 101, "switched without a subprotocol")
      check.absent(bare.headers["sec-websocket-protocol"], "none answered: none was offered")
      check.excludes(bare.raw, token, "no token")
      bare.connection:close()

      local other = socket.open(socket.path, { cookie = cookie, protocols = { "chat" } })
      check.equal(other.status, 101, "switched")
      check.absent(other.headers["sec-websocket-protocol"], "not answered to a browser that did not offer phoenix")
      other.connection:close()

      local forged = socket.open(
         socket.path,
         { cookie = cookie, protocols = { "phoenix", "base64url.bearer.phx.Zm9yZ2Vk" } }
      )
      check.equal(forged.headers["sec-websocket-protocol"], "phoenix", "phoenix")
      local seen = seen_upstream(forged)
      check.equal(
         seen.headers["sec-websocket-protocol"],
         "phoenix, base64url.bearer.phx." .. token,
         "the browser's token entry never reaches upstream"
      )
      forged.connection:close()
   end)

   it("serves the endpoint path without /websocket as well", function()
      local opened = socket.open("/bff/ws/v1/matching/merchant?vsn=2.0.0", { cookie = cookie })
      check.equal(opened.status, 101, "switched")
      check.equal(seen_upstream(opened).path, "/ws/v1/matching/merchant", "path")
      opened.connection:close()
   end)

   it("refuses an upgrade whose Origin is not the application's own, before the session is read", function()
      local before = upgrades("origin_refused") or 0
      for label, origin in pairs({
         foreign = "https://evil.example",
         sibling = scenario.origin("backoffice"),
         plain = "http://seller.localhost:8443",
         opaque = "null",
      }) do
         local answer = socket.upgrade(socket.path, { cookie = cookie }, origin)
         check.equal(answer.status, 403, label)
         check.equal(client.text(answer, "error"), "CSRF_REFUSED", label .. " code")
         check.equal(#answer.set_cookies, 0, label .. " keeps the cookie")
      end

      local missing = socket.upgrade(socket.path, { cookie = cookie }, nil)
      check.equal(missing.status, 403, "no Origin at all")
      check.at_least(upgrades("origin_refused"), before + 5, "counted")

      local state = client.edge("GET", "/bff/session", { cookie = cookie })
      check.equal(client.flag(state, "authenticated"), true, "the session survived")
   end)

   it("asks for a session, and ends a cookie that names none", function()
      local none = socket.upgrade(socket.path, {}, scenario.origin("seller-web"))
      check.equal(none.status, 401, "no cookie")
      check.equal(client.text(none, "error"), "SESSION_REQUIRED", "code")

      local unknown = socket.upgrade(
         socket.path,
         { cookie = flows.session(string.rep("Z", 43)) },
         scenario.origin("seller-web")
      )
      check.equal(unknown.status, 401, "unknown cookie")
      check.equal(client.text(unknown, "error"), "SESSION_ENDED", "code")
      check.equal(
         unknown.set_cookies[1],
         "__Host-kx_session=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0",
         "expired"
      )
   end)

   it("refuses an applicant (customer) with SELLER_REQUIRED and keeps the session", function()
      local applicant = flows.session(flows.session_cookie("seller-web", "customer@example.test"))
      local answer = socket.upgrade(socket.path, { cookie = applicant }, scenario.origin("seller-web"))
      check.equal(answer.status, 403, "status")
      check.equal(client.text(answer, "error"), "SELLER_REQUIRED", "code")
      check.equal(#answer.set_cookies, 0, "the cookie stays")

      local state = client.edge("GET", "/bff/session", { cookie = applicant })
      check.equal(client.flag(state, "authenticated"), true, "the session stays")
   end)

   it("takes only a WebSocket upgrade, and only on the seller web", function()
      local plain = client.edge("GET", socket.path, { cookie = cookie })
      check.equal(plain.status, 426, "a plain GET")
      check.equal(client.text(plain, "error"), "WEBSOCKET_REQUIRED", "code")
      check.equal(client.header(plain, "Upgrade"), "websocket", "the protocol to upgrade to")

      local posted = client.edge("POST", socket.path, { cookie = cookie, body = "{}" })
      check.equal(posted.status, 405, "POST")

      local admin = flows.session(flows.admin_session_cookie())
      local backoffice = socket.upgrade(
         socket.path,
         { app = "backoffice", cookie = admin },
         scenario.origin("backoffice")
      )
      check.equal(backoffice.status, 404, "not on the backoffice")
      check.equal(client.text(backoffice, "error"), "NOT_FOUND", "code")
   end)

   it("refreshes first when the access token is about to expire", function()
      fake.configure({ access_expires_in = 30 })
      local short = flows.session(flows.session_cookie("seller-web", "seller@example.test"))
      fake.configure({ access_expires_in = 900 })

      local opened = socket.open(socket.path, { cookie = short, protocols = { "phoenix" } })
      check.equal(opened.status, 101, "switched")
      check.equal(fake.count("refresh"), 1, "refreshed once")
      local seen = seen_upstream(opened)
      check.equal(
         seen.headers["sec-websocket-protocol"],
         "phoenix, base64url.bearer.phx." .. encoded(fake.issued("access")),
         "the renewed token"
      )
      opened.connection:close()
   end)

   it("passes the upstream's refusal through, and answers 503 when the upstream cannot be reached", function()
      local refused = socket.open(socket.path .. "?refuse=1", { cookie = cookie, protocols = { "phoenix" } })
      check.equal(refused.status, 403, "matching's refusal")
      check.absent(refused.headers["sec-websocket-protocol"], "no subprotocol on a refusal")

      local before = upgrades("unavailable") or 0
      local closed = socket.upgrade(socket.path .. "?close=1", { cookie = cookie }, scenario.origin("seller-web"))
      check.equal(closed.status, 503, "status")
      check.equal(client.text(closed, "error"), "API_UNAVAILABLE", "code")
      check.at_least(upgrades("unavailable"), before + 1, "counted")
   end)
end)
