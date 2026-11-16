local cjson = require("cjson.safe")
local client_address = require("http.client_address")
local context = require("http.context")
local event_protocol = require("http.event_protocol")
local host_aliases = require("adapters.host_aliases")
local http_client = require("adapters.http_client")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local secure_random = require("adapters.secure_random")
local session_use = require("http.session_use")
local sessions = require("http.sessions")
local settings = require("http.settings")
local socket_handshake = require("http.socket_handshake")
local timing = require("config.timing")
local websocket_client = require("resty.websocket.client")
local websocket_server = require("resty.websocket.server")
local type RequestContext = require("types.request_context")

local record event_socket
end

local UPSTREAM_MATCHING_PATH = "/ws/v1/matching/events"
local IDENTITY_ME_PATH = "/api/v1/auth/me"
local MAX_PAYLOAD_LEN = 65535
local CLIENT_TIMEOUT_MS = 60000
local PUBSUB_READ_TIMEOUT_MS = 1000
local FLUSH_INTERVAL_SECONDS = 0.25

local IDENTITY_TIMEOUTS: http_client.Timeouts = {
   connect_ms = timing.identity_connect_ms,
   send_ms = timing.identity_send_ms,
   read_ms = timing.identity_read_ms,
}

local API_TIMEOUTS: http_client.Timeouts = {
   connect_ms = timing.api_connect_ms,
   send_ms = timing.api_send_ms,
   read_ms = timing.api_read_ms,
}

local OUTCOMES: {string: string} = {
   ["SESSION_REQUIRED"] = "session_refused",
   ["SESSION_ENDED"] = "session_refused",
   ["ROLE_REFUSED"] = "session_refused",
}

local record Caller
   token: string
   role: string
   principal_id: string
   client_ip: string
   request_id: string
   app_label: string
end

local record Hub
   client: websocket_server.Connection
   upstream: websocket_client.Connection
   subscriber: redis.Client
   sub_thread: ngx.Thread
   flush_thread: ngx.Thread
   channels_by_order: {string: string}
   subscribed_channels: {string: boolean}
   latest_by_channel: {string: string}
   last_flush_at: number
   flush_scheduled: boolean
   writing: boolean
   closed: boolean
end

local function new_event_id(): string
   local hex = secure_random.hex(16)
   local formatted = event_protocol.uuid_from_hex(hex)
   if formatted ~= nil then
      return formatted
   end

   return string.format("evt-%d-%d", ngx.worker.pid(), math.floor(ngx.now() * 1000))
end

local function now_iso(): string
   local utc = ngx.utctime()
   return string.gsub(utc, " ", "T") .. "Z"
end

local function safe_send_text(hub: Hub, text: string): boolean
   if hub.closed or text == nil then
      return false
   end

   while hub.writing do
      if hub.closed then
         return false
      end
      ngx.sleep(0.002)
   end

   if hub.closed then
      return false
   end

   hub.writing = true
   local bytes, failure = hub.client:send_text(text)
   hub.writing = false
   if bytes == nil then
      hub.closed = true
      logger.info("event_socket_write_failed", { cause = failure or "" })
      return false
   end

   return true
end

local function flush_positions(hub: Hub)
   hub.flush_scheduled = false
   if hub.closed then
      return
   end

   hub.last_flush_at = ngx.now()
   local pending = hub.latest_by_channel
   hub.latest_by_channel = {}
   for _, payload in pairs(pending) do
      if not safe_send_text(hub, payload) then
         return
      end
   end
end

local function schedule_flush(hub: Hub)
   local elapsed = ngx.now() - hub.last_flush_at
   if elapsed >= FLUSH_INTERVAL_SECONDS then
      flush_positions(hub)
      return
   end

   if hub.flush_scheduled then
      return
   end

   hub.flush_scheduled = true
   local delay = FLUSH_INTERVAL_SECONDS - elapsed
   hub.flush_thread = ngx.thread.spawn(function(): string
      ngx.sleep(delay)
      flush_positions(hub)
      return nil
   end)
end

local function stop_subscriber(hub: Hub)
   local previous = hub.subscriber
   local thread = hub.sub_thread
   hub.subscriber = nil
   hub.sub_thread = nil
   if previous ~= nil then
      previous:close()
   end
   if thread ~= nil then
      ngx.thread.wait(thread)
   end
end

