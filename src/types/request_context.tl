local http = require("resty.http")
local type AppPolicy = require("types.app_policy")

local record RequestContext
   request_id: string
   client_address: string
   app: AppPolicy
   method: string
   headers: {string: http.HeaderValue}
end

return RequestContext
