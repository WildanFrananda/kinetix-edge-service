local http = require("resty.http")

local record UpstreamReply
   reached: boolean
   cause: string
   status: integer
   headers: {string: http.HeaderValue}
   body: string
end

return UpstreamReply
