local type AppPolicy = require("types.app_policy")
local type RequestContext = require("types.request_context")

local record Route
   path: string
   prefix: boolean
   name: string
   methods: {string}
   for_app: boolean
   offered: function(AppPolicy): boolean
   handler: function(RequestContext)
end

return Route