local function sync_subscriber(hub: Hub): boolean
   stop_subscriber(hub)
   if hub.closed then
      return true
   end

   local channels: {string} = {}
   for channel, active in pairs(hub.subscribed_channels) do
      if active then
         table.insert(channels, channel)
      end
   end
   if #channels == 0 then
      return true
   end

   local sub, failure = redis_store.open_subscriber(settings.current.environment, PUBSUB_READ_TIMEOUT_MS)
   if sub == nil then
      logger.warn("event_socket_redis_unavailable", { cause = failure or "" })
      return false
   end

   for _, channel in ipairs(channels) do
      local _, sub_err = sub:subscribe(channel)
      if sub_err ~= nil then
         sub:close()
         logger.warn("event_socket_subscribe_failed", { cause = sub_err })
         return false
      end
   end

   hub.subscriber = sub
   hub.sub_thread = ngx.thread.spawn(function(): string
      while not hub.closed and hub.subscriber == sub do
         local reply, read_err = sub:read_reply()
         if reply ~= nil then
            local msg_channel = reply[2]
            local msg_payload = reply[3]
            if reply[1] == "message" and msg_channel is string and msg_payload is string then
               hub.latest_by_channel[msg_channel] = msg_payload
               schedule_flush(hub)
            end
         elseif read_err ~= "timeout" then
            if not hub.closed and hub.subscriber == sub then
               logger.info("event_socket_redis_closed", { cause = read_err or "" })
            end
            return nil
         end
      end

      return nil
   end)

   return true
end

local function resolve_order_number(caller: Caller, order_ref: string): string, string
   local headers: {string: string} = {
      ["Accept"] = "application/json",
      ["Authorization"] = "Bearer " .. caller.token,
      ["X-Request-Id"] = caller.request_id,
      ["X-Forwarded-For"] = caller.client_ip,
   }
   local base = settings.current.environment.api_upstream

   if event_protocol.is_uuid(order_ref) then
      local reply = http_client.request(
         base .. "/api/v1/orders/" .. order_ref,
         { method = "GET", headers = headers },
         API_TIMEOUTS
      )
      if not reply.reached then
         return nil, "upstream_unavailable"
      end
      if reply.status == 403 then
         return nil, "forbidden"
      end
      if reply.status == 404 then
         return nil, "order_not_found"
      end
      if reply.status ~= 200 then
         return nil, "upstream_unavailable"
      end

      local decoded = cjson.decode(reply.body)
      if not (decoded is cjson.Document) then
         return nil, "upstream_unavailable"
      end

      local order_number = decoded["orderNumber"]
      if order_number is string and order_number ~= "" then
         return order_number, nil
      end

      return nil, "order_not_found"
   end

   return nil, "invalid_order_id"
end

local function handle_subscribe(hub: Hub, caller: Caller, request_id: string, data: cjson.Object)
   local raw_order_id = data["orderId"]
   local raw_order_number = data["orderNumber"]
   local order_ref: string = nil
   if raw_order_id is string and raw_order_id ~= "" then
      order_ref = raw_order_id
   elseif raw_order_number is string and raw_order_number ~= "" then
      order_ref = raw_order_number
   end

   if order_ref == nil then
      local detail = event_protocol.error_detail("invalid_order_id")
      safe_send_text(hub, event_protocol.error_json(request_id, detail, new_event_id(), now_iso()))
      return
   end

   local order_number, err_key = resolve_order_number(caller, order_ref)
   if order_number == nil then
      local detail = event_protocol.error_detail(err_key)
      safe_send_text(hub, event_protocol.error_json(request_id, detail, new_event_id(), now_iso()))
      return
   end

   local channel = event_protocol.subscription_channel(order_number)
   if hub.channels_by_order[order_ref] == nil then
      hub.subscribed_channels[channel] = true
      if not sync_subscriber(hub) then
         hub.subscribed_channels[channel] = nil
         local detail = event_protocol.error_detail("upstream_unavailable")
         safe_send_text(hub, event_protocol.error_json(request_id, detail, new_event_id(), now_iso()))
         return
      end

      hub.channels_by_order[order_ref] = channel
      hub.channels_by_order[order_number] = channel
   end

   local payload: cjson.Object = { subscribed = true, orderId = order_ref, orderNumber = order_number }
   safe_send_text(hub, event_protocol.ack_json(request_id, payload, new_event_id(), now_iso()))
end

local function handle_unsubscribe(hub: Hub, request_id: string, data: cjson.Object)
   local raw_order_id = data["orderId"]
   if not (raw_order_id is string) or raw_order_id == "" then
      local detail = event_protocol.error_detail("invalid_order_id")
      safe_send_text(hub, event_protocol.error_json(request_id, detail, new_event_id(), now_iso()))
      return
   end

   local channel = hub.channels_by_order[raw_order_id]
   if channel ~= nil then
      hub.subscribed_channels[channel] = nil
      for key, value in pairs(hub.channels_by_order) do
         if value == channel then
            hub.channels_by_order[key] = nil
         end
      end
      hub.latest_by_channel[channel] = nil
      sync_subscriber(hub)
   end

   local payload: cjson.Object = { unsubscribed = true, orderId = raw_order_id }
   safe_send_text(hub, event_protocol.ack_json(request_id, payload, new_event_id(), now_iso()))
