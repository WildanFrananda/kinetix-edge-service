local cookies = require("http.cookies")
local identity_client = require("adapters.identity_client")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local sessions = require("http.sessions")
local sign_in = require("http.sign_in")
local type RequestContext = require("types.request_context")
local type Session = require("types.session")
local type SessionLookup = require("types.session_lookup")

local record logout
end

local function expired_cookies(): {string}
   return { cookies.expired(cookies.session_name), cookies.expired(cookies.pending_name) }
end

local function pending_keys(request: RequestContext): {string}
   local keys: {string} = {}
   local pending = sign_in.pending_cookie(request)
   if pending ~= nil then
      table.insert(keys, sessions.pending_key_of(pending))
   end

   return keys
end

local function signed_out(client: redis.Client, request: RequestContext, found: SessionLookup, revoked: boolean)
   local keys = pending_keys(request)
   if found ~= nil and found.key ~= nil then
      table.insert(keys, found.key)
   end

   local deleted = true
   if found ~= nil and found.state == "found" then
      deleted = sessions.finish(client, request, keys, "logout")
   else
      deleted = redis_store.delete(client, keys)
   end

   if not deleted then
      if not revoked then
         return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
      end

      logger.warn("revoked_session_not_deleted", { request_id = request.request_id })
   end

   respond.no_content(expired_cookies())
end

local function current_session(client: redis.Client, request: RequestContext, found: SessionLookup): Session, string
   if not sessions.needs_refresh(found.session) then
      return found.session, nil
   end

   local result = sessions.refresh(client, request, found)
   if result.outcome == "renewed" then
      return result.session, nil
   end

   if result.outcome == "refused" or result.outcome == "role_refused" then
      return nil, nil
   end

   if result.outcome == "store_unavailable" then
      return nil, "SESSION_STORE_UNAVAILABLE"
   end

   return nil, "IDENTITY_UNAVAILABLE"
end

local function settle(client: redis.Client, request: RequestContext, found: SessionLookup)
   local session, failure = current_session(client, request, found)
   if failure ~= nil then
      return respond.error(failure, request.request_id, nil)
   end

   if session == nil then
      return signed_out(client, request, nil, false)
   end

   local reply = identity_client.logout(request, session.access_token, session.refresh_token)
   if not reply.reached or reply.status >= 500 or reply.status == 429 then
      metrics.dependency_failed("identity")
      logger.warn(
         "identity_unavailable",
         { stage = "logout", status = reply.status or 0, cause = reply.cause or "", request_id = request.request_id }
      )
      return respond.error("IDENTITY_UNAVAILABLE", request.request_id, nil)
   end

   if reply.status >= 300 and reply.status ~= 401 and reply.status ~= 403 then
      logger.error(
         "identity_answer_not_understood",
         { stage = "logout", status = reply.status, request_id = request.request_id }
      )
      return respond.error("IDENTITY_FAILED", request.request_id, nil)
   end

   signed_out(client, request, found, true)
end

function logout.serve(request: RequestContext)
   local client = sessions.open()
   if client == nil then
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   local value = sign_in.session_cookie(request)
   local found = sessions.lookup(client, request, value)
   if found.state == "unavailable" then
      respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   elseif found.state == "found" then
      ngx.var.edge_session_tag = sessions.tag_of(value)
      settle(client, request, found)
   else
      signed_out(client, request, nil, false)
   end

   redis_store.release(client)
end

return logout
