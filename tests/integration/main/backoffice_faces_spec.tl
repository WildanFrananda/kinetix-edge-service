local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")

local function login(host: string, origin: string): Answer
   return client.edge("POST", "/bff/login", {
      app = "backoffice",
      host = host,
      origin = origin,
      body = client.json({ email = "admin-2fa@example.test", password = scenario.password }),
   })
end

local function refused(answer: Answer, label: string)
   check.equal(answer.status, 403, label)
   check.equal(client.text(answer, "error"), "CSRF_REFUSED", label .. " code")
end

describe("the backoffice's faces", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("signs in on the onion with its own http origin", function()
      local answer = login(scenario.onion_host, "http://" .. scenario.onion_host)
      check.equal(answer.status, 200, "admitted")
      check.truthy(client.flag(answer, "mfaRequired"), "second factor asked")
      check.present(client.cookie_value(answer, "__Host-kx_pending"), "pending cookie set")
   end)

   it("signs in on the tunnel address with its own https origin", function()
      local answer = login(scenario.tunnel_host, "https://" .. scenario.tunnel_host)
      check.equal(answer.status, 200, "admitted")
      check.truthy(client.flag(answer, "mfaRequired"), "second factor asked")
   end)

   it("checks each face against its own origin, never a sibling's", function()
      refused(login(scenario.onion_host, "https://" .. scenario.onion_host), "https for the onion")
      refused(login(scenario.onion_host, "https://" .. scenario.tunnel_host), "the tunnel's origin on the onion")
      refused(login(scenario.tunnel_host, "http://" .. scenario.onion_host), "the onion's origin on the tunnel")
      refused(login(scenario.tunnel_host, "http://" .. scenario.tunnel_host), "plain http on the tunnel")
      check.equal(fake.count("login"), 0, "identity never asked")
   end)
end)
