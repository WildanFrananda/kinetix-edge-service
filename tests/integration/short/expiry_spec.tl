local check = require("tests.support.check")
local client = require("tests.support.client")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local type Answer = require("tests.support.types.answer")

local function at(started: number, seconds: number)
   ngx.update_time()

   local wait = started + seconds - ngx.now()
   if wait > 0 then
      ngx.sleep(wait)
   end
end

local function session_state(value: string): boolean
   return client.flag(client.edge("GET", "/bff/session", { cookie = flows.session(value) }), "authenticated")
end

local function use(value: string): Answer
   return client.edge("GET", "/bff/api/v1/orders", { cookie = flows.session(value) })
end

describe("lifetimes, with the test configuration's short ones", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("ends an idle session (seller web: 3 s idle)", function()
      ngx.update_time()
      local started = ngx.now()
      local value = flows.session_cookie("seller-web", "seller@example.test")

      at(started, 3.5)
      check.falsy(session_state(value), "idle past 3 s")

      local answer = use(value)
      check.equal(answer.status, 401, "status")
      check.equal(client.text(answer, "error"), "SESSION_ENDED", "code")
   end)

   it("extends the idle limit on use, but a read of the session is not a use (backoffice: 2 s idle)", function()
      ngx.update_time()
      local started = ngx.now()
      local value = flows.admin_session_cookie()
      local cookie = flows.session(value)

      at(started, 1.5)
      check.equal(client.edge("GET", "/bff/api/v1/orders", { app = "backoffice", cookie = cookie }).status, 200, "use")
      at(started, 3.0)
      local alive = client.edge("GET", "/bff/session", { app = "backoffice", cookie = cookie })
      check.equal(client.flag(alive, "authenticated"), true, "alive at 3 s thanks to the use at 1.5 s")

      at(started, 3.8)
      local gone = client.edge("GET", "/bff/session", { app = "backoffice", cookie = cookie })
      check.equal(client.flag(gone, "authenticated"), false, "the read at 3 s did not extend it")
   end)

   it("never extends past the absolute end, however recently it was used (seller web: 5 s)", function()
      ngx.update_time()
      local started = ngx.now()
      local value = flows.session_cookie("seller-web", "seller@example.test")
      local key = "edge:session:" .. digest.sha256_hex(value)

      at(started, 1.5)
      check.equal(use(value).status, 200, "used at 1.5 s")
      at(started, 3.0)
      check.equal(use(value).status, 200, "used at 3 s")
      at(started, 4.2)
      check.equal(use(value).status, 200, "used at 4.2 s")
      check.at_most(redis_admin.pttl(key), 1000, "the TTL stops at the absolute end, not 3 s later")

      at(started, 5.3)
      local answer = use(value)
      check.equal(answer.status, 401, "past the absolute end")
      check.equal(client.text(answer, "error"), "SESSION_ENDED", "code")
   end)

   it("gives the seller web's persistent cookie the absolute lifetime as Max-Age", function()
      local answer = flows.login("seller-web", "seller@example.test", nil)
      check.matches(answer.set_cookies[1], "; Max%-Age=5$", "Max-Age from the policy")
   end)
end)
