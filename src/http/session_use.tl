local cookies = require("http.cookies")
local redis = require("resty.redis")
local respond = require("http.respond")
local sessions = require("http.sessions")
local sign_in = require("http.sign_in")
local type RequestContext = require("types.request_context")
local type Session = require("types.session")

local record session_use
end

local function refused(request: RequestContext, code: string): Session, string
   if code == "SESSION_ENDED" or code == "ROLE_REFUSED" then
      respond.error(code, request.request_id, { cookies.expired(cookies.session_name) })
   else
      respond.error(code, request.request_id, nil)
   end

   return nil, code
end

function session_use.usable(client: redis.Client, request: RequestContext): Session, string
   local value = sign_in.session_cookie(request)
   local found = sessions.lookup(client, request, value)
   if found.state == "unavailable" then
      return refused(request, "SESSION_STORE_UNAVAILABLE")
   end

   if found.state ~= "found" then
      if value == nil then
         return refused(request, "SESSION_REQUIRED")
      end

      return refused(request, "SESSION_ENDED")
   end

   ngx.var.edge_session_tag = sessions.tag_of(value)

   local touched = sessions.touch(client, request, found)
   if touched == "ended" then
      return refused(request, "SESSION_ENDED")
   end

   if touched ~= "found" then
      return refused(request, "SESSION_STORE_UNAVAILABLE")
   end

   if not sessions.needs_refresh(found.session) then
      return found.session, nil
   end

   local result = sessions.refresh(client, request, found)
   if result.outcome == "renewed" then
      return result.session, nil
   end

   if result.outcome == "refused" then
      return refused(request, "SESSION_ENDED")
   end

   if result.outcome == "role_refused" then
      return refused(request, "ROLE_REFUSED")
   end

   if result.outcome == "store_unavailable" then
      return refused(request, "SESSION_STORE_UNAVAILABLE")
   end

   return refused(request, "IDENTITY_UNAVAILABLE")
end

return session_use
