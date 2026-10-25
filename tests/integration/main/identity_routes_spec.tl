local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local type Answer = require("tests.support.types.answer")

local function me(cookie: string, browser: string, request_id: string): Answer
   return client.edge(
      "GET",
      "/bff/api/v1/auth/me",
      { cookie = cookie, forwarded_for = "10.0.0.9, " .. browser, request_id = request_id }
   )
end

describe("identity's own routes", function()
   local cookie: string = nil

   before_each(function()
      fake.reset()
      redis_admin.flush()
      cookie = flows.session(flows.session_cookie("seller-web", "seller@example.test"))
   end)

   it("go straight to identity with the browser's address alone, the bearer, request id and client", function()
      local request_id = client.request_id()
      local answer = me(cookie, "203.0.113.60", request_id)
      check.equal(answer.status, 200, "status")
      check.equal(client.text(answer, "principalId"), "prn_fake_101", "identity answered")
      check.equal(#answer.set_cookies, 0, "identity's Set-Cookie dropped")
      check.equal(client.header(answer, "Cache-Control"), "no-store", "no-store")

      local headers = fake.headers("me")
      check.equal(headers["x-forwarded-for"], "203.0.113.60", "one entry: the browser's")
      check.equal(headers["authorization"], "Bearer " .. fake.issued("access"), "the session's bearer")
      check.equal(headers["x-request-id"], request_id, "request id")
      check.equal(headers["x-kinetix-client"], "seller-web", "client name")
      check.absent(headers["cookie"], "no cookie")
   end)

   it("give each browser its own bucket in identity's per-address throttle", function()
      for attempt = 1, 3 do
         check.equal(me(cookie, "203.0.113.61", nil).status, 200, "browser A, call " .. string.format("%d", attempt))
      end

      local limited = me(cookie, "203.0.113.61", nil)
      check.equal(limited.status, 429, "browser A is limited")
      check.equal(client.header(limited, "Retry-After"), "60", "identity's Retry-After passes")

      check.equal(me(cookie, "203.0.113.62", nil).status, 200, "browser B is not")
   end)

   it("include couriers, while everything else goes through the gateway", function()
      local couriers = client.edge("GET", "/bff/api/v1/couriers/applications", { cookie = cookie })
      check.equal(couriers.status, 200, "couriers")
      check.equal(fake.count("couriers"), 1, "identity served it")

      local sellers = client.edge("GET", "/bff/api/v1/sellers/101/application", { cookie = cookie })
      check.equal(sellers.status, 200, "sellers")
      check.equal(client.text(sellers, "path"), "/api/v1/sellers/101/application", "the gateway served it")

      local decoded = cjson.decode(sellers.body)
      check.truthy(decoded is cjson.Document, "the gateway's echo")
   end)
end)
