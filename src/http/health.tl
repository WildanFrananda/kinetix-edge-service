local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local sessions = require("http.sessions")
local type RequestContext = require("types.request_context")

local record health
end

function health.live(_: RequestContext)
   respond.json(200, { status = "ok" }, nil)
end

function health.ready(request: RequestContext)
   local client = sessions.open()
   if client == nil then
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   local answered = redis_store.ping(client)
   redis_store.release(client)

   if not answered then
      return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   respond.json(200, { status = "ready" }, nil)
end

return health
