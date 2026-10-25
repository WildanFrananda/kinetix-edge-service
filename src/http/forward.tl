local api_path = require("http.api_path")
local cookies = require("http.cookies")
local forward_headers = require("http.forward_headers")
local http_client = require("adapters.http_client")
local json_body = require("http.json_body")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local sessions = require("http.sessions")
local settings = require("http.settings")
local sign_in = require("http.sign_in")
local timing = require("config.timing")
local type RequestContext = require("types.request_context")
local type Session = require("types.session")

local record forward
end

local TIMEOUTS: http_client.Timeouts = {
   connect_ms = timing.api_connect_ms,
   send_ms = timing.api_send_ms,
   read_ms = timing.api_read_ms,
}

local BODY_METHODS: {string: boolean} = { ["POST"] = true, ["PUT"] = true, ["PATCH"] = true, ["DELETE"] = true }

local function ended(request: RequestContext, code: string)
   respond.error(code, request.request_id, { cookies.expired(cookies.session_name) })
end

local function usable_session(client: redis.Client, request: RequestContext): Session
   local value = sign_in.session_cookie(request)
   local found = sessions.lookup(client, request, value)
   if found.state == "unavailable" then
      respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
      return nil
   end

   if found.state ~= "found" then
      if value == nil then
         respond.error("SESSION_REQUIRED", request.request_id, nil)
      else
         ended(request, "SESSION_ENDED")
      end

      return nil
   end

   ngx.var.edge_session_tag = sessions.tag_of(value)

   if not sessions.touch(client, request, found) then
      respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
      return nil
   end

   if not sessions.needs_refresh(found.session) then
      return found.session
   end

   local result = sessions.refresh(client, request, found)
   if result.outcome == "renewed" then
      return result.session
   end

   if result.outcome == "refused" then
      ended(request, "SESSION_ENDED")
   elseif result.outcome == "role_refused" then
      ended(request, "ROLE_REFUSED")
   elseif result.outcome == "store_unavailable" then
      respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   else
      respond.error("IDENTITY_UNAVAILABLE", request.request_id, nil)
   end

   return nil
end

local function relay(request: RequestContext, path: string, session: Session)
   local body: string = nil
   if BODY_METHODS[request.method] then
      body = json_body.raw()
      if body == nil then
         return respond.error("PAYLOAD_TOO_LARGE", request.request_id, nil)
      end

      if body == "" then
         body = nil
      end
   end

   local environment = settings.current.environment
   local base = environment.api_upstream
   local dependency = "api"
   local client: string = nil
   if api_path.is_identity(path) then
      base = environment.identity_url
      dependency = "identity"
      client = request.app.client
   end

   local query = ngx.var.args
   local url = base .. path
   if query ~= nil and query ~= "" then
      url = url .. "?" .. query
   end

   local reply = http_client.request(
      url,
      {
         method = request.method,
         body = body,
         headers = forward_headers.upstream(request.headers, request, session.access_token, client),
      },
      TIMEOUTS
   )
   if not reply.reached then
      metrics.dependency_failed(dependency)
      logger.warn(
         "api_unavailable",
         { upstream = dependency, cause = reply.cause or "", request_id = request.request_id }
      )
      return respond.error("API_UNAVAILABLE", request.request_id, nil)
   end

   ngx.status = reply.status
   for name, value in pairs(forward_headers.downstream(reply.headers)) do
      ngx.header[name] = value
   end

   if request.method ~= "HEAD" and reply.body ~= "" then
      ngx.print(reply.body)
   end
end

function forward.serve(request: RequestContext)
   local path = api_path.upstream(ngx.var.uri)
   if path == nil or api_path.is_refused(path) then
      return respond.error("NOT_FOUND", request.request_id, nil)
   end

   local client = sessions.open()
   if client == nil then
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   local session = usable_session(client, request)
   redis_store.release(client)

   if session ~= nil then
      relay(request, path, session)
   end
end

return forward
