local forwarding = require("config.forwarding")
local http = require("resty.http")
local type ApiRouteRule = require("types.api_route_rule")
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

local function base_upstream(browser: {string: http.HeaderValue}, context: RequestContext): {string: string}
   local headers: {string: string} = {}
   for _, name in ipairs(forwarding.request_headers) do
      local value = browser[name]
      if value ~= nil then
         headers[name] = joined(value)
      end
   end

   headers["x-request-id"] = context.request_id
   headers["x-forwarded-for"] = context.client_address

   return headers
end

function forward_headers.upstream(
   browser: {string: http.HeaderValue},
   context: RequestContext,
   access_token: string,
   client: string,
   face: string
): {string: string}
   local headers = base_upstream(browser, context)
   headers["authorization"] = "Bearer " .. access_token
   if client ~= nil then
      headers["x-kinetix-client"] = client
   end

   if face ~= nil then
      headers["x-kinetix-origin"] = face
   end

   return headers
end

function forward_headers.api_upstream(
   browser: {string: http.HeaderValue},
   context: RequestContext,
   rule: ApiRouteRule,
   bearer_token: string
): {string: string}
   local headers = base_upstream(browser, context)
   if bearer_token ~= nil then
      headers["authorization"] = "Bearer " .. bearer_token
   end

   if not rule.strip_client_header then
      local client_header = browser["x-kinetix-client"]
      if client_header ~= nil then
         headers["x-kinetix-client"] = joined(client_header)
      end

      local app_check = browser["x-firebase-appcheck"]
      if app_check ~= nil then
         headers["x-firebase-appcheck"] = joined(app_check)
      end
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