end

local function open_matching_upstream(caller: Caller): websocket_client.Connection
   if caller.role ~= "courier" and caller.role ~= "seller" and caller.role ~= "admin" then
      return nil
   end

   local upstream, err = websocket_client:new({ timeout = CLIENT_TIMEOUT_MS })
   if upstream == nil then
      logger.warn("event_socket_upstream_init_failed", { cause = err or "", request_id = caller.request_id })
      return nil
   end

   local http_url = settings.current.environment.api_upstream .. UPSTREAM_MATCHING_PATH
   local resolved_http, alias_host = host_aliases.resolve_url(http_url, settings.current.host_aliases)
   local resolved_url = event_protocol.ws_url(resolved_http, "")
   local host = alias_host or socket_handshake.upstream_host(settings.current.environment.api_upstream)
   local headers: {string} = {
      "Authorization: Bearer " .. caller.token,
      "X-Request-Id: " .. caller.request_id,
      "X-Forwarded-For: " .. caller.client_ip,
      "X-Edge-Role: " .. caller.role,
   }

   local connected, failure = upstream:connect(resolved_url, { host = host, headers = headers })
   if connected == nil then
      logger.warn("event_socket_upstream_failed", { cause = failure or "", request_id = caller.request_id })
      return nil
   end

   return upstream
end

local function close_hub(hub: Hub)
   hub.closed = true
   if hub.upstream ~= nil then
      hub.upstream:send_close()
      hub.upstream:close()
      hub.upstream = nil
   end
   stop_subscriber(hub)
   if hub.flush_thread ~= nil then
      ngx.thread.wait(hub.flush_thread)
      hub.flush_thread = nil
   end
   hub.client:send_close()
end

local function spawn_upstream_relay(hub: Hub): ngx.Thread
   if hub.upstream == nil then
      return nil
   end

   return ngx.thread.spawn(function(): string
      while not hub.closed and hub.upstream ~= nil do
         local data, kind, err = hub.upstream:recv_frame()
         if data == nil then
            if err ~= "timeout" then
               hub.closed = true
               return nil
            end
         elseif kind == "close" then
            hub.closed = true
            return nil
         elseif kind == "ping" then
            hub.upstream:send_pong(data)
         elseif kind == "text" then
            if not safe_send_text(hub, data) then
               return nil
            end
         end
      end

      return nil
   end)
end

local function handle_client_text(hub: Hub, caller: Caller, raw: string)
   local parsed = event_protocol.parse_frame(raw)
   if not parsed.ok then
      local detail: event_protocol.ErrorDetail = {
         code = parsed.code,
         reason = parsed.reason,
         message = parsed.message,
         retryable = parsed.retryable,
      }
      safe_send_text(hub, event_protocol.error_json(parsed.request_id, detail, new_event_id(), now_iso()))
      return
   end

   if parsed.event == "system.ping" and hub.upstream == nil then
      safe_send_text(hub, event_protocol.pong_json(parsed.request_id, new_event_id(), now_iso()))
      return
   end

   if parsed.event == "subscription.subscribe" then
      handle_subscribe(hub, caller, parsed.request_id, parsed.data)
      return
   end

   if parsed.event == "subscription.unsubscribe" then
      handle_unsubscribe(hub, parsed.request_id, parsed.data)
      return
   end

   if hub.upstream ~= nil then
      local bytes, send_err = hub.upstream:send_text(raw)
      if bytes == nil then
         logger.warn("event_socket_upstream_send_failed", { cause = send_err or "", request_id = caller.request_id })
         local detail = event_protocol.error_detail("upstream_unavailable")
         safe_send_text(hub, event_protocol.error_json(parsed.request_id, detail, new_event_id(), now_iso()))
         hub.closed = true
      end
      return
   end

   local detail = event_protocol.error_detail("unknown_event")
   safe_send_text(hub, event_protocol.error_json(parsed.request_id, detail, new_event_id(), now_iso()))
end

