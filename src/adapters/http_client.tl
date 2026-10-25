local http = require("resty.http")
local timing = require("config.timing")
local type UpstreamReply = require("types.upstream_reply")

local record http_client
   record Timeouts
      connect_ms: integer
      send_ms: integer
      read_ms: integer
   end
end

function http_client.request(url: string, params: http.Params, timeouts: http_client.Timeouts): UpstreamReply
   local client, failure = http.new()
   if client == nil then
      return { reached = false, cause = failure }
   end

   client:set_timeouts(timeouts.connect_ms, timeouts.send_ms, timeouts.read_ms)
   params.keepalive_timeout = timing.upstream_keepalive_ms
   params.keepalive_pool = timing.upstream_pool_size

   local response, unreached = client:request_uri(url, params)
   if response == nil then
      return { reached = false, cause = unreached }
   end

   return { reached = true, status = response.status, headers = response.headers, body = response.body or "" }
end

return http_client
