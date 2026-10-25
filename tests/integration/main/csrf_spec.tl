local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")
local type EdgeRequest = require("tests.support.types.edge_request")

local function login(request: EdgeRequest): Answer
   request.body = request.body or client.json({ email = "seller@example.test", password = scenario.password })

   return client.edge("POST", "/bff/login", request)
end

local function refused(answer: Answer, label: string)
   check.equal(answer.status, 403, label)
   check.equal(client.text(answer, "error"), "CSRF_REFUSED", label .. " code")
   check.equal(#answer.set_cookies, 0, label .. " sets no cookie")
end

describe("forged requests", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("refuses a foreign Origin before identity is asked", function()
      refused(login({ origin = "https://evil.example" }), "foreign origin")
      refused(login({ origin = "https://evil.example", fetch_site = "same-origin" }), "foreign origin, same-origin")
      refused(login({ origin = scenario.origin("backoffice") }), "the other application")
      refused(login({ origin = "http://seller.localhost:8443" }), "plain http")
      refused(login({ origin = "null" }), "opaque origin")
      check.equal(fake.count("login"), 0, "identity never asked")
   end)

   it("without an Origin, admits only Sec-Fetch-Site: same-origin", function()
      refused(login({ omit_origin = true }), "neither header")
      refused(login({ omit_origin = true, fetch_site = "cross-site" }), "cross-site")
      refused(login({ omit_origin = true, fetch_site = "same-site" }), "same-site")
      refused(login({ omit_origin = true, fetch_site = "none" }), "none")
      check.equal(fake.count("login"), 0, "identity never asked")

      local admitted = login({ omit_origin = true, fetch_site = "same-origin" })
      check.equal(admitted.status, 200, "same-origin admitted")
   end)

   it("admits the application's own Origin", function()
      check.equal(login({}).status, 200, "own origin")
   end)

   it("takes JSON bodies only", function()
      local form = login({ content_type = "application/x-www-form-urlencoded", body = "email=a&password=b" })
      check.equal(form.status, 415, "form")
      check.equal(client.text(form, "error"), "JSON_REQUIRED", "code")

      local text = login({ content_type = "text/plain" })
      check.equal(text.status, 415, "text/plain")
      check.equal(fake.count("login"), 0, "identity never asked")
   end)

   it("guards logout and the API forwarder as well", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      local cookie = flows.session(value)

      refused(client.edge("POST", "/bff/logout", { cookie = cookie, origin = "https://evil.example" }), "logout")
      refused(client.edge("DELETE", "/bff/api/v1/orders/OR-1", { cookie = cookie, omit_origin = true }), "api delete")
      refused(
         client.edge("POST", "/bff/api/v1/orders", { cookie = cookie, origin = "https://evil.example", body = "{}" }),
         "api post"
      )
      check.equal(fake.count("logout"), 0, "identity never asked to log out")

      local still = client.edge("GET", "/bff/session", { cookie = cookie })
      check.equal(client.flag(still, "authenticated"), true, "the session survived")
   end)
end)
