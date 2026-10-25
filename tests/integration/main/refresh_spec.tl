local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local type Answer = require("tests.support.types.answer")

local function bearer_seen(answer: Answer): string
   local decoded = cjson.decode(answer.body)
   if not decoded is cjson.Document then
      return nil
   end

   local headers = decoded["headers"] as {string: string}

   return headers ~= nil and headers["authorization"] or nil
end

local function short_lived_session(): string
   fake.configure({ access_expires_in = 30 })
   local value = flows.session_cookie("seller-web", "seller@example.test")
   fake.configure({ access_expires_in = 900 })

   return value
end

local function api(value: string): Answer
   return client.edge("GET", "/bff/api/v1/orders", { cookie = flows.session(value) })
end

describe("refresh", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("renews through identity when under 60 seconds are left, and only then", function()
      local value = short_lived_session()
      local first_refresh = fake.issued("refresh")

      local answer = api(value)
      check.equal(answer.status, 200, "status")
      check.equal(fake.count("refresh"), 1, "one refresh")
      check.equal(bearer_seen(answer), "Bearer " .. fake.issued("access"), "the new access token went upstream")

      local fields = redis_admin.hash("edge:session:" .. digest.sha256_hex(value))
      check.equal(fields["refresh_token"], fake.issued("refresh"), "the rotated refresh token is kept")
      check.differ(fields["refresh_token"], first_refresh, "rotated")
      check.equal(fake.headers("refresh")["x-kinetix-client"], "seller-web", "client name")

      check.equal(api(value).status, 200, "a fresh token")
      check.equal(fake.count("refresh"), 1, "no second refresh")
   end)

   it("refreshes once for many concurrent requests, so the rotation is never seen as reuse", function()
      local value = short_lived_session()
      fake.configure({ refresh_delay_ms = 400 })

      local threads: {ngx.Thread} = {}
      for _ = 1, 8 do
         table.insert(threads, ngx.thread.spawn(function(): string
            local answer = api(value)

            return string.format("%d", answer.status) .. " " .. (bearer_seen(answer) or "none")
         end))
      end

      local expected = "200 Bearer "
      local outcomes: {string} = {}
      for _, thread in ipairs(threads) do
         local _, outcome = ngx.thread.wait(thread)
         table.insert(outcomes, outcome)
      end

      check.equal(fake.count("refresh"), 1, "exactly one refresh")
      check.equal(fake.count("reuse"), 0, "no reuse")
      for index, outcome in ipairs(outcomes) do
         check.equal(outcome, expected .. fake.issued("access"), "request " .. string.format("%d", index))
      end
   end)

   it("ends the session when identity refuses the refresh", function()
      local value = short_lived_session()
      fake.configure({ refresh_mode = "refuse" })

      local answer = api(value)
      check.equal(answer.status, 401, "status")
      check.equal(client.text(answer, "error"), "SESSION_ENDED", "code")
      check.equal(
         answer.set_cookies[1],
         "__Host-kx_session=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0",
         "cookie expired"
      )
      check.equal(#redis_admin.keys("edge:session:*"), 0, "session deleted")
   end)

   it("keeps the session and answers 503 while identity cannot be reached", function()
      local value = short_lived_session()

      for _, mode in ipairs({ "unavailable", "close", "unknown_client" }) do
         fake.configure({ refresh_mode = mode })
         local answer = api(value)
         check.equal(answer.status, 503, mode)
         check.equal(client.text(answer, "error"), "IDENTITY_UNAVAILABLE", mode .. " code")
         check.equal(#answer.set_cookies, 0, mode .. " keeps the cookie")

         local state = client.edge("GET", "/bff/session", { cookie = flows.session(value) })
         check.equal(client.flag(state, "authenticated"), true, mode .. " keeps the session")
      end

      fake.configure({ refresh_mode = "ok" })
      check.equal(api(value).status, 200, "renewed once identity is back")
   end)

   it("ends the session and logs out at identity when the refreshed role is not the application's", function()
      local value = short_lived_session()
      fake.configure({ roles = { ["seller@example.test"] = "courier" } })

      local answer = api(value)
      check.equal(answer.status, 403, "status")
      check.equal(client.text(answer, "error"), "ROLE_REFUSED", "code")
      check.equal(#redis_admin.keys("edge:session:*"), 0, "session deleted")
      check.equal(fake.count("logout"), 1, "logged out at identity")
      check.truthy(fake.revoked(fake.issued("refresh")), "the family ended")
   end)
end)
