local errors = require("http.errors")
local respond = require("http.respond")

local record nginx_error
end

function nginx_error.serve(status: integer)
   local request_id = ngx.var.edge_request_id
   if request_id == nil or request_id == "" then
      request_id = ngx.var.request_id
      ngx.var.edge_request_id = request_id
   end

   respond.edge_error(errors.for_status(status), request_id, nil, nil)
end

return nginx_error
