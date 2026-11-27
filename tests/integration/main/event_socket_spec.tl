local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")
local socket = require("tests.support.socket")
local type OpenedSocket = require("tests.support.types.opened_socket")

local function recv_json(opened: OpenedSocket): cjson.Document
   local data, kind, failure = opened.connection:recv_frame()
   check.equal(kind, "text", "expected text frame (" .. tostring(failure) .. ")")

   local decoded = cjson.decode(data)
   check.truthy(decoded is cjson.Document, "frame must decode as JSON object")
   return decoded as cjson.Document
end

local function bearer_login(email: string): string
   local payload = cjson.encode({ email = email, password = "correct-password" })
   local reply = client.call(
      scenario.identity_url,
      "POST",
      "/api/v1/auth/login",
      { ["X-Kinetix-Client"] = "seller-web" },
      payload
   )
   local doc = cjson.decode(reply.body) as cjson.Document
   return doc["accessToken"] as string
end

describe("the unified camelCase JSON event WebSocket", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("refuses non-WebSocket HTTP requests with 426 and bad BFF origin with 403", function()
      local bare = client.edge("GET", "/ws/v1/events", { headers = {} })
      check.equal(bare.status, 426, "bearer endpoint requires upgrade")

      local cookie = flows.session(flows.session_cookie("seller-web", "seller@example.test"))
      local bad_origin = socket.upgrade(
         "/bff/ws/v1/events",
         { app = "seller-web", cookie = cookie },
         "https://evil.example"
      )
      check.equal(bad_origin.status, 403, "bff endpoint refuses foreign origin")
   end)

   it("refuses missing or unknown bearer tokens on /ws/v1/events", function()
      local missing = socket.upgrade("/ws/v1/events", {}, nil)
      check.equal(missing.status, 401, "missing bearer token refused")

      local bad = socket.upgrade("/ws/v1/events", { headers = { ["Authorization"] = "Bearer not-valid" } }, nil)
      check.equal(bad.status, 401, "invalid bearer token refused")
   end)

   it("bridges courier bearer sockets bidirectionally to matching without phoenix framing", function()
      local token = bearer_login("courier@example.test")
      local opened = socket.open(
         "/ws/v1/events",
         { headers = { ["Authorization"] = "Bearer " .. token } }
      )
      check.equal(opened.status, 101, "courier upgraded")
      check.absent(opened.headers["sec-websocket-protocol"], "no phoenix subprotocol")

      local snapshot = recv_json(opened)
      check.equal(snapshot["event"], "matching.job.snapshot", "upstream snapshot forwarded")
      local snap_data = snapshot["data"] as cjson.Object
      check.equal(snap_data["role"], "courier", "forwarded role header")
      check.equal(snap_data["authorization"], "Bearer " .. token, "forwarded bearer")

      opened.connection:send_text(
         '{"event":"courier.location.ping","requestId":"req-c1","schemaVersion":1,"data":{"latitude":-6.2}}'
      )
      local ack = recv_json(opened)
      check.equal(ack["event"], "command.ack", "upstream ack relayed")
      check.equal(ack["requestId"], "req-c1", "requestId preserved")
      check.equal((ack["data"] as cjson.Object)["echoEvent"], "courier.location.ping", "echoed event")
      opened.connection:close()
   end)

   it("enforces order ownership for buyers and coalesces rapid Redis position broadcasts", function()
      local token = bearer_login("customer@example.test")
      local opened = socket.open(
         "/ws/v1/events",
         { headers = { ["Authorization"] = "Bearer " .. token } }
      )
      check.equal(opened.status, 101, "customer upgraded")

      opened.connection:send_text('{"event":"system.ping","requestId":"req-p1","schemaVersion":1,"data":{}}')
      local pong = recv_json(opened)
      check.equal(pong["event"], "system.pong", "edge answers system.ping for buyers")
      check.equal(pong["requestId"], "req-p1", "pong requestId")

      opened.connection:send_text(
         '{"event":"subscription.subscribe","requestId":"req-bad","schemaVersion":1,"data":{"orderId":"not-uuid"}}'
      )
      local invalid_err = recv_json(opened)
      check.equal(invalid_err["event"], "command.error", "non-uuid rejected")
      check.equal((invalid_err["error"] as cjson.Object)["code"], "INVALID_ORDER_ID", "invalid order id code")

      opened.connection:send_text(
         '{"event":"subscription.subscribe","requestId":"req-403","schemaVersion":1,'
            .. '"data":{"orderId":"22222222-2222-2222-2222-222222222222"}}'
      )
      local forbidden_err = recv_json(opened)
      check.equal((forbidden_err["error"] as cjson.Object)["code"], "FORBIDDEN", "forbidden order rejected")

      opened.connection:send_text(
         '{"event":"subscription.subscribe","requestId":"req-404","schemaVersion":1,'
            .. '"data":{"orderId":"33333333-3333-3333-3333-333333333333"}}'
      )
      local missing_err = recv_json(opened)
      check.equal((missing_err["error"] as cjson.Object)["code"], "ORDER_NOT_FOUND", "missing order rejected")

      opened.connection:send_text(
         '{"event":"subscription.subscribe","requestId":"req-ok","schemaVersion":1,'
            .. '"data":{"orderId":"11111111-1111-1111-1111-111111111111"}}'
      )
      local sub_ack = recv_json(opened)
      check.equal(sub_ack["event"], "command.ack", "subscribed ack")
      check.equal((sub_ack["data"] as cjson.Object)["orderNumber"], "ORD-1001", "resolved order number")

      local first_pos = '{"event":"courier.location.updated","eventId":"evt-1","orderId":"ORD-1001",'
         .. '"schemaVersion":1,"data":{"latitude":-6.20}}'
      local second_pos = '{"event":"courier.location.updated","eventId":"evt-2","orderId":"ORD-1001",'
         .. '"schemaVersion":1,"data":{"latitude":-6.25}}'
      redis_admin.publish("matching:position:ORD-1001", first_pos)
      ngx.sleep(0.05)
      redis_admin.publish("matching:position:ORD-1001", second_pos)

      local delivered = recv_json(opened)
      check.equal(delivered["event"], "courier.location.updated", "live position pushed")
      check.equal(delivered["orderId"], "ORD-1001", "orderId intact")
      check.truthy(delivered["eventId"] == "evt-1" or delivered["eventId"] == "evt-2", "position received")
      if delivered["eventId"] == "evt-1" then
         local next_pos = recv_json(opened)
         check.equal(next_pos["eventId"], "evt-2", "throttled latest position followed")
      end

      opened.connection:send_text(
         '{"event":"subscription.unsubscribe","requestId":"req-unsub","schemaVersion":1,'
            .. '"data":{"orderId":"11111111-1111-1111-1111-111111111111"}}'
      )
      local unsub_ack = recv_json(opened)
      check.equal(unsub_ack["event"], "command.ack", "unsubscribed ack")
      check.equal((unsub_ack["data"] as cjson.Object)["unsubscribed"], true, "unsubscribed flag")
      opened.connection:close()
   end)

   it("opens /bff/ws/v1/events for authenticated seller browser sessions without leaking cookies", function()
      local cookie = flows.session(flows.session_cookie("seller-web", "seller@example.test"))
      local opened = socket.open("/bff/ws/v1/events", { app = "seller-web", cookie = cookie })
      check.equal(opened.status, 101, "seller upgraded over BFF")

      local snapshot = recv_json(opened)
      check.equal(snapshot["event"], "matching.job.snapshot", "seller snapshot received")
      local snap_data = snapshot["data"] as cjson.Object
      check.equal(snap_data["role"], "seller", "forwarded seller role")

      opened.connection:send_text(
         '{"event":"courier.location.ping","requestId":"req-esc-1","schemaVersion":1,"data":{"latitude":-6.2}}'
      )
      local refused = recv_json(opened)
      check.equal(refused["event"], "command.error", "seller cannot send courier command upstream")
      check.equal((refused["error"] as cjson.Object)["code"], "FORBIDDEN", "forbidden error code")
      opened.connection:close()
   end)

   it("enforces X7 per-principal socket caps and frees slots on disconnect", function()
      local token = bearer_login("courier@example.test")
      local first = socket.open(
         "/ws/v1/events",
         { headers = { ["Authorization"] = "Bearer " .. token, ["X-Forwarded-For"] = "203.0.113.81" } }
      )
      local second = socket.open(
         "/ws/v1/events",
         { headers = { ["Authorization"] = "Bearer " .. token, ["X-Forwarded-For"] = "203.0.113.82" } }
      )
      check.equal(first.status, 101, "first courier socket opened")
      check.equal(second.status, 101, "second courier socket opened")

      local capped = socket.upgrade(
         "/ws/v1/events",
         { forwarded_for = "203.0.113.83", headers = { ["Authorization"] = "Bearer " .. token } },
         nil
      )
      check.equal(capped.status, 429, "third concurrent courier socket refused with 429")
      check.equal(client.text(capped, "error"), "TOO_MANY_REQUESTS", "socket cap error code")

      first.connection:send_close()
      first.connection:close()
      local probe = 90
      flows.eventually(function(): boolean
         probe = probe + 1
         local reply = socket.upgrade(
            "/ws/v1/events",
            {
               forwarded_for = "203.0.113." .. tostring(probe),
               headers = { ["Authorization"] = "Bearer " .. token },
            },
            nil
         )
         return reply.status == 101
      end, "closing one socket releases its X7 slot")

      second.connection:send_close()
      second.connection:close()
   end)

   it("enforces X2 sliding-window rate limits on inbound WebSocket frames", function()
      local token = bearer_login("customer@example.test")
      local opened = socket.open("/ws/v1/events", { headers = { ["Authorization"] = "Bearer " .. token } })
      check.equal(opened.status, 101, "buyer socket opened")

      for seq = 1, 60 do
         opened.connection:send_text(
            '{"event":"system.ping","requestId":"req-rl-' .. tostring(seq) .. '","schemaVersion":1,"data":{}}'
         )
         local pong = recv_json(opened)
         check.equal(pong["event"], "system.pong", "ping " .. tostring(seq) .. " within frame limit")
      end

      opened.connection:send_text('{"event":"system.ping","requestId":"req-rl-61","schemaVersion":1,"data":{}}')
      local limited = recv_json(opened)
      check.equal(limited["event"], "command.error", "61st frame rate limited")
      local err_obj = limited["error"] as cjson.Object
      check.equal(err_obj["code"], "TOO_MANY_REQUESTS", "ws rate limit code")
      check.equal(err_obj["retryable"], true, "ws rate limit error is retryable")
      opened.connection:close()
   end)
end)
