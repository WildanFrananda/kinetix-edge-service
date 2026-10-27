local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")

local EXPIRED_SESSION = "__Host-kx_session=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"
local EXPIRED_PENDING = "__Host-kx_pending=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"

describe("logout", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   after_each(function()
      redis_admin.edge_command("+del")
   end)

   it("logs out at identity with the refresh token, deletes the session and expires both cookies", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      local access = fake.issued("access")
      local refresh = fake.issued("refresh")

      local answer = client.edge("POST", "/bff/logout", { cookie = flows.session(value) })
      check.equal(answer.status, 204, "status")
      check.equal(answer.set_cookies[1], EXPIRED_SESSION, "session cookie expired")
      check.equal(answer.set_cookies[2], EXPIRED_PENDING, "pending cookie expired")
      check.equal(fake.count("logout"), 1, "identity asked")
      check.equal(fake.headers("logout")["authorization"], "Bearer " .. access, "with the access token")
      check.equal(fake.issued("logged_out_refresh"), refresh, "and the refresh token in the body")
      check.truthy(fake.revoked(refresh), "the refresh family ended")
      check.equal(#redis_admin.keys("edge:session:*"), 0, "session deleted")

      local after = client.edge("GET", "/bff/api/v1/orders", { cookie = flows.session(value) })
      check.equal(after.status, 401, "the cookie is worthless")
   end)

   it("refreshes first when the access token is about to expire", function()
      fake.configure({ access_expires_in = 30 })
      local value = flows.session_cookie("seller-web", "seller@example.test")
      fake.configure({ access_expires_in = 900 })

      local answer = client.edge("POST", "/bff/logout", { cookie = flows.session(value) })
      check.equal(answer.status, 204, "status")
      check.equal(fake.count("refresh"), 1, "refreshed")
      check.equal(fake.headers("logout")["authorization"], "Bearer " .. fake.issued("access"), "with the new token")
   end)

   it("keeps the session and answers 503 when identity cannot be told", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      fake.configure({ logout_mode = "close" })

      local answer = client.edge("POST", "/bff/logout", { cookie = flows.session(value) })
      check.equal(answer.status, 503, "status")
      check.equal(client.text(answer, "error"), "IDENTITY_UNAVAILABLE", "code")
      check.equal(#answer.set_cookies, 0, "cookie kept")

      local state = client.edge("GET", "/bff/session", { cookie = flows.session(value) })
      check.equal(client.flag(state, "authenticated"), true, "session kept")
   end)

   it("answers 204 and expires both cookies when identity logged out but the session could not be deleted", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      local refresh = fake.issued("refresh")
      redis_admin.edge_command("-del")

      local answer = client.edge("POST", "/bff/logout", { cookie = flows.session(value) })
      redis_admin.edge_command("+del")
      check.equal(answer.status, 204, "status: the tokens are revoked, so the user is signed out")
      check.equal(answer.set_cookies[1], EXPIRED_SESSION, "session cookie expired")
      check.equal(answer.set_cookies[2], EXPIRED_PENDING, "pending cookie expired")
      check.truthy(fake.revoked(refresh), "identity ended the family")
   end)

   it("succeeds without a session, expiring whatever cookies there were", function()
      local answer = client.edge("POST", "/bff/logout", {})
      check.equal(answer.status, 204, "status")
      check.equal(answer.set_cookies[1], EXPIRED_SESSION, "session cookie expired")
      check.equal(fake.count("logout"), 0, "identity not asked")
   end)
end)
