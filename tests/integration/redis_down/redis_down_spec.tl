local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")

local ANY_SESSION = flows.session(string.rep("Q", 43))

local function unavailable(answer: Answer, label: string)
   check.equal(answer.status, 503, label)
   check.equal(client.text(answer, "error"), "SESSION_STORE_UNAVAILABLE", label .. " code")
   check.equal(#answer.set_cookies, 0, label .. " sets no cookie")
end

describe("with Redis unreachable", function()
   before_each(function()
      fake.reset()
   end)

   it("stays live but not ready", function()
      check.equal(client.call(scenario.edge_url, "GET", "/health", {}, nil).status, 200, "live")
      unavailable(client.call(scenario.edge_url, "GET", "/health/ready", {}, nil), "ready")
   end)

   it("refuses a sign-in before identity is asked, never falling back", function()
      unavailable(flows.login("seller-web", "seller@example.test", nil), "sign-in")
      check.equal(fake.count("login"), 0, "identity not asked")
   end)

   it("answers 503 for the session, the API and logout, and never says signed out", function()
      unavailable(client.edge("GET", "/bff/session", { cookie = ANY_SESSION }), "session")
      unavailable(client.edge("GET", "/bff/api/v1/orders", { cookie = ANY_SESSION }), "api")
      unavailable(client.edge("POST", "/bff/logout", { cookie = ANY_SESSION }), "logout")
      unavailable(client.edge("POST", "/bff/2fa/verify", { body = client.json({ code = "123456" }) }), "verify")
   end)

   it("still refuses a forged request first", function()
      local answer = client.edge("POST", "/bff/login", { origin = "https://evil.example", body = "{}" })
      check.equal(answer.status, 403, "CSRF before the store")
   end)
end)
