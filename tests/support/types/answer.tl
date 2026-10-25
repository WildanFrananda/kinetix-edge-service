local cjson = require("cjson.safe")
local http = require("resty.http")

local record Answer
   status: integer
   headers: {string: http.HeaderValue}
   body: string
   json: cjson.Document
   set_cookies: {string}
end

return Answer
