local check = require("tests.support.check")
local client = require("tests.support.client")
local clock = require("adapters.clock")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")

local function revocations(outcome: string): number
   local text = client.call(scenario.metrics_url, "GET", "/metrics", {}, nil).body
   local name = "kinetix_edge_session_revocations_total{app=\"seller-web\",outcome=\"" .. outcome .. "\"}"
   for line in string.gmatch(text, "[^\n]+") do
      if string.sub(line, 1, #name + 1) == name .. " " then
         return tonumber(string.sub(line, #name + 2))
      end
   end

   return nil
end

describe("the tokens of a session the edge ends without a logout", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("are logged out at identity when a new sign-in replaces the session, off the sign-in's path", function()
      local first = flows.session_cookie("seller-web", "seller@example.test")
      local first_access = fake.issued("access")
      local first_refresh = fake.issued("refresh")
      local before = revocations("revoked") or 0

      local second = flows.login("seller-web", "seller@example.test", flows.session(first))
      check.equal(second.status, 200, "second sign-in")
      flows.eventually(function(): boolean
         return fake.revoked(first_refresh)
      end, "the replaced session's family ended at identity")
      check.equal(fake.headers("logout")["authorization"], "Bearer " .. first_access, "with its own access token")
      check.equal(fake.count("refresh"), 0, "a fresh token needs no refresh first")
      flows.eventually(function(): boolean
         return (revocations("revoked") or 0) >= before + 1
      end, "counted")
   end)

   it("are refreshed first when the access token is stale, so identity takes the logout", function()
      fake.configure({ access_expires_in = 30 })
      local first = flows.session_cookie("seller-web", "seller@example.test")
      local first_refresh = fake.issued("refresh")
      fake.configure({ access_expires_in = 900 })

      check.equal(flows.login("seller-web", "seller@example.test", flows.session(first)).status, 200, "sign-in")
      flows.eventually(function(): boolean
         return fake.revoked(first_refresh)
      end, "the stale session's family ended at identity")
      check.equal(fake.count("refresh"), 1, "one refresh, for a token identity's logout accepts")
   end)

   it("never let a failed logout refuse the new sign-in, and count the failure", function()
      local first = flows.session_cookie("seller-web", "seller@example.test")
      local first_refresh = fake.issued("refresh")
      local before = revocations("failed") or 0
      fake.configure({ logout_mode = "close" })

      local second = flows.login("seller-web", "seller@example.test", flows.session(first))
      check.equal(second.status, 200, "the sign-in stands")
      flows.eventually(function(): boolean
         return (revocations("failed") or 0) >= before + 1
      end, "the failure is counted")
      check.falsy(fake.revoked(first_refresh), "identity could not take it")

      local cookie = flows.session(client.cookie_value(second, "__Host-kx_session"))
      local state = client.edge("GET", "/bff/session", { cookie = cookie })
      check.equal(client.flag(state, "authenticated"), true, "the new session works")
   end)

   it("are logged out at identity when a lookup finds the session past its absolute end", function()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      local refresh = fake.issued("refresh")
      local key = "edge:session:" .. digest.sha256_hex(value)
      redis_admin.set_field(key, "absolute_end", string.format("%d", clock.now_ms() - 1000))

      local answer = client.edge("GET", "/bff/api/v1/orders", { cookie = flows.session(value) })
      check.equal(answer.status, 401, "status")
      check.equal(client.text(answer, "error"), "SESSION_ENDED", "code")
      check.equal(#redis_admin.keys(key), 0, "deleted")
      flows.eventually(function(): boolean
         return fake.revoked(refresh)
      end, "its family ended at identity")
   end)
end)
