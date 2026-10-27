local cjson = require("cjson.safe")
local websocket_server = require("resty.websocket.server")

local record api
end

local SOCKET_PREFIX = "/ws/v1/matching/merchant"

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

function api.serve()
   local uri = ngx.var.uri
   if uri == "/api/v1/fake/close" then
      return ngx.exit(444)
   end

   if uri == SOCKET_PREFIX or uri == SOCKET_PREFIX .. "/websocket" then
      return socket()
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
