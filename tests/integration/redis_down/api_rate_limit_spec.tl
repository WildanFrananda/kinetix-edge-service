local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")

local function encode_b64url(text: string): string
   local encoded = ngx.encode_base64(text, true)
   return (string.gsub(string.gsub(encoded, "+", "-"), "/", "_"))
end

local function buyer_bearer(): string
   local header = encode_b64url('{"alg":"RS256","typ":"JWT"}')
   local encoded_payload = cjson.encode({
      sub = "prn_down_1",
      role = "customer",
      token_use = "access",
      aud = "kinetix",
   })
   local payload = encode_b64url(encoded_payload)
   return header .. "." .. payload .. ".sig"
end

describe("API rate limiting when Redis cannot be reached", function()
   it("fails closed with 503 SESSION_STORE_UNAVAILABLE instead of waiving limits", function()
      local answer = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["Authorization"] = "Bearer " .. buyer_bearer(),
               ["Idempotency-Key"] = "idem-down-1",
            },
            body = '{"addressId":1}',
         }
      )
      check.equal(answer.status, 503, "fails closed when Redis is unreachable")
      check.equal(client.text(answer, "error"), "SESSION_STORE_UNAVAILABLE", "store unavailable code")
   end)
end)
