local api_path = require("http.api_path")
local api_routes = require("config.api_routes")
local client_address = require("http.client_address")
local context = require("http.context")
local early_checks = require("http.early_checks")
local event_protocol = require("http.event_protocol")
local forward_headers = require("http.forward_headers")
local json_body = require("http.json_body")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local principal = require("http.principal")
local respond = require("http.respond")
local settings = require("http.settings")
local upstream_relay = require("http.upstream_relay")
local type RequestContext = require("types.request_context")

local record api_proxy
end

function api_proxy.serve(request: RequestContext)
   local rule = api_routes.match(ngx.var.uri)
   if rule == nil then
      return respond.error("NOT_FOUND", request.request_id, nil)
   end

   local address = client_address.from_forwarded_for(context.joined(request.headers, "x-forwarded-for", ","))
   if address == nil then
      return respond.error("CLIENT_ADDRESS_REQUIRED", request.request_id, nil)
   end

   request.client_address = address

   local authorization = context.single(request.headers, "authorization")
   local principal_class = principal.class_from_bearer(authorization)
   ngx.var.edge_principal_class = principal_class

   local checked = early_checks.evaluate(rule, request.method, request.headers, json_body.raw)
   if not checked.ok then
      metrics.decision("early_check", checked.reason)
      logger.info(
         "early_check_refused",
         {
            route = rule.name,
            reason = checked.reason,
            principal_class = principal_class,
            request_id = request.request_id,
         }
      )
      return respond.error(checked.error_code, request.request_id, nil)
   end

   metrics.decision("early_check", "allowed")

   local path = api_path.normalize(ngx.var.uri)
   if path == nil then
      return respond.error("NOT_FOUND", request.request_id, nil)
   end

   local environment = settings.current.environment
   local base = environment.api_upstream
   if rule.target == "identity" then
      base = environment.identity_url
   end

   local bearer = event_protocol.bearer_token(authorization)
   local headers = forward_headers.api_upstream(request.headers, request, rule, bearer)
   upstream_relay.send(request.request_id, request.method, base, path, rule.target, checked.body, headers)
end

return api_proxy
