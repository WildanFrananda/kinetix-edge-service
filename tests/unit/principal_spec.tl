local cjson = require("cjson.safe")
local check = require("tests.support.check")
local principal = require("http.principal")

local function encode_b64url(text: string): string
   local encoded = ngx.encode_base64(text, true)
   return (string.gsub(string.gsub(encoded, "+", "-"), "/", "_"))
end

local function jwt_with_role(role: string): string
   local header = encode_b64url('{"alg":"RS256","typ":"JWT"}')
   local encoded_payload = cjson.encode({ sub = "prn_1", role = role })
   local payload = encode_b64url(encoded_payload)
   return header .. "." .. payload .. ".sig"
end

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
end)
