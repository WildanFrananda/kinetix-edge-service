local clock = require("adapters.clock")
local cookies = require("http.cookies")
local lifetimes = require("http.lifetimes")
local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local sessions = require("http.sessions")
local sign_in = require("http.sign_in")
local type RequestContext = require("types.request_context")
local type SessionView = require("types.session_view")

local record session_endpoint
end

function session_endpoint.serve(request: RequestContext)
   local client = sessions.open()
   if client == nil then
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   local value = sign_in.session_cookie(request)
   local found = sessions.lookup(client, request, value)
   redis_store.release(client)

   if found.state == "unavailable" then
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   if found.state ~= "found" then
      local set_cookies: {string} = {}
      if value ~= nil then
         table.insert(set_cookies, cookies.expired(cookies.session_name))
      end

      return respond.json(200, { authenticated = false }, set_cookies)
   end

   ngx.var.edge_session_tag = sessions.tag_of(value)

   local view: SessionView = {
      authenticated = true,
      role = found.session.role,
      principalId = found.session.principal_id,
      expiresAt = clock.iso8601(lifetimes.ends_at(request.app, found.session)),
   }

   respond.json(200, view, nil)
end

return session_endpoint
