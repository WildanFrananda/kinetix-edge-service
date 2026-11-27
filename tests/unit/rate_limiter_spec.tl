local check = require("tests.support.check")
local digest = require("adapters.digest")
local rate_limiter = require("http.rate_limiter")
local type ApiRouteRule = require("types.api_route_rule")
local type Environment = require("types.environment")
local type PrincipalClaims = require("types.principal_claims")
local type RequestContext = require("types.request_context")

local LOGIN_RULE: ApiRouteRule = {
   name = "/api/v1/auth/login",
   prefix = "/api/v1/auth/login",
   exact = true,
   methods = { "POST" },
   target = "identity",
   max_body_bytes = 16384,
   require_json = true,
   require_idempotency = false,
   strip_client_header = false,
   require_auth = false,
   rate_limit_group = "auth_login",
}

local CHECKOUT_RULE: ApiRouteRule = {
   name = "/api/v1/orders/checkout",
   prefix = "/api/v1/orders/checkout",
   exact = true,
   methods = { "POST" },
   target = "api",
   max_body_bytes = 65536,
   require_json = true,
   require_idempotency = true,
   strip_client_header = true,
   require_auth = true,
   rate_limit_group = "checkout",
}

local REQUEST: RequestContext = {
   request_id = "req-1",
   client_address = "198.51.100.77",
   method = "POST",
   headers = {},
}

local CLAIMS: PrincipalClaims = {
   has_bearer = true,
   valid_shape = true,
   sub = "prn_buyer_42",
   role = "customer",
   token_use = "access",
   audience_ok = true,
   principal_class = "buyer",
}

local ENV: Environment = {}

describe("rate_limiter", function()
   it("hashes IP, normalized email, and sub before calling Redis", function()
      local seen: {string} = {}
      local function allow(
         _: Environment,
         key: string,
         _max: integer,
         _win: integer,
         _now: integer
      ): boolean, boolean, integer
         table.insert(seen, key)
         return true, false, 1
      end

      local login_res = rate_limiter.evaluate_with(
         allow,
         1000,
         ENV,
         LOGIN_RULE,
         REQUEST,
         nil,
         '{"email":"  Alice@Example.COM "}'
      )
      check.truthy(login_res.ok, "login allowed")
      check.equal(#seen, 2, "ip and email buckets checked")
      check.equal(
         seen[1],
         "edge:rl:auth_login_ip:ip:" .. digest.sha256_hex("198.51.100.77"),
         "hashed ip key"
      )
      check.equal(
         seen[2],
         "edge:rl:auth_login_email:email:" .. digest.sha256_hex("alice@example.com"),
         "hashed email key"
      )
      check.excludes(seen[1], "198.51.100.77", "no raw ip in key")
      check.excludes(seen[2], "alice", "no raw email in key")

      seen = {}
      local checkout_res = rate_limiter.evaluate_with(allow, 1000, ENV, CHECKOUT_RULE, REQUEST, CLAIMS, "{}")
      check.truthy(checkout_res.ok, "checkout allowed")
      check.equal(#seen, 1, "principal bucket checked")
      check.equal(
         seen[1],
         "edge:rl:checkout_principal:sub:" .. digest.sha256_hex("prn_buyer_42"),
         "hashed sub key"
      )
      check.excludes(seen[1], "prn_buyer_42", "no raw sub in key")
   end)

   it("refuses with 429 Retry-After when over limit and fails closed when Redis is unavailable", function()
      local function deny(
         _: Environment,
         _key: string,
         _max: integer,
         _win: integer,
         _now: integer
      ): boolean, boolean, integer
         return false, false, 99
      end
      local limited = rate_limiter.evaluate_with(deny, 1000, ENV, CHECKOUT_RULE, REQUEST, CLAIMS, "{}")
      check.falsy(limited.ok, "over limit refused")
      check.equal(limited.error_code, "TOO_MANY_REQUESTS", "429 code")
      check.equal(limited.retry_after, "60", "retry after seconds")

      local function broken(
         _: Environment,
         _key: string,
         _max: integer,
         _win: integer,
         _now: integer
      ): boolean, boolean, integer
         return false, true, 0
      end
      local down = rate_limiter.evaluate_with(broken, 1000, ENV, CHECKOUT_RULE, REQUEST, CLAIMS, "{}")
      check.falsy(down.ok, "store failure refused")
      check.truthy(down.unavailable, "marked unavailable")
      check.equal(down.error_code, "SESSION_STORE_UNAVAILABLE", "503 fail-closed")
   end)
end)
