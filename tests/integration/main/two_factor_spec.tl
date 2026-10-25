local check = require("tests.support.check")
local client = require("tests.support.client")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")

local ATTRIBUTES = "; Path=/; Secure; HttpOnly; SameSite=Strict"

local function verify(app: string, pending: string, code: string): Answer
   local cookie: string = nil
   if pending ~= nil then
      cookie = flows.pending(pending)
   end

   return client.edge("POST", "/bff/2fa/verify", { app = app, cookie = cookie, body = client.json({ code = code }) })
end

local function enrolment_call(path: string, pending: string, code: string): Answer
   local body = "{}"
   if code ~= nil then
      body = client.json({ code = code })
   end

   return client.edge("POST", path, { app = "backoffice", cookie = flows.pending(pending), body = body })
end

describe("sign-in with a second factor", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("keeps the challenge in Redis behind a pending cookie and answers only mfaRequired", function()
      local answer = flows.login("backoffice", "admin-2fa@example.test", nil)
      check.equal(answer.status, 200, "status")
      check.equal(client.flag(answer, "mfaRequired"), true, "mfa required")
      check.excludes(answer.body, "fake-challenge", "no challenge token in the body")
      check.absent(client.set_cookie(answer, "__Host-kx_session"), "no session yet")

      local pending = client.cookie_value(answer, "__Host-kx_pending")
      check.equal(#pending, 43, "pending value")
      check.equal(answer.set_cookies[1], "__Host-kx_pending=" .. pending .. ATTRIBUTES .. "; Max-Age=300", "attributes")

      local key = "edge:pending:" .. digest.sha256_hex(pending)
      check.equal(redis_admin.hash(key)["token"], fake.issued("challenge"), "challenge kept")
      check.at_most(redis_admin.pttl(key), 300000, "challenge lifetime")
   end)

   it("keeps the pending sign-in through a wrong code, then starts the session on the right one", function()
      local pending = client.cookie_value(flows.login("backoffice", "admin-2fa@example.test", nil), "__Host-kx_pending")

      local wrong = verify("backoffice", pending, "000000")
      check.equal(wrong.status, 401, "wrong code")
      check.equal(client.text(wrong, "error"), "CODE_REFUSED", "code")

      local right = verify("backoffice", pending, scenario.code)
      check.equal(right.status, 200, "right code")
      check.equal(client.text(right, "role"), "admin", "role")

      local session = client.cookie_value(right, "__Host-kx_session")
      check.equal(
         client.set_cookie(right, "__Host-kx_session"),
         "__Host-kx_session=" .. session .. ATTRIBUTES,
         "a browser-session cookie for the backoffice, with no Max-Age"
      )
      check.equal(
         client.set_cookie(right, "__Host-kx_pending"),
         "__Host-kx_pending=" .. ATTRIBUTES .. "; Max-Age=0",
         "pending cookie expired"
      )
      check.equal(#redis_admin.keys("edge:pending:*"), 0, "pending gone")
      check.equal(fake.headers("verify")["x-kinetix-client"], "backoffice", "client name")

      local replay = verify("backoffice", pending, scenario.code)
      check.equal(replay.status, 401, "a spent pending sign-in")
      check.equal(client.text(replay, "error"), "SIGN_IN_REQUIRED", "code")
   end)

   it("asks for a sign-in when there is no pending one", function()
      local answer = verify("backoffice", nil, scenario.code)
      check.equal(answer.status, 401, "status")
      check.equal(client.text(answer, "error"), "SIGN_IN_REQUIRED", "code")
      check.equal(fake.count("verify"), 0, "identity was not asked")
   end)

   it("offers the challenge to sellers who enabled a second factor", function()
      local login = flows.login("seller-web", "seller-2fa@example.test", nil)
      local pending = client.cookie_value(login, "__Host-kx_pending")
      local right = verify("seller-web", pending, scenario.code)
      check.equal(right.status, 200, "status")
      check.equal(client.text(right, "role"), "seller", "role")
   end)

   it("enrols an admin through the restricted session, then asks for a fresh sign-in", function()
      local login = flows.login("backoffice", "admin-new@example.test", nil)
      check.equal(client.flag(login, "mfaEnrolmentRequired"), true, "enrolment required")
      check.excludes(login.body, "fake-enrolment", "no enrolment token in the body")

      local pending = client.cookie_value(login, "__Host-kx_pending")
      check.equal(login.set_cookies[1], "__Host-kx_pending=" .. pending .. ATTRIBUTES .. "; Max-Age=600", "attributes")

      local secret = enrolment_call("/bff/2fa/setup", pending, nil)
      check.equal(secret.status, 200, "setup")
      check.equal(client.text(secret, "twoFactorSecret"), "JBSWY3DPEHPK3PXP", "secret to show")
      check.matches(client.text(secret, "qrCodeUrl"), "^otpauth://", "QR")
      check.equal(client.flag(secret, "enabled"), false, "not yet enabled")
      check.equal(fake.path("setup"), "/api/v1/auth/2fa/setup/106", "the account's own id")
      check.equal(fake.headers("setup")["authorization"], "Bearer " .. fake.issued("enrolment"), "enrolment token")

      local wrong = enrolment_call("/bff/2fa/enable", pending, "000000")
      check.equal(wrong.status, 401, "wrong code")
      check.equal(client.text(wrong, "error"), "CODE_REFUSED", "code")

      local enabled = enrolment_call("/bff/2fa/enable", pending, scenario.code)
      check.equal(enabled.status, 200, "enabled")
      check.equal(client.flag(enabled, "enabled"), true, "enabled flag")
      check.equal(enabled.set_cookies[1], "__Host-kx_pending=" .. ATTRIBUTES .. "; Max-Age=0", "pending expired")
      check.absent(client.set_cookie(enabled, "__Host-kx_session"), "no session from enrolment")
      check.equal(#redis_admin.keys("edge:pending:*"), 0, "pending gone")

      local again = flows.login("backoffice", "admin-new@example.test", nil)
      check.equal(client.flag(again, "mfaRequired"), true, "the next sign-in takes the challenge")
   end)

   it("does not let an enrolment stand in for a challenge", function()
      local pending = client.cookie_value(flows.login("backoffice", "admin-new@example.test", nil), "__Host-kx_pending")
      local answer = verify("backoffice", pending, scenario.code)
      check.equal(answer.status, 401, "status")
      check.equal(client.text(answer, "error"), "SIGN_IN_REQUIRED", "code")
      check.equal(fake.count("verify"), 0, "identity was not asked")
   end)

   it("refuses enrolment on the seller web, which admits no admin", function()
      local answer = flows.login("seller-web", "admin-new@example.test", nil)
      check.equal(answer.status, 403, "status")
      check.equal(client.text(answer, "error"), "ROLE_REFUSED", "code")
      check.equal(#answer.set_cookies, 0, "no cookie")
      check.equal(#redis_admin.keys("*"), 0, "nothing kept")
   end)
end)
