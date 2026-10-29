local api_path = require("http.api_path")
local check = require("tests.support.check")

describe("api_path", function()
   it("maps /bff/api/<rest> onto /api/<rest>", function()
      check.equal(api_path.upstream("/bff/api/v1/orders/OR-1"), "/api/v1/orders/OR-1", "path")
      check.equal(api_path.upstream("/bff/api/v1/orders/"), "/api/v1/orders/", "trailing slash")
   end)

   it("escapes each segment, so a decoded character cannot change the path", function()
      check.equal(api_path.upstream("/bff/api/v1/products/a b?c"), "/api/v1/products/a%20b%3Fc", "escaped")
   end)

   it("refuses paths outside the prefix and dot segments", function()
      check.absent(api_path.upstream("/bff/apix/v1"), "other prefix")
      check.absent(api_path.upstream("/bff/api"), "the bare prefix")
      check.absent(api_path.upstream("/bff/api/v1/../../bff/session"), "dot segments")
   end)

   it("refuses identity's token-issuing routes, whatever their case or suffix", function()
      check.truthy(api_path.is_refused("/api/v1/auth/login"), "login")
      check.truthy(api_path.is_refused("/api/v1/AUTH/Login"), "case")
      check.truthy(api_path.is_refused("/api/v1/auth/refresh/"), "suffix")
      check.truthy(api_path.is_refused("/api/v1/auth/2fa/verify"), "verify")
      check.truthy(api_path.is_refused("/api/v1/auth/2fa/passkey/verify"), "passkey verify")
      check.truthy(api_path.is_refused("/api/v1/auth/2fa/Passkey/Verify/"), "passkey verify, case and suffix")
      check.truthy(api_path.is_refused("/api/v1/couriers/register"), "courier registration")
      check.falsy(api_path.is_refused("/api/v1/auth/me"), "me")
      check.falsy(api_path.is_refused("/api/v1/auth/loginx"), "a longer word")
   end)

   it("forwards passkey management, which issues no token, to identity", function()
      for _, path in ipairs({
         "/api/v1/auth/passkeys/7",
         "/api/v1/auth/passkeys/7/options",
         "/api/v1/auth/passkeys/7/0f6c2d4e-8a1b-4c3d-9e5f-6a7b8c9d0e1f",
      }) do
         check.falsy(api_path.is_refused(path), path .. " is not refused")
         check.truthy(api_path.is_identity(path), path .. " goes to identity")
      end
   end)

   it("sends identity's own routes to identity, and nothing else", function()
      check.truthy(api_path.is_identity("/api/v1/auth/me"), "auth")
      check.truthy(api_path.is_identity("/api/v1/AUTH/2fa/disable/7"), "auth, in capitals")
      check.truthy(api_path.is_identity("/api/v1/couriers/applications"), "couriers")
      check.falsy(api_path.is_identity("/api/v1/authority"), "a longer word")
      check.falsy(api_path.is_identity("/api/v1/sellers/7/application"), "sellers go through the gateway")
      check.falsy(api_path.is_identity("/api/v1/users/7/profile"), "users go through the gateway")
      check.falsy(api_path.is_identity("/api/v1/orders/OR-1"), "orders")
   end)
end)
