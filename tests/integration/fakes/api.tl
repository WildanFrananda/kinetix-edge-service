local cjson = require("cjson.safe")
local websocket_server = require("resty.websocket.server")

local record api
end

local SOCKET_PREFIX = "/ws/v1/matching/merchant"
local EVENTS_SOCKET_PATH = "/ws/v1/matching/events"

local function flat_headers(): {string: string}
   local headers = ngx.req.get_headers(100, false)
   local flat: {string: string} = {}
   for key, value in pairs(headers) do
      if value is string then
         flat[key] = value
      else
         flat[key] = table.concat(value, ", ")
      end
   end

   return flat
end

local function socket()
   local query = ngx.var.args or ""
   if string.find(query, "close=1", 1, true) ~= nil then
      return ngx.exit(444)
   end

   if string.find(query, "refuse=1", 1, true) ~= nil then
      ngx.status = 403
      ngx.print("")
      return
   end

   local seen = cjson.encode({ path = ngx.var.uri, query = query, headers = flat_headers() })
   local connection, failure = websocket_server:new({ timeout = 5000, max_payload_len = 65535 })
   if connection == nil then
      ngx.log(ngx.ERR, "the fake socket refused the handshake: ", failure)
      return ngx.exit(400)
   end

   connection:send_text(seen)
   while true do
      local data, kind = connection:recv_frame()
      if data == nil or kind == "close" then
         connection:send_close()
         return
      end

      if kind == "text" then
         connection:send_text("echo:" .. data)
      end
   end
end

local function event_socket()
   local headers = flat_headers()
   local connection, failure = websocket_server:new({ timeout = 5000, max_payload_len = 65535 })
   if connection == nil then
      ngx.log(ngx.ERR, "the fake event socket refused the handshake: ", failure)
      return ngx.exit(400)
   end

   local snapshot = cjson.encode({
      event = "matching.job.snapshot",
      eventId = "evt-fake-snapshot",
      schemaVersion = 1,
      occurredAt = "2026-11-16T00:00:00Z",
      sentAt = "2026-11-16T00:00:00Z",
      data = {
         role = headers["x-edge-role"] or "",
         authorization = headers["authorization"] or "",
      },
   })
   connection:send_text(snapshot)

   while true do
      local data, kind = connection:recv_frame()
      if data == nil or kind == "close" then
         connection:send_close()
         return
      end

      if kind == "text" then
         local decoded = cjson.decode(data)
         local doc: cjson.Document = (decoded is cjson.Document) and decoded or {}
         local req_id = doc["requestId"]
         local evt_name = doc["event"]
         local reply_doc: {string: cjson.Field} = {
            event = "command.ack",
            eventId = "evt-fake-ack",
            schemaVersion = 1,
            occurredAt = "2026-11-16T00:00:00Z",
            sentAt = "2026-11-16T00:00:00Z",
            data = {
               echoEvent = (evt_name is string) and evt_name or "",
               accepted = true,
            },
         }
         if req_id is string then
            reply_doc["requestId"] = req_id
         end
         local reply = cjson.encode(reply_doc)
         connection:send_text(reply)
      end
   end
end

local function serve_order_lookup(order_id: string): boolean
   local auth = ngx.req.get_headers(100, false)["authorization"]
   if auth == nil or auth == "" then
      ngx.status = 401
      ngx.header["Content-Type"] = "application/json"
      ngx.print(cjson.encode({ error = "UNAUTHORIZED" }))
      return true
   end

   if order_id == "11111111-1111-1111-1111-111111111111" then
      ngx.status = 200
      ngx.header["Content-Type"] = "application/json"
      ngx.print(cjson.encode({
         id = order_id,
         orderNumber = "ORD-1001",
         customerPrincipalId = "prn_fake_103",
      }))
      return true
   end

   if order_id == "22222222-2222-2222-2222-222222222222" then
      ngx.status = 403
      ngx.header["Content-Type"] = "application/json"
      ngx.print(cjson.encode({ error = "FORBIDDEN" }))
      return true
   end

   ngx.status = 404
   ngx.header["Content-Type"] = "application/json"
   ngx.print(cjson.encode({ error = "ORDER_NOT_FOUND" }))
   return true
end

local FIXTURE_ORDERS: {string: boolean} = {
   ["11111111-1111-1111-1111-111111111111"] = true,
   ["22222222-2222-2222-2222-222222222222"] = true,
   ["33333333-3333-3333-3333-333333333333"] = true,
}

function api.serve()
   local uri = ngx.var.uri
   if uri == "/api/v1/fake/close" then
      return ngx.exit(444)
   end

   if uri == SOCKET_PREFIX or uri == SOCKET_PREFIX .. "/websocket" then
      return socket()
   end

   if uri == EVENTS_SOCKET_PATH then
      return event_socket()
   end

   local order_id = string.match(uri, "^/api/v1/orders/([^/]+)$")
   if order_id ~= nil and FIXTURE_ORDERS[order_id] then
      serve_order_lookup(order_id)
      return
   end

   ngx.req.read_body()

   local status = tonumber(string.match(uri, "^/api/v1/fake/status/(%d%d%d)$")) or 200
   ngx.status = math.floor(status)
   ngx.header["Content-Type"] = "application/json"
   ngx.header["Set-Cookie"] = { "upstream=1; Path=/", "tracker=2; Path=/; HttpOnly" }
   ngx.header["Cache-Control"] = "public, max-age=600"
   ngx.header["X-Upstream"] = "fake-api"
   ngx.header["X-Powered-By"] = "fake"
   local echoed = cjson.encode({
      method = ngx.req.get_method(),
      path = uri,
      query = ngx.var.args or "",
      body = ngx.req.get_body_data() or "",
      headers = flat_headers(),
   })
   ngx.print(echoed)
end

return api
