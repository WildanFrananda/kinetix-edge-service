local api_auth = require("config.api_auth")
local api_path = require("http.api_path")
local api_routes = require("config.api_routes")
local app_version = require("http.app_version")
local client_address = require("http.client_address")
local context = require("http.context")
local early_checks = require("http.early_checks")
local errors = require("http.errors")
local event_protocol = require("http.event_protocol")
local forward_headers = require("http.forward_headers")
local ip_cidr = require("http.ip_cidr")
local json_body = require("http.json_body")
local kill_switches = require("http.kill_switches")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local principal = require("http.principal")
local rate_limiter = require("http.rate_limiter")
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

   if rule.allowed_cidrs ~= nil then
      if not ip_cidr.matches_any(address, rule.allowed_cidrs) then
         metrics.decision("webhook", "refused")
         logger.info(
            "webhook_refused",
            { route = rule.name, reason = "untrusted_source", request_id = request.request_id }
         )
         return respond.error("WEBHOOK_FORBIDDEN", request.request_id, nil)
      end

      metrics.decision("webhook", "allowed")
   end

   local environment = settings.current.environment
   if rule.kill_switch ~= nil then
      local ks = kill_switches.evaluate(environment, rule.kill_switch)
      if not ks.ok then
         if ks.unavailable then
            return respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
         end

         metrics.decision("kill_switch", rule.kill_switch)
         logger.info(
            "kill_switch_refused",
            { route = rule.name, feature = rule.kill_switch, request_id = request.request_id }
         )
         return respond.feature_disabled(
            errors.catalogue["FEATURE_DISABLED"],
            request.request_id,
            ks.retry_after,
            ks.message_key
         )
      end
   end

   local client_header = context.single(request.headers, "x-kinetix-client")
   local version_header = context.single(request.headers, "x-kinetix-app-version")
   local version_check = app_version.evaluate(client_header, version_header)
   if not version_check.ok then
      metrics.decision("app_version", version_check.reason)
      logger.info(
         "app_version_refused",
         {
            route = rule.name,
            reason = version_check.reason,
            client = version_check.client or "",
            request_id = request.request_id,
         }
      )
      if version_check.error_code == "UPGRADE_REQUIRED" then
         return respond.upgrade_required(
            errors.catalogue["UPGRADE_REQUIRED"],
            request.request_id,
            version_check.minimum_version,
            version_check.store_url
         )
      end

      return respond.error(version_check.error_code, request.request_id, nil)
   end

   if version_check.version ~= nil then
      metrics.decision("app_version", "allowed")
   end

   local authorization = context.single(request.headers, "authorization")
   local claims = principal.inspect(authorization, api_auth.expected_audience)
   ngx.var.edge_principal_class = claims.principal_class

   if rule.require_auth then
      local auth_check = principal.authorize(claims, rule)
      if not auth_check.ok then
         metrics.decision("auth", auth_check.reason)
         logger.info(
            "auth_refused",
            {
               route = rule.name,
               reason = auth_check.reason,
               principal_class = claims.principal_class,
               request_id = request.request_id,
            }
         )
         return respond.error(auth_check.error_code, request.request_id, nil)
      end

      metrics.decision("auth", "allowed")
   end

   local checked = early_checks.evaluate(rule, request.method, request.headers, json_body.raw)
   if not checked.ok then
      metrics.decision("early_check", checked.reason)
      logger.info(
         "early_check_refused",
         {
            route = rule.name,
            reason = checked.reason,
            principal_class = claims.principal_class,
            request_id = request.request_id,
         }
      )
      return respond.error(checked.error_code, request.request_id, nil)
   end

   metrics.decision("early_check", "allowed")

   if rule.rate_limit_group ~= nil then
      local rl = rate_limiter.evaluate(environment, rule, request, claims, checked.body)
      if not rl.ok then
         if rl.unavailable then
            return respond.error(rl.error_code, request.request_id, nil)
         end

         metrics.decision("rate_limit", rl.reason)
         logger.info(
            "rate_limited",
            {
               route = rule.name,
               reason = rl.reason,
               principal_class = claims.principal_class,
               request_id = request.request_id,
            }
         )
         return respond.edge_error(
            errors.catalogue["TOO_MANY_REQUESTS"],
            request.request_id,
            nil,
            rl.retry_after
         )
      end

      metrics.decision("rate_limit", "allowed")
   end

   local path = api_path.normalize(ngx.var.uri)
   if path == nil then
      return respond.error("NOT_FOUND", request.request_id, nil)
   end

   local base = environment.api_upstream
   if rule.target == "identity" then
      base = environment.identity_url
   end

   local bearer = event_protocol.bearer_token(authorization)
   local headers = forward_headers.api_upstream(request.headers, request, rule, bearer)
   upstream_relay.send(request.request_id, request.method, base, path, rule.target, checked.body, headers)
end

return api_proxy
