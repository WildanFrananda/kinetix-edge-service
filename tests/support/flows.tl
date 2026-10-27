local check = require("tests.support.check")
local client = require("tests.support.client")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")

local record flows
end

function flows.login(app: string, email: string, cookie: string): Answer
   return client.edge(
      "POST",
      "/bff/login",
      { app = app, cookie = cookie, body = client.json({ email = email, password = scenario.password }) }
   )
end

function flows.session_cookie(app: string, email: string): string
   local answer = flows.login(app, email, nil)
   check.equal(answer.status, 200, "sign-in of " .. email .. " on " .. app)

   local value = client.cookie_value(answer, "__Host-kx_session")
   check.present(value, "session cookie of " .. email)

   return value
end

function flows.cookie(name: string, value: string): string
   return name .. "=" .. value
end

function flows.session(value: string): string
   return flows.cookie("__Host-kx_session", value)
end

function flows.pending(value: string): string
   return flows.cookie("__Host-kx_pending", value)
end

function flows.eventually(holds: function(): boolean, label: string)
   for _ = 1, 150 do
      if holds() then
         return
      end

      ngx.sleep(0.02)
   end

   check.truthy(holds(), label)
end

function flows.admin_session_cookie(): string
   local login = flows.login("backoffice", "admin-2fa@example.test", nil)
   local pending = client.cookie_value(login, "__Host-kx_pending")
   check.present(pending, "pending cookie of the admin")

   local verified = client.edge(
      "POST",
      "/bff/2fa/verify",
      { app = "backoffice", cookie = flows.pending(pending), body = client.json({ code = scenario.code }) }
   )
   check.equal(verified.status, 200, "the admin's challenge")

   return client.cookie_value(verified, "__Host-kx_session")
end

return flows
