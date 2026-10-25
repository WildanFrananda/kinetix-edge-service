local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")

describe("the role gate", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("refuses a seller on the backoffice and logs the tokens out at identity", function()
      local answer = flows.login("backoffice", "seller@example.test", nil)
      check.equal(answer.status, 403, "status")
      check.equal(client.text(answer, "error"), "ROLE_REFUSED", "code")
      check.absent(client.set_cookie(answer, "__Host-kx_session"), "no session cookie")
      check.equal(#redis_admin.keys("*"), 0, "no session kept")
      check.equal(fake.count("logout"), 1, "logged out at identity")
      check.equal(fake.headers("logout")["authorization"], "Bearer " .. fake.issued("access"), "with its access token")
      check.truthy(fake.revoked(fake.issued("refresh")), "the refresh family ended")
   end)

   it("refuses a courier on the seller web", function()
      local answer = flows.login("seller-web", "courier@example.test", nil)
      check.equal(answer.status, 403, "status")
      check.equal(client.text(answer, "error"), "ROLE_REFUSED", "code")
      check.truthy(fake.revoked(fake.issued("refresh")), "logged out at identity")
   end)

   it("refuses an admin who answered the challenge on the seller web", function()
      local pending = client.cookie_value(flows.login("seller-web", "admin-2fa@example.test", nil), "__Host-kx_pending")
      local answer = client.edge(
         "POST",
         "/bff/2fa/verify",
         { cookie = flows.pending(pending), body = client.json({ code = "123456" }) }
      )
      check.equal(answer.status, 403, "status")
      check.equal(client.text(answer, "error"), "ROLE_REFUSED", "code")
      check.equal(
         client.set_cookie(answer, "__Host-kx_pending"),
         "__Host-kx_pending=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0",
         "pending expired"
      )
      check.equal(#redis_admin.keys("*"), 0, "nothing kept")
   end)
end)
