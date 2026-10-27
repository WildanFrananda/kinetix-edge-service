local client = require("tests.support.client")
local scenario = require("tests.support.scenario")
local websocket_client = require("resty.websocket.client")
local type Answer = require("tests.support.types.answer")
local type EdgeRequest = require("tests.support.types.edge_request")
local type OpenedSocket = require("tests.support.types.opened_socket")
local type SocketRequest = require("tests.support.types.socket_request")

local record socket
   path: string
end

socket.path = "/bff/ws/v1/matching/merchant/websocket"

local function parsed(header: string): integer, {string: string}
   local status = tonumber(string.match(header, "^%s*HTTP/1%.1%s+(%d%d%d)"))
   local headers: {string: string} = {}
   for line in string.gmatch(header, "[^\r\n]+") do
      local name, value = string.match(line, "^([%w%-]+):%s*(.-)%s*$")
      if name ~= nil then
         headers[string.lower(name)] = value
      end
   end

   return math.floor(status or 0), headers
end

function socket.open(path: string, request: SocketRequest): OpenedSocket
   local options: SocketRequest = request or {}
   local app = options.app or "seller-web"
   local connection, failure = websocket_client:new({ timeout = 5000 })
   if connection == nil then
      error("cannot make a WebSocket client: " .. tostring(failure))
   end

   local headers: {string} = {
      "X-Request-Id: " .. (options.request_id or client.request_id()),
      "X-Forwarded-For: " .. scenario.forwarded_for,
   }
   if options.cookie ~= nil then
      table.insert(headers, "Cookie: " .. options.cookie)
   end

   local opened, refused, header = connection:connect(
      scenario.socket_url .. path,
      {
         host = scenario.hosts[app],
         origin = options.origin or scenario.origin(app),
         protocols = options.protocols,
         headers = headers,
      }
   )
   if opened == nil then
      error("no handshake answer from the edge: " .. tostring(refused))
   end

   local status, answer_headers = parsed(header)

   return { status = status, headers = answer_headers, raw = header, connection = connection }
end

function socket.upgrade(path: string, request: EdgeRequest, origin: string): Answer
   local options: EdgeRequest = request or {}
   local headers: {string: string} = {
      ["Upgrade"] = "websocket",
      ["Connection"] = "Upgrade",
      ["Sec-WebSocket-Key"] = "dGhlIHNhbXBsZSBub25jZQ==",
      ["Sec-WebSocket-Version"] = "13",
   }
   if origin ~= nil then
      headers["Origin"] = origin
   end

   for name, value in pairs(options.headers or {}) do
      headers[name] = value
   end

   options.headers = headers

   return client.edge("GET", path, options)
end

return socket
