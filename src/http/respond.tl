local cjson = require("cjson.safe")
local errors = require("http.errors")
local type EdgeError = require("types.edge_error")
local type ErrorBody = require("types.error_body")

local record respond
end

local function cookies_out(set_cookies: {string})
   if set_cookies ~= nil and #set_cookies > 0 then
      ngx.header["Set-Cookie"] = set_cookies
   end
end

function respond.raw(status: integer, body: string, set_cookies: {string})
   ngx.status = status
   ngx.header["Content-Type"] = "application/json"
   cookies_out(set_cookies)
   ngx.print(body)
end

function respond.json<T>(status: integer, value: T, set_cookies: {string})
   local body = cjson.encode(value)
   if body == nil then
      body = "{}"
   end

   respond.raw(status, body, set_cookies)
end

function respond.no_content(set_cookies: {string})
   ngx.status = 204
   cookies_out(set_cookies)
end

function respond.edge_error(failure: EdgeError, request_id: string, set_cookies: {string}, retry_after: string)
   local body: ErrorBody = { error = failure.code, message = failure.message, requestId = request_id }
   if retry_after ~= nil then
      ngx.header["Retry-After"] = retry_after
   end

   respond.json(failure.status, body, set_cookies)
end

function respond.error(code: string, request_id: string, set_cookies: {string})
   respond.edge_error(errors.catalogue[code], request_id, set_cookies, nil)
end

function respond.method_not_allowed(allowed: string, request_id: string)
   ngx.header["Allow"] = allowed
   respond.error("METHOD_NOT_ALLOWED", request_id, nil)
end

return respond
