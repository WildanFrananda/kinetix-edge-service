local context = require("http.context")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local response_headers = require("http.response_headers")
local session_use = require("http.session_use")
local sessions = require("http.sessions")
local settings = require("http.settings")
local socket_handshake = require("http.socket_handshake")
local type RequestContext = require("types.request_context")

local record merchant_socket
end

local BFF_PREFIX = "/bff"
local UPSTREAM_LOCATION = "@merchant_socket"

local OUTCOMES: {string: string} = {
   ["SESSION_REQUIRED"] = "session_refused",
   ["SESSION_ENDED"] = "session_refused",
   ["ROLE_REFUSED"] = "session_refused",
}

local function admits(roles: {string}, role: string): boolean
   for _, admitted in ipairs(roles) do
      if admitted == role then
         return true
      end
   end

   return false
end

local function upstream_url(): string
   local url = settings.current.environment.api_upstream .. string.sub(ngx.var.uri, #BFF_PREFIX + 1)
   local query = ngx.var.args
   if query ~= nil and query ~= "" then
      return url .. "?" .. query
   end

   return url
end

function merchant_socket.serve(request: RequestContext)
   local app = request.app.name
   if not socket_handshake.is_upgrade(request.headers) then
      metrics.socket_upgrade(app, "not_websocket")
      ngx.header["Upgrade"] = "websocket"
      return respond.error("WEBSOCKET_REQUIRED", request.request_id, nil)
   end

   if context.single(request.headers, "origin") ~= request.app.origin then
      metrics.socket_upgrade(app, "origin_refused")
      logger.info("csrf_refused", { reason = "socket_origin", app = app, request_id = request.request_id })
      return respond.error("CSRF_REFUSED", request.request_id, nil)
   end

   local client = sessions.open()
   if client == nil then
      metrics.socket_upgrade(app, "session_unavailable")
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   local session, refusal = session_use.usable(client, request)
   redis_store.release(client)
   if session == nil then
      return metrics.socket_upgrade(app, OUTCOMES[refusal] or "session_unavailable")
   end

   if not admits(request.app.merchant_socket_roles, session.role) then
      metrics.socket_upgrade(app, "role_refused")
      logger.info("socket_role_refused", { role = session.role, app = app, request_id = request.request_id })
      return respond.error("SELLER_REQUIRED", request.request_id, nil)
   end

   ngx.var.edge_socket_upstream = upstream_url()
   ngx.var.edge_socket_host = socket_handshake.upstream_host(settings.current.environment.api_upstream)
   ngx.var.edge_socket_protocol = socket_handshake.protocols_for(session.access_token)
   ngx.var.edge_client_address = request.client_address

   ngx.exec(UPSTREAM_LOCATION)
end

function merchant_socket.answer()
   response_headers.filter()
   ngx.header["Set-Cookie"] = nil

   local app = ngx.var.edge_app or ""
   if ngx.status ~= 101 then
      metrics.socket_upgrade(app, "refused")
      ngx.header["Sec-WebSocket-Protocol"] = nil
      return
   end

   metrics.socket_upgrade(app, "upgraded")
   local browser = ngx.req.get_headers(100, false)
   if socket_handshake.offers_phoenix(browser) then
      ngx.header["Sec-WebSocket-Protocol"] = socket_handshake.subprotocol
   else
      ngx.header["Sec-WebSocket-Protocol"] = nil
   end
end

function merchant_socket.unavailable()
   local request_id = ngx.var.edge_request_id
   metrics.socket_upgrade(ngx.var.edge_app or "", "unavailable")
   metrics.dependency_failed("api")
   logger.warn("api_unavailable", { upstream = "api", stage = "merchant_socket", request_id = request_id })
   respond.error("API_UNAVAILABLE", request_id, nil)
end

return merchant_socket
