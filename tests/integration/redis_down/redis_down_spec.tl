local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local scenario = require("tests.support.scenario")
local socket = require("tests.support.socket")
local type Answer = require("tests.support.types.answer")

local ANY_SESSION = flows.session(string.rep("Q", 43))
local ANY_PENDING = flows.pending(string.rep("P", 43))

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
      unavailable(
         socket.upgrade(socket.path, { cookie = ANY_SESSION }, scenario.origin("seller-web")),
         "merchant socket"
      )
   end)

   it("refuses a passkey sign-in before identity is asked", function()
      unavailable(
         client.edge("POST", "/bff/2fa/passkey/options", { app = "backoffice", cookie = ANY_PENDING }),
         "passkey options"
      )
      unavailable(
         client.edge(
            "POST",
            "/bff/2fa/passkey/verify",
            { app = "backoffice", cookie = ANY_PENDING, body = client.json({ credential = { id = "Y3JlZA" } }) }
         ),
         "passkey verify"
      )
      check.equal(fake.count("passkey_options"), 0, "identity not asked for options")
      check.equal(fake.count("passkey_verify"), 0, "identity not asked to verify")
   end)

   it("refuses a sign-up before identity is asked", function()
      local answer = client.edge(
         "POST",
         "/bff/register",
         { body = client.json({ email = "new@example.test", password = "a-long-enough-password" }) }
      )
      unavailable(answer, "sign-up")
      check.equal(fake.count("register"), 0, "identity not asked")
   end)

   it("still refuses a forged request first", function()
      local answer = client.edge("POST", "/bff/login", { origin = "https://evil.example", body = "{}" })
      check.equal(answer.status, 403, "CSRF before the store")
   end)
end)
