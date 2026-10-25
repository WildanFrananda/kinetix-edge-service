local logger = require("adapters.logger")
local metrics = require("adapters.metrics")

local record access_log
end

function access_log.write()
   ngx.update_time()

   local seconds = ngx.now() - ngx.req.start_time()
   local route = ngx.var.edge_route or "unmatched"
   local method = ngx.req.get_method()
   local status = ngx.status
   local request_id = ngx.var.edge_request_id
   if request_id == nil or request_id == "" then
      request_id = ngx.var.request_id
   end

   metrics.request(method, route, status, seconds)
   logger.info(
      "request",
      {
         method = method,
         route = route,
         status = status,
         duration_ms = math.floor(seconds * 1000 + 0.5),
         request_id = request_id,
         app = ngx.var.edge_app or "",
         session = ngx.var.edge_session_tag or "",
      }
   )
end

return access_log
