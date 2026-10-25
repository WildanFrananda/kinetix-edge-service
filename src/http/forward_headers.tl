local forwarding = require("config.forwarding")
local http = require("resty.http")
local type RequestContext = require("types.request_context")

local record forward_headers
end

local function joined(value: http.HeaderValue): string
   if value is string then
      return value
   end

   return table.concat(value, ", ")
end

local function is_dropped(name: string): boolean
   local lowered = string.lower(name)
   for _, dropped in ipairs(forwarding.dropped_response_headers) do
      if lowered == dropped then
         return true
      end
   end

   return false
end

function forward_headers.upstream(
   browser: {string: http.HeaderValue},
   context: RequestContext,
   access_token: string,
   client: string
): {string: string}
   local headers: {string: string} = {}
   for _, name in ipairs(forwarding.request_headers) do
      local value = browser[name]
      if value ~= nil then
         headers[name] = joined(value)
      end
   end

   headers["authorization"] = "Bearer " .. access_token
   headers["x-request-id"] = context.request_id
   headers["x-forwarded-for"] = context.client_address
   if client ~= nil then
      headers["x-kinetix-client"] = client
   end

   return headers
end

function forward_headers.downstream(upstream: {string: http.HeaderValue}): {string: http.HeaderValue}
   local headers: {string: http.HeaderValue} = {}
   for name, value in pairs(upstream) do
      if not is_dropped(name) then
         headers[name] = value
      end
   end

   return headers
end

return forward_headers
