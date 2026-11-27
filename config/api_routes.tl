local forwarding = require("config.forwarding")
local type ApiRouteRule = require("types.api_route_rule")

local record api_routes
   rules: {ApiRouteRule}
end

api_routes.rules = {
   {
      name = "/api/v1/auth/login",
      prefix = "/api/v1/auth/login",
      exact = true,
      methods = { "POST" },
      target = "identity",
      max_body_bytes = 16384,
      require_json = true,
      require_idempotency = false,
      strip_client_header = false,
   },
   {
      name = "/api/v1/auth/register",
      prefix = "/api/v1/auth/register",
      exact = true,
      methods = { "POST" },
      target = "identity",
      max_body_bytes = 16384,
      require_json = true,
      require_idempotency = false,
      strip_client_header = false,
   },
   {
      name = "/api/v1/auth/refresh",
      prefix = "/api/v1/auth/refresh",
      exact = true,
      methods = { "POST" },
      target = "identity",
      max_body_bytes = 16384,
      require_json = true,
      require_idempotency = false,
      strip_client_header = false,
   },
   {
      name = "/api/v1/auth/2fa/verify",
      prefix = "/api/v1/auth/2fa/verify",
      exact = true,
      methods = { "POST" },
      target = "identity",
      max_body_bytes = 16384,
      require_json = true,
      require_idempotency = false,
      strip_client_header = false,
   },
   {
      name = "/api/v1/auth/logout",
      prefix = "/api/v1/auth/logout",
      exact = true,
      methods = { "POST" },
      target = "identity",
      max_body_bytes = 16384,
      require_json = true,
      require_idempotency = false,
      strip_client_header = false,
   },
   {
      name = "/api/v1/auth/{path}",
      prefix = "/api/v1/auth",
      exact = false,
      methods = forwarding.methods,
      target = "identity",
      max_body_bytes = 32768,
      require_json = true,
      require_idempotency = false,
      strip_client_header = false,
   },
   {
      name = "/api/v1/couriers/register",
      prefix = "/api/v1/couriers/register",
      exact = true,
      methods = { "POST" },
      target = "identity",
      max_body_bytes = 32768,
      require_json = true,
      require_idempotency = false,
      strip_client_header = false,
   },
   {
      name = "/api/v1/couriers/{path}",
      prefix = "/api/v1/couriers",
      exact = false,
      methods = forwarding.methods,
      target = "identity",
      max_body_bytes = 65536,
      require_json = true,
      require_idempotency = false,
      strip_client_header = false,
   },
   {
      name = "/api/v1/orders/checkout",
      prefix = "/api/v1/orders/checkout",
      exact = true,
      methods = { "POST" },
      target = "api",
      max_body_bytes = 65536,
      require_json = true,
      require_idempotency = true,
      strip_client_header = true,
   },
   {
      name = "/api/v1/orders/{path}",
      prefix = "/api/v1/orders",
      exact = false,
      methods = forwarding.methods,
      target = "api",
      max_body_bytes = 65536,
      require_json = true,
      require_idempotency = false,
      strip_client_header = true,
   },
   {
      name = "/api/v1/cart/{path}",
      prefix = "/api/v1/cart",
      exact = false,
      methods = forwarding.methods,
      target = "api",
      max_body_bytes = 32768,
      require_json = true,
      require_idempotency = false,
      strip_client_header = true,
   },
   {
      name = "/api/v1/payment/wallet/customer/topup",
      prefix = "/api/v1/payment/wallet/customer/topup",
      exact = true,
      methods = { "POST" },
      target = "api",
      max_body_bytes = 16384,
      require_json = true,
      require_idempotency = true,
      strip_client_header = true,
   },
   {
      name = "/api/v1/payment/gateway/midtrans/notifications",
      prefix = "/api/v1/payment/gateway/midtrans/notifications",
      exact = true,
      methods = { "POST" },
      target = "api",
      max_body_bytes = 65536,
      require_json = true,
      require_idempotency = false,
      strip_client_header = true,
   },
   {
      name = "/api/v1/payment/{path}",
      prefix = "/api/v1/payment",
      exact = false,
      methods = forwarding.methods,
      target = "api",
      max_body_bytes = 65536,
      require_json = true,
      require_idempotency = false,
      strip_client_header = true,
   },
}

local function matches_rule(rule: ApiRouteRule, uri: string): boolean
   if rule.exact then
      return uri == rule.prefix
   end

   return uri == rule.prefix or string.sub(uri, 1, #rule.prefix + 1) == rule.prefix .. "/"
end

function api_routes.match(uri: string): ApiRouteRule
   if uri == nil then
      return nil
   end

   for _, rule in ipairs(api_routes.rules) do
      if matches_rule(rule, uri) then
         return rule
      end
   end

   return nil
end

return api_routes
