local context = require("http.context")
local csrf = require("http.csrf")
local forward = require("http.forward")
local forwarding = require("config.forwarding")
local health = require("http.health")
local json_body = require("http.json_body")
local logger = require("adapters.logger")
local logout = require("http.logout")
local merchant_socket = require("http.merchant_socket")
local metrics = require("adapters.metrics")
local respond = require("http.respond")
local session_endpoint = require("http.session_endpoint")
local sign_in = require("http.sign_in")
local sign_up = require("http.sign_up")
local type AppPolicy = require("types.app_policy")
local type RequestContext = require("types.request_context")
local type Route = require("types.route")

local record router
   routes: {Route}
end

local function offers_sign_up(app: AppPolicy): boolean
   return app.sign_up
end

local function offers_merchant_socket(app: AppPolicy): boolean
   return #app.merchant_socket_roles > 0
end

router.routes = {
   {
      path = "/health",
      prefix = false,
      name = "/health",
      methods = { "GET", "HEAD" },
      for_app = false,
      handler = health.live,
   },
   {
      path = "/health/ready",
      prefix = false,
      name = "/health/ready",
      methods = { "GET", "HEAD" },
      for_app = false,
      handler = health.ready,
   },
   {
      path = "/bff/session",
      prefix = false,
      name = "/bff/session",
      methods = { "GET" },
      for_app = true,
      handler = session_endpoint.serve,
   },
   {
      path = "/bff/login",
      prefix = false,
      name = "/bff/login",
      methods = { "POST" },
      for_app = true,
      handler = sign_in.login,
   },
   {
      path = "/bff/register",
      prefix = false,
      name = "/bff/register",
      methods = { "POST" },
      for_app = true,
      offered = offers_sign_up,
      handler = sign_up.serve,
   },
   {
      path = "/bff/2fa/verify",
      prefix = false,
      name = "/bff/2fa/verify",
      methods = { "POST" },
      for_app = true,
      handler = sign_in.verify,
   },
   {
      path = "/bff/2fa/setup",
      prefix = false,
      name = "/bff/2fa/setup",
      methods = { "POST" },
      for_app = true,
      handler = sign_in.setup,
   },
   {
      path = "/bff/2fa/enable",
      prefix = false,
      name = "/bff/2fa/enable",
      methods = { "POST" },
      for_app = true,
      handler = sign_in.enable,
   },
   {
      path = "/bff/logout",
      prefix = false,
      name = "/bff/logout",
      methods = { "POST" },
      for_app = true,
      handler = logout.serve,
   },
   {
      path = "/bff/ws/v1/matching/merchant",
      prefix = false,
      name = "/bff/ws/v1/matching/merchant",
      methods = { "GET" },
      for_app = true,
      offered = offers_merchant_socket,
      handler = merchant_socket.serve,
   },
   {
      path = "/bff/ws/v1/matching/merchant/websocket",
      prefix = false,
      name = "/bff/ws/v1/matching/merchant/websocket",
      methods = { "GET" },
      for_app = true,
      offered = offers_merchant_socket,
      handler = merchant_socket.serve,
   },
   {
      path = "/bff/api",
      prefix = true,
      name = "/bff/api/{path}",
      methods = forwarding.methods,
      for_app = true,
      handler = forward.serve,
   },
}

local function matches(route: Route, uri: string): boolean
   if route.prefix then
      return string.sub(uri, 1, #route.path + 1) == route.path .. "/"
   end

   return uri == route.path
end

local function route_for(uri: string): Route
   for _, route in ipairs(router.routes) do
      if matches(route, uri) then
         return route
      end
   end

   return nil
end

local function allows(route: Route, method: string): boolean
   for _, allowed in ipairs(route.methods) do
      if allowed == method then
         return true
      end
   end

   return false
end

local function refused_as_forged(request: RequestContext): boolean
   local refusal = csrf.refusal(
      request.method,
      context.single(request.headers, "origin"),
      context.single(request.headers, "sec-fetch-site"),
      request.app.origin
   )
   if refusal == nil and csrf.changes_state(request.method) and json_body.is_present(request) then
      if not csrf.is_json(context.single(request.headers, "content-type")) then
         metrics.csrf_refused(request.app.name, "content_type")
         respond.error("JSON_REQUIRED", request.request_id, nil)
         return true
      end
   end

   if refusal == nil then
      return false
   end

   metrics.csrf_refused(request.app.name, refusal)
   logger.info("csrf_refused", { reason = refusal, app = request.app.name, request_id = request.request_id })
   respond.error("CSRF_REFUSED", request.request_id, nil)

   return true
end

local function handle(route: Route, request: RequestContext)
   local ran, failure = pcall(function(): string
      route.handler(request)
      return nil
   end)
   if ran then
      return
   end

   logger.error("unhandled_error", { route = route.name, cause = tostring(failure), request_id = request.request_id })
   if not ngx.headers_sent then
      respond.error("INTERNAL_ERROR", request.request_id, nil)
   end
end

function router.serve()
   local headers = ngx.req.get_headers(100, false)
   local request_id = context.request_id(headers)
   ngx.var.edge_request_id = request_id

   local route = route_for(ngx.var.uri)
   if route == nil then
      return respond.error("NOT_FOUND", request_id, nil)
   end

   ngx.var.edge_route = route.name

   if not allows(route, ngx.req.get_method()) then
      return respond.method_not_allowed(table.concat(route.methods, ", "), request_id)
   end

   local request, refusal = context.build(headers, request_id, route.for_app)
   if request == nil then
      return respond.error(refusal, request_id, nil)
   end

   if route.for_app then
      ngx.var.edge_app = request.app.name
      if route.offered ~= nil and not route.offered(request.app) then
         return respond.error("NOT_FOUND", request_id, nil)
      end

      if refused_as_forged(request) then
         return
      end
   end

   handle(route, request)
end

return router
