local host_aliases = require("adapters.host_aliases")
local http = require("resty.http")
local settings = require("http.settings")
local timing = require("config.timing")
local type UpstreamReply = require("types.upstream_reply")

local record http_client
   record Timeouts
      connect_ms: integer
      send_ms: integer
      read_ms: integer
   end
end

local function with_host_header(params: http.Params, host_header: string): http.Params
   local headers: {string: string} = {}
   if params.headers ~= nil then
      for name, value in pairs(params.headers) do
         headers[name] = value
      end
   end

   if headers["host"] == nil and headers["Host"] == nil then
      headers["host"] = host_header
   end

   return {
      method = params.method,
      body = params.body,
      headers = headers,
      keepalive_timeout = params.keepalive_timeout,
      keepalive_pool = params.keepalive_pool,
   }
end

function http_client.request(url: string, params: http.Params, timeouts: http_client.Timeouts): UpstreamReply
   local client, failure = http.new()
   if client == nil then
      return { reached = false, cause = failure }
   end

   local aliases = settings.current ~= nil and settings.current.host_aliases or nil
   local target_url, host_header = host_aliases.resolve_url(url, aliases)
   local request_params = params
   if host_header ~= nil then
      request_params = with_host_header(params, host_header)
   end

   client:set_timeouts(timeouts.connect_ms, timeouts.send_ms, timeouts.read_ms)
   request_params.keepalive_timeout = timing.upstream_keepalive_ms
   request_params.keepalive_pool = timing.upstream_pool_size

   local response, unreached = client:request_uri(target_url, request_params)
   if response == nil then
      return { reached = false, cause = unreached }
   end

   return { reached = true, status = response.status, headers = response.headers, body = response.body or "" }
end

return http_client