local function run_session(caller: Caller)
   local upstream = open_matching_upstream(caller)
   if caller.role == "courier" and upstream == nil then
      metrics.socket_upgrade(caller.app_label, "unavailable")
      return respond.error("API_UNAVAILABLE", caller.request_id, nil)
   end

   local server, failure = websocket_server:new({ timeout = CLIENT_TIMEOUT_MS, max_payload_len = MAX_PAYLOAD_LEN })
   if server == nil then
      if upstream ~= nil then
         upstream:close()
      end
      metrics.socket_upgrade(caller.app_label, "refused")
      logger.info("event_socket_upgrade_failed", { cause = failure or "", request_id = caller.request_id })
      return
   end

   metrics.socket_upgrade(caller.app_label, "upgraded")

   local hub: Hub = {
      client = server,
      upstream = upstream,
      subscriber = nil,
      sub_thread = nil,
      flush_thread = nil,
      channels_by_order = {},
      subscribed_channels = {},
      latest_by_channel = {},
      last_flush_at = 0,
      flush_scheduled = false,
      writing = false,
      closed = false,
   }

   local upstream_thread = spawn_upstream_relay(hub)

   while not hub.closed do
      local data, kind, err = server:recv_frame()
      if data == nil then
         if err ~= "timeout" then
            hub.closed = true
         end
      elseif kind == "close" then
         hub.closed = true
      elseif kind == "ping" then
         server:send_pong(data)
      elseif kind == "text" then
         handle_client_text(hub, caller, data)
      end
   end

   close_hub(hub)
   if upstream_thread ~= nil then
      ngx.thread.wait(upstream_thread)
   end
end

local function verify_bearer_me(request: RequestContext, token: string, client_ip: string): string, string
   local url = settings.current.environment.identity_url .. IDENTITY_ME_PATH
   local reply = http_client.request(
      url,
      {
         method = "GET",
         headers = {
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. token,
            ["X-Request-Id"] = request.request_id,
            ["X-Forwarded-For"] = client_ip,
         },
      },
      IDENTITY_TIMEOUTS
   )
   if not reply.reached then
      metrics.dependency_failed("identity")
      metrics.socket_upgrade("api", "unavailable")
      respond.error("IDENTITY_UNAVAILABLE", request.request_id, nil)
      return nil, nil
   end

   if reply.status == 429 then
      metrics.socket_upgrade("api", "refused")
      respond.error("TOO_MANY_REQUESTS", request.request_id, nil)
      return nil, nil
   end

   if reply.status == 401 or reply.status == 403 then
      metrics.socket_upgrade("api", "session_refused")
      respond.error("SESSION_ENDED", request.request_id, nil)
      return nil, nil
   end

   if reply.status ~= 200 then
      metrics.socket_upgrade("api", "unavailable")
      respond.error("IDENTITY_FAILED", request.request_id, nil)
      return nil, nil
   end

   local decoded = cjson.decode(reply.body)
   if not (decoded is cjson.Document) then
      metrics.socket_upgrade("api", "unavailable")
      respond.error("IDENTITY_FAILED", request.request_id, nil)
      return nil, nil
   end

   local principal_id = decoded["principalId"]
   local role = decoded["role"]
   if not (principal_id is string) or principal_id == "" or not (role is string) or role == "" then
      metrics.socket_upgrade("api", "unavailable")
      respond.error("IDENTITY_FAILED", request.request_id, nil)
      return nil, nil
   end

   return principal_id, string.lower(role)
end

function event_socket.serve_bff(request: RequestContext)
   local app = request.app.name
   if not socket_handshake.is_upgrade(request.headers) then
      metrics.socket_upgrade(app, "not_websocket")
      ngx.header["Upgrade"] = "websocket"
      return respond.error("WEBSOCKET_REQUIRED", request.request_id, nil)
   end

   if context.single(request.headers, "origin") ~= request.app.origin then
      metrics.socket_upgrade(app, "origin_refused")
      logger.info("csrf_refused", { reason = "event_socket_origin", app = app, request_id = request.request_id })
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

   ngx.var.edge_client_address = request.client_address
   run_session({
      token = session.access_token,
      role = string.lower(session.role),
      principal_id = session.principal_id,
      client_ip = request.client_address,
      request_id = request.request_id,
      app_label = app,
   })
end

function event_socket.serve_bearer(request: RequestContext)
   if not socket_handshake.is_upgrade(request.headers) then
      metrics.socket_upgrade("api", "not_websocket")
      ngx.header["Upgrade"] = "websocket"
      return respond.error("WEBSOCKET_REQUIRED", request.request_id, nil)
   end

   local token = event_protocol.bearer_token(context.single(request.headers, "authorization"))
   if token == nil then
      metrics.socket_upgrade("api", "session_refused")
      return respond.error("SESSION_REQUIRED", request.request_id, nil)
   end

   local forwarded = client_address.from_forwarded_for(context.joined(request.headers, "x-forwarded-for", ","))
   local client_ip = forwarded or ngx.var.remote_addr or ""
   local principal_id, role = verify_bearer_me(request, token, client_ip)
   if principal_id == nil then
      return
   end

   ngx.var.edge_client_address = client_ip
   run_session({
      token = token,
      role = role,
      principal_id = principal_id,
      client_ip = client_ip,
      request_id = request.request_id,
      app_label = "api",
   })
end

return event_socket
