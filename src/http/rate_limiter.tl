local cjson = require("cjson.safe")
local clock = require("adapters.clock")
local digest = require("adapters.digest")
local json_body = require("http.json_body")
local rate_limit_store = require("adapters.rate_limit_store")
local rate_limits = require("config.rate_limits")
local type ApiRouteRule = require("types.api_route_rule")
local type Environment = require("types.environment")
local type PrincipalClaims = require("types.principal_claims")
local type RateLimitResult = require("types.rate_limit_result")
local type RateLimitRule = require("types.rate_limit_rule")
local type RequestContext = require("types.request_context")

local record rate_limiter
   type ConsumeFn = function(Environment, string, integer, integer, integer): boolean, boolean, integer
end

local EMAIL_LONGEST = 254

local function trimmed(value: string): string
   return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function extract_email(body: string): string
   if body == nil or body == "" then
      return nil
   end

   local decoded = cjson.decode(body)
   if not (decoded is cjson.Document) then
      return nil
   end

   local email = json_body.text(decoded, "email", EMAIL_LONGEST)
   if email == nil then
      return nil
   end

   local clean = string.lower(trimmed(email))
   if clean == "" then
      return nil
   end

   return clean
end

local function bucket_key(
   rule: RateLimitRule,
   request: RequestContext,
   claims: PrincipalClaims,
   body: string
): string
   if rule.key_scope == "ip" then
      return "edge:rl:" .. rule.name .. ":ip:" .. digest.sha256_hex(request.client_address)
   end

   if rule.key_scope == "principal" then
      if claims ~= nil and claims.sub ~= nil and claims.sub ~= "" then
         return "edge:rl:" .. rule.name .. ":sub:" .. digest.sha256_hex(claims.sub)
      end

      return "edge:rl:" .. rule.name .. ":ip:" .. digest.sha256_hex(request.client_address)
   end

   if rule.key_scope == "email" then
      local email = extract_email(body)
      if email == nil then
         return nil
      end

      return "edge:rl:" .. rule.name .. ":email:" .. digest.sha256_hex(email)
   end

   return nil
end

function rate_limiter.evaluate_with(
   consume: rate_limiter.ConsumeFn,
   now_ms: integer,
   environment: Environment,
   route_rule: ApiRouteRule,
   request: RequestContext,
   claims: PrincipalClaims,
   body: string
): RateLimitResult
   local rules = rate_limits.for_group(route_rule.rate_limit_group)
   if #rules == 0 then
      return { ok = true, unavailable = false }
   end

   for _, rl_rule in ipairs(rules) do
      local key = bucket_key(rl_rule, request, claims, body)
      if key ~= nil then
         local allowed, unavailable = consume(
            environment,
            key,
            rl_rule.max_requests,
            rl_rule.window_ms,
            now_ms
         )
         if unavailable then
            return {
               ok = false,
               unavailable = true,
               reason = "store_unavailable",
               error_code = "SESSION_STORE_UNAVAILABLE",
            }
         end

         if not allowed then
            local seconds = math.max(1, math.ceil(rl_rule.window_ms / 1000))
            return {
               ok = false,
               unavailable = false,
               reason = rl_rule.name,
               error_code = "TOO_MANY_REQUESTS",
               retry_after = tostring(seconds),
            }
         end
      end
   end

   return { ok = true, unavailable = false, reason = "allowed" }
end

function rate_limiter.evaluate(
   environment: Environment,
   route_rule: ApiRouteRule,
   request: RequestContext,
   claims: PrincipalClaims,
   body: string
): RateLimitResult
   return rate_limiter.evaluate_with(
      rate_limit_store.consume,
      clock.now_ms(),
      environment,
      route_rule,
      request,
      claims,
      body
   )
end

return rate_limiter
