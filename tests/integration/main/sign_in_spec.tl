local check = require("tests.support.check")
local client = require("tests.support.client")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")

local ATTRIBUTES = "; Path=/; Secure; HttpOnly; SameSite=Strict"

describe("sign-in without a second factor", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("starts a session behind an HttpOnly __Host- cookie and answers no token", function()
      local request_id = client.request_id()
      local answer = client.edge(
         "POST",
         "/bff/login",
         {
            request_id = request_id,
            body = client.json({ email = "seller@example.test", password = scenario.password }),
         }
      )
      check.equal(answer.status, 200, "status")
      check.equal(client.flag(answer, "authenticated"), true, "authenticated")
      check.equal(client.text(answer, "role"), "seller", "role")
      check.equal(client.text(answer, "principalId"), "prn_fake_101", "principal")
      check.matches(client.text(answer, "expiresAt"), "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$", "expires at")
      check.excludes(answer.body, "fake-access", "no access token in the body")
      check.excludes(answer.body, "fake-refresh", "no refresh token in the body")
      check.equal(client.header(answer, "Cache-Control"), "no-store", "no-store")

      check.equal(#answer.set_cookies, 1, "one cookie")
      local value = client.cookie_value(answer, "__Host-kx_session")
      check.matches(value, "^[%w%-_]+$", "base64url")
      check.equal(#value, 43, "32 random bytes")
      check.equal(
         answer.set_cookies[1],
         "__Host-kx_session=" .. value .. ATTRIBUTES .. "; Max-Age=2592000",
         "attributes"
      )

      local headers = fake.headers("login")
      check.equal(headers["x-kinetix-client"], "seller-web", "client name")
      check.equal(headers["x-forwarded-for"], scenario.browser_address, "the browser's address only")
      check.equal(headers["x-request-id"], request_id, "request id")
      check.absent(headers["cookie"], "no cookie to identity")
   end)

   it("keys Redis by the cookie's SHA-256 and keeps the cookie itself nowhere in Redis", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      local key = "edge:session:" .. digest.sha256_hex(value)

      local keys = redis_admin.keys("*")
      check.equal(#keys, 1, "one key")
      check.equal(keys[1], key, "hashed key")

      local fields = redis_admin.hash(key)
      check.equal(fields["access_token"], fake.issued("access"), "access token kept")
      check.equal(fields["refresh_token"], fake.issued("refresh"), "refresh token kept")
      check.equal(fields["app"], "seller-web", "app")
      check.equal(fields["role"], "seller", "role")
      for name, stored in pairs(fields) do
         check.excludes(stored, value, "cookie value in " .. name)
      end

      local ttl = redis_admin.pttl(key)
      check.at_most(ttl, 604800000, "idle limit")
      check.at_least(ttl, 604700000, "a fresh idle limit")
   end)

   it("admits an applicant (customer) on the seller web", function()
      local answer = flows.login("seller-web", "customer@example.test", nil)
      check.equal(answer.status, 200, "status")
      check.equal(client.text(answer, "role"), "customer", "role")
   end)

   it("refuses a wrong password with the one error shape", function()
      local request_id = client.request_id()
      local answer = client.edge(
         "POST",
         "/bff/login",
         { request_id = request_id, body = client.json({ email = "seller@example.test", password = "wrong-password" }) }
      )
      check.equal(answer.status, 401, "status")
      check.equal(client.text(answer, "error"), "SIGN_IN_REFUSED", "code")
      check.equal(client.text(answer, "requestId"), request_id, "request id")
      check.present(client.text(answer, "message"), "message")
      check.equal(#answer.set_cookies, 0, "no cookie")

      local keys = 0
      for _ in pairs(answer.json) do
         keys = keys + 1
      end
      check.equal(keys, 3, "error, message, requestId and nothing else")
   end)

   it("passes identity's SIGN_IN_DELAYED through with Retry-After", function()
      local answer = flows.login("seller-web", "delayed@example.test", nil)
      check.equal(answer.status, 429, "status")
      check.equal(client.text(answer, "error"), "SIGN_IN_DELAYED", "code")
      check.equal(client.header(answer, "Retry-After"), "7", "retry after")
   end)

   it("refuses a body that is not the sign-in's", function()
      local broken = client.edge("POST", "/bff/login", { body = "{not json" })
      check.equal(broken.status, 400, "malformed")
      check.equal(client.text(broken, "error"), "INVALID_REQUEST", "code")

      local partial = client.edge("POST", "/bff/login", { body = client.json({ email = "seller@example.test" }) })
      check.equal(partial.status, 400, "no password")
      check.equal(fake.count("login"), 0, "identity was not asked")
   end)

   it("answers 503 and keeps nothing when identity cannot be reached", function()
      fake.configure({ login_mode = "close" })
      local closed = flows.login("seller-web", "seller@example.test", nil)
      check.equal(closed.status, 503, "connection closed")
      check.equal(client.text(closed, "error"), "IDENTITY_UNAVAILABLE", "code")

      fake.configure({ login_mode = "unavailable" })
      local unavailable = flows.login("seller-web", "seller@example.test", nil)
      check.equal(unavailable.status, 503, "identity's own 503")
      check.equal(client.text(unavailable, "error"), "IDENTITY_UNAVAILABLE", "code")
      check.equal(#redis_admin.keys("*"), 0, "no session")
   end)

   it("answers the session's state without a token", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")

      local signed_in = client.edge("GET", "/bff/session", { cookie = flows.session(value) })
      check.equal(signed_in.status, 200, "status")
      check.equal(client.flag(signed_in, "authenticated"), true, "authenticated")
      check.equal(client.text(signed_in, "role"), "seller", "role")
      check.equal(client.text(signed_in, "principalId"), "prn_fake_101", "principal")
      check.present(client.text(signed_in, "expiresAt"), "expires at")
      check.excludes(signed_in.body, "fake-", "no token")

      local anonymous = client.edge("GET", "/bff/session", {})
      check.equal(anonymous.status, 200, "anonymous status")
      check.equal(client.flag(anonymous, "authenticated"), false, "not authenticated")
      check.equal(#anonymous.set_cookies, 0, "nothing to expire")

      local stale = client.edge("GET", "/bff/session", { cookie = flows.session(string.rep("A", 43)) })
      check.equal(client.flag(stale, "authenticated"), false, "unknown cookie")
      check.equal(stale.set_cookies[1], "__Host-kx_session=" .. ATTRIBUTES .. "; Max-Age=0", "expired")
   end)

   it("reads a session cookie sent twice as no session, so a planted copy cannot shadow the real one", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      local twice = flows.session(string.rep("D", 43)) .. "; " .. flows.session(value)

      local answer = client.edge("GET", "/bff/session", { cookie = twice })
      check.equal(client.flag(answer, "authenticated"), false, "ambiguous cookie")
   end)

   it("binds a session to its application, so the other host does not honour it", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      local elsewhere = client.edge("GET", "/bff/session", { app = "backoffice", cookie = flows.session(value) })
      check.equal(client.flag(elsewhere, "authenticated"), false, "backoffice ignores it")

      local home = client.edge("GET", "/bff/session", { cookie = flows.session(value) })
      check.equal(client.flag(home, "authenticated"), true, "still valid on its own host")
   end)
end)
