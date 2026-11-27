local forward_headers = require("http.forward_headers")
local http_client = require("adapters.http_client")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local respond = require("http.respond")
local timing = require("config.timing")

local record upstream_relay
end

local TIMEOUTS: http_client.Timeouts = {
   connect_ms = timing.api_connect_ms,
   send_ms = timing.api_send_ms,
   read_ms = timing.api_read_ms,
}

function upstream_relay.send(
   request_id: string,
   method: string,
   base_url: string,
   path: string,
   dependency: string,
   body: string,
   headers: {string: string}
)
   local query = ngx.var.args
   local url = base_url .. path
   if query ~= nil and query ~= "" then
      url = url .. "?" .. query
   end

   local reply = http_client.request(
      url,
      {
         method = method,
         body = body,
         headers = headers,
      },
      TIMEOUTS
   )
   if not reply.reached then
      metrics.dependency_failed(dependency)
      logger.warn(
         "api_unavailable",
         { upstream = dependency, cause = reply.cause or "", request_id = request_id }
      )
      return respond.error("API_UNAVAILABLE", request_id, nil)
   end

   ngx.status = reply.status
   for name, value in pairs(forward_headers.downstream(reply.headers)) do
      ngx.header[name] = value
   end

   if method ~= "HEAD" and reply.body ~= "" then
      ngx.print(reply.body)
   end
end

return upstream_relay
