local cjson = require("cjson.safe")
local check = require("tests.support.check")
local principal = require("http.principal")
local type ApiRouteRule = require("types.api_route_rule")

local function encode_b64url(text: string): string
   local encoded = ngx.encode_base64(text, true)
   return (string.gsub(string.gsub(encoded, "+", "-"), "/", "_"))
end

local function jwt_with_claims(claims: {string: string}): string
   local header = encode_b64url('{"alg":"RS256","typ":"JWT"}')
   local encoded_payload = cjson.encode(claims)
   local payload = encode_b64url(encoded_payload)
   return header .. "." .. payload .. ".sig"
end

local function jwt_with_role(role: string): string
   return jwt_with_claims({ sub = "prn_1", role = role })
end

local BUYER_RULE: ApiRouteRule = {
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
   allowed_roles = { "customer", "buyer" },
}

describe("principal", function()
   it("maps verified token roles to bounded metric principal classes", function()
      check.equal(principal.class_from_bearer("Bearer " .. jwt_with_role("customer")), "buyer", "customer -> buyer")
      check.equal(principal.class_from_bearer("Bearer " .. jwt_with_role("buyer")), "buyer", "buyer -> buyer")
      check.equal(principal.class_from_bearer("Bearer " .. jwt_with_role("seller")), "seller", "seller")
      check.equal(principal.class_from_bearer("Bearer " .. jwt_with_role("courier")), "courier", "courier")
      check.equal(principal.class_from_bearer("Bearer " .. jwt_with_role("admin")), "admin", "admin")
   end)

   it("folds absent, malformed, or unknown tokens to anonymous", function()
      check.equal(principal.class_from_bearer(nil), "anonymous", "nil header")
      check.equal(principal.class_from_bearer("Basic abc"), "anonymous", "non-bearer")
      check.equal(principal.class_from_bearer("Bearer not-a-jwt"), "anonymous", "malformed jwt")
      check.equal(principal.class_from_bearer("Bearer " .. jwt_with_role("guest")), "anonymous", "unknown role")
   end)

   it("enforces access token_use, expected audience, and allowed roles on protected routes", function()
      local valid = jwt_with_claims({ sub = "prn_1", role = "customer", token_use = "access", aud = "kinetix" })
      local ok = principal.authorize(principal.inspect("Bearer " .. valid, "kinetix"), BUYER_RULE)
      check.truthy(ok.ok, "valid access token allowed")

      local missing = principal.authorize(principal.inspect(nil, "kinetix"), BUYER_RULE)
      check.falsy(missing.ok, "missing bearer refused")
      check.equal(missing.error_code, "TOKEN_REQUIRED", "missing token -> 401")

      local refresh = jwt_with_claims({ sub = "prn_1", role = "customer", token_use = "refresh", aud = "kinetix" })
      local bad_use = principal.authorize(principal.inspect("Bearer " .. refresh, "kinetix"), BUYER_RULE)
      check.falsy(bad_use.ok, "refresh token refused")
      check.equal(bad_use.reason, "wrong_token_use", "wrong token use")

      local wrong_aud = jwt_with_claims({ sub = "prn_1", role = "customer", token_use = "access", aud = "other" })
      local bad_aud = principal.authorize(principal.inspect("Bearer " .. wrong_aud, "kinetix"), BUYER_RULE)
      check.falsy(bad_aud.ok, "wrong aud refused")
      check.equal(bad_aud.reason, "wrong_audience", "wrong audience")

      local courier = jwt_with_claims({ sub = "prn_2", role = "courier", token_use = "access", aud = "kinetix" })
      local forbidden = principal.authorize(principal.inspect("Bearer " .. courier, "kinetix"), BUYER_RULE)
      check.falsy(forbidden.ok, "disallowed role refused")
      check.equal(forbidden.error_code, "FORBIDDEN", "role refused -> 403")
   end)
end)
