local type RequestContext = require("types.request_context")

local record Route
   path: string
   prefix: boolean
   name: string
   methods: {string}
   for_app: boolean
   handler: function(RequestContext)
end

return Route
