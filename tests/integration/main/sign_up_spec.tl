local check = require("tests.support.check")
local client = require("tests.support.client")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")
local type EdgeRequest = require("tests.support.types.edge_request")

local ATTRIBUTES = "; Path=/; Secure; HttpOnly; SameSite=Strict"
local NEW_PASSWORD = "a-long-enough-password"

local function register(email: string, password: string, request: EdgeRequest): Answer
   local options: EdgeRequest = request or {}
   options.body = options.body or client.json({ email = email, password = password })

   return client.edge("POST", "/bff/register", options)
end

describe("sign-up on the seller web", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("creates the account at identity and starts a session like a sign-in, answering no token", function()
      local request_id = client.request_id()
      local answer = register("new-seller@example.test", NEW_PASSWORD, { request_id = request_id })
      check.equal(answer.status, 201, "status")
      check.equal(client.flag(answer, "authenticated"), true, "authenticated")
      check.equal(client.text(answer, "role"), "customer", "a new account is an applicant")
      check.matches(client.text(answer, "principalId"), "^prn_fake_", "principal")
      check.present(client.text(answer, "expiresAt"), "expires at")
      check.excludes(answer.body, "fake-", "no token in the body")
      check.equal(client.header(answer, "Cache-Control"), "no-store", "no-store")

      local value = client.cookie_value(answer, "__Host-kx_session")
      check.equal(#value, 43, "a session cookie")
      check.equal(
         client.set_cookie(answer, "__Host-kx_session"),
         "__Host-kx_session=" .. value .. ATTRIBUTES .. "; Max-Age=2592000",
         "the seller web's persistent cookie"
      )

      local fields = redis_admin.hash("edge:session:" .. digest.sha256_hex(value))
      check.equal(fields["access_token"], fake.issued("access"), "access token kept")
      check.equal(fields["role"], "customer", "role kept")

      local headers = fake.headers("register")
      check.equal(headers["x-kinetix-client"], "seller-web", "client name")
      check.equal(headers["x-forwarded-for"], scenario.browser_address, "the browser's address only")
      check.equal(headers["x-request-id"], request_id, "request id")
      check.absent(headers["cookie"], "no cookie to identity")

      local state = client.edge("GET", "/bff/session", { cookie = flows.session(value) })
      check.equal(client.text(state, "role"), "customer", "the session reads back")
   end)

   it("is not served on the backoffice", function()
      local answer = register("new-admin@example.test", NEW_PASSWORD, { app = "backoffice" })
      check.equal(answer.status, 404, "status")
      check.equal(client.text(answer, "error"), "NOT_FOUND", "code")
      check.equal(fake.count("register"), 0, "identity was not asked")
   end)

   it("answers 409 EMAIL_TAKEN for an address identity already has", function()
      local answer = register("seller@example.test", NEW_PASSWORD, nil)
      check.equal(answer.status, 409, "status")
      check.equal(client.text(answer, "error"), "EMAIL_TAKEN", "code")
      check.equal(#answer.set_cookies, 0, "no cookie")
      check.equal(#redis_admin.keys("*"), 0, "no session")
   end)

   it("relays identity's validation message as INVALID_REQUEST", function()
      local answer = register("short@example.test", "too-short", nil)
      check.equal(answer.status, 400, "status")
      check.equal(client.text(answer, "error"), "INVALID_REQUEST", "code")
      check.equal(
         client.text(answer, "message"),
         "password must be longer than or equal to 12 characters",
         "identity's own words"
      )
      check.equal(#redis_admin.keys("*"), 0, "no session")
   end)

   it("refuses a body without an email or a password before identity is asked", function()
      local partial = client.edge("POST", "/bff/register", { body = client.json({ email = "x@example.test" }) })
      check.equal(partial.status, 400, "no password")
      check.equal(client.text(partial, "error"), "INVALID_REQUEST", "code")

      local broken = client.edge("POST", "/bff/register", { body = "{not json" })
      check.equal(broken.status, 400, "malformed")
      check.equal(fake.count("register"), 0, "identity was not asked")
   end)

   it("passes identity's throttle through as 429 with its Retry-After", function()
      local answer = register("throttled@example.test", NEW_PASSWORD, nil)
      check.equal(answer.status, 429, "status")
      check.equal(client.text(answer, "error"), "TOO_MANY_REQUESTS", "code")
      check.equal(client.header(answer, "Retry-After"), "60", "retry after")
   end)

   it("answers 503 and keeps nothing when identity cannot be reached", function()
      fake.configure({ register_mode = "close" })
      local closed = register("closed@example.test", NEW_PASSWORD, nil)
      check.equal(closed.status, 503, "connection closed")
      check.equal(client.text(closed, "error"), "IDENTITY_UNAVAILABLE", "code")

      fake.configure({ register_mode = "unavailable" })
      local unavailable = register("down@example.test", NEW_PASSWORD, nil)
      check.equal(unavailable.status, 503, "identity's own 503")
      check.equal(client.text(unavailable, "error"), "IDENTITY_UNAVAILABLE", "code")
      check.equal(#redis_admin.keys("*"), 0, "no session")
   end)

   it("takes the forgery checks of every POST", function()
      local foreign = register("forged@example.test", NEW_PASSWORD, { origin = "https://evil.example" })
      check.equal(foreign.status, 403, "foreign origin")
      check.equal(client.text(foreign, "error"), "CSRF_REFUSED", "code")

      local form = register(
         "form@example.test",
         NEW_PASSWORD,
         { content_type = "application/x-www-form-urlencoded", body = "email=a&password=b" }
      )
      check.equal(form.status, 415, "not JSON")
      check.equal(fake.count("register"), 0, "identity was not asked")
   end)

   it("replaces the session the browser brought, like every sign-in", function()
      local first = flows.session_cookie("seller-web", "seller@example.test")
      local first_refresh = fake.issued("refresh")
      local answer = register("second@example.test", NEW_PASSWORD, { cookie = flows.session(first) })
      check.equal(answer.status, 201, "status")
      check.equal(#redis_admin.keys("edge:session:" .. digest.sha256_hex(first)), 0, "the old session is gone")
      check.differ(client.cookie_value(answer, "__Host-kx_session"), first, "a new id")
      flows.eventually(function(): boolean
         return fake.revoked(first_refresh)
      end, "the old session's family is logged out at identity")
   end)
end)
