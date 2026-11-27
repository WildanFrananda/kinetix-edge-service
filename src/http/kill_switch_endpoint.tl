local cjson = require("cjson.safe")
local json_body = require("http.json_body")
local kill_switches = require("http.kill_switches")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local session_use = require("http.session_use")
local sessions = require("http.sessions")
local settings = require("http.settings")
local type RequestContext = require("types.request_context")
local type Session = require("types.session")

local record kill_switch_endpoint
end

local MAX_MESSAGE_KEY_LEN = 64
local MAX_REASON_LEN = 200
local MIN_RETRY_AFTER = 1
local MAX_RETRY_AFTER = 86400
local MIN_TTL_SECONDS = 60
local MAX_TTL_SECONDS = 604800

local function open_admin_session(request: RequestContext): redis.Client, Session
   local client = sessions.open()
   if client == nil then
      respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
      return nil, nil
   end

   local session = session_use.usable(client, request)
   if session == nil then
      redis_store.release(client)
      return nil, nil
   end

   if string.lower(session.role or "") ~= "admin" then
      redis_store.release(client)
      respond.error("ROLE_REFUSED", request.request_id, nil)
      return nil, nil
   end

   return client, session
end

local function feature_from_uri(uri: string): string
   if uri == nil then
      return nil
   end

   local matched = string.match(uri, "^/bff/edge/kill%-switches/([%a_]+)$")
   if matched == nil or not kill_switches.is_known(matched) then
      return nil
   end

   return string.lower(matched)
end

local function optional_integer(doc: cjson.Document, name: string, low: integer, high: integer): integer, boolean
   local raw = doc[name]
   if raw == nil then
      return nil, true
   end

   if not (raw is number) or raw ~= math.floor(raw) or raw < low or raw > high then
      return nil, false
   end

   return math.floor(raw), true
end

local function optional_message_key(doc: cjson.Document): string, boolean
   local raw = doc["messageKey"]
   if raw == nil then
      return nil, true
   end

   if not (raw is string) or raw == "" or #raw > MAX_MESSAGE_KEY_LEN then
      return nil, false
   end

   if string.match(raw, "^[A-Z0-9_]+$") == nil then
      return nil, false
   end

   return raw, true
end

local function optional_reason(doc: cjson.Document): string, boolean
   local raw = doc["reason"]
   if raw == nil then
      return nil, true
   end

   if not (raw is string) or #raw > MAX_REASON_LEN then
      return nil, false
   end

   return raw, true
end

function kill_switch_endpoint.list(request: RequestContext)
   local client, session = open_admin_session(request)
   if session == nil then
      return
   end

   redis_store.release(client)
   local items, unavailable = kill_switches.list(settings.current.environment)
   if unavailable then
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   respond.json(200, { features = items }, nil)
end

function kill_switch_endpoint.serve(request: RequestContext)
   local feature = feature_from_uri(ngx.var.uri)
   if feature == nil then
      return respond.error("NOT_FOUND", request.request_id, nil)
   end

   local client, session = open_admin_session(request)
   if session == nil then
      return
   end

   redis_store.release(client)
   local environment = settings.current.environment

   if request.method == "GET" then
      local state, unavailable = kill_switches.get_state(environment, feature)
      if unavailable then
         return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
      end

      return respond.json(200, state, nil)
   end

   if request.method == "DELETE" then
      local state, unavailable = kill_switches.update(
         environment,
         feature,
         session.principal_id,
         false,
         nil,
         nil,
         nil,
         nil,
         request.request_id
      )
      if unavailable then
         return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
      end

      return respond.json(200, state, nil)
   end

   local body = json_body.object()
   local raw_enabled = body ~= nil and body["enabled"] or nil
   if not (raw_enabled is boolean) then
      return respond.error("INVALID_REQUEST", request.request_id, nil)
   end

   local enabled = raw_enabled as boolean
   local message_key, key_ok = optional_message_key(body)
   local retry_after, retry_ok = optional_integer(body, "retryAfter", MIN_RETRY_AFTER, MAX_RETRY_AFTER)
   local ttl_seconds, ttl_ok = optional_integer(body, "ttlSeconds", MIN_TTL_SECONDS, MAX_TTL_SECONDS)
   local reason, reason_ok = optional_reason(body)
   if not key_ok or not retry_ok or not ttl_ok or not reason_ok then
      return respond.error("INVALID_REQUEST", request.request_id, nil)
   end

   local updated, unavailable = kill_switches.update(
      environment,
      feature,
      session.principal_id,
      enabled,
      message_key,
      retry_after,
      ttl_seconds,
      reason,
      request.request_id
   )
   if unavailable then
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   respond.json(200, updated, nil)
end

return kill_switch_endpoint
