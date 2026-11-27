local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local socket = require("tests.support.socket")

local function encode_b64url(text: string): string
   local encoded = ngx.encode_base64(text, true)
   return (string.gsub(string.gsub(encoded, "+", "-"), "/", "_"))
end

local function buyer_bearer(): string
   local header = encode_b64url('{"alg":"RS256","typ":"JWT"}')
   local encoded_payload = cjson.encode({
      sub = "prn_ks_buyer_1",
      role = "customer",
      token_use = "access",
      aud = "kinetix",
   })
   local payload = encode_b64url(encoded_payload)
   return header .. "." .. payload .. ".sig"
end

describe("X8 kill switches", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("restricts management to backoffice admin sessions with Origin CSRF", function()
      local seller_cookie = flows.session_cookie("seller-web", "seller@example.test")
      local seller_attempt = client.edge(
         "GET",
         "/bff/edge/kill-switches",
         { app = "seller-web", cookie = flows.session(seller_cookie) }
      )
      check.equal(seller_attempt.status, 404, "seller-web cannot access kill switches")

      local anon_attempt = client.edge("GET", "/bff/edge/kill-switches", { app = "backoffice" })
      check.equal(anon_attempt.status, 401, "unauthenticated backoffice request refused")

      local admin_cookie = flows.admin_session_cookie()
      local bad_origin = client.edge(
         "PUT",
         "/bff/edge/kill-switches/checkout",
         {
            app = "backoffice",
            origin = "https://evil.example",
            cookie = flows.session(admin_cookie),
            body = '{"enabled":true}',
         }
      )
      check.equal(bad_origin.status, 403, "foreign origin refused on PUT")
      check.equal(client.text(bad_origin, "error"), "CSRF_REFUSED", "csrf code")

      redis_admin.set_field("edge:session:" .. digest.sha256_hex(admin_cookie), "role", "seller")
      local non_admin = client.edge(
         "GET",
         "/bff/edge/kill-switches",
         { app = "backoffice", cookie = flows.session(admin_cookie) }
      )
      check.equal(non_admin.status, 403, "non-admin backoffice session refused")
      check.equal(client.text(non_admin, "error"), "ROLE_REFUSED", "role refused code")
   end)

   it("toggles switches with TTL/audit and enforces 503 Retry-After + messageKey across routes", function()
      local admin_cookie = flows.admin_session_cookie()

      local initial = client.edge(
         "GET",
         "/bff/edge/kill-switches",
         { app = "backoffice", cookie = flows.session(admin_cookie) }
      )
      check.equal(initial.status, 200, "list switches")
      check.at_least(#(initial.json["features"] as {cjson.Object}), 7, "all switchable features listed")

      local bad_body = client.edge(
         "PUT",
         "/bff/edge/kill-switches/checkout",
         {
            app = "backoffice",
            cookie = flows.session(admin_cookie),
            body = '{"enabled":"yes"}',
         }
      )
      check.equal(bad_body.status, 400, "invalid switch body refused")

      local enabled = client.edge(
         "PUT",
         "/bff/edge/kill-switches/checkout",
         {
            app = "backoffice",
            cookie = flows.session(admin_cookie),
            body = cjson.encode({
               enabled = true,
               messageKey = "MAINTENANCE_PAYMENT_OUTAGE",
               retryAfter = 120,
               ttlSeconds = 300,
               reason = "payment maintenance",
            }),
         }
      )
      check.equal(enabled.status, 200, "checkout switch enabled")
      check.equal(client.flag(enabled, "enabled"), true, "enabled flag true")
      check.equal(client.text(enabled, "messageKey"), "MAINTENANCE_PAYMENT_OUTAGE", "messageKey saved")
      check.excludes(client.text(enabled, "updatedBy"), "admin", "actor hashed in response")

      local key = "edge:kill:checkout"
      local ttl = redis_admin.pttl(key)
      check.at_least(ttl, 1, "kill switch key has positive TTL")
      check.at_most(ttl, 300000, "kill switch TTL bounded")

      local checkout = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["Authorization"] = "Bearer " .. buyer_bearer(),
               ["Idempotency-Key"] = "idem-ks-1",
            },
            body = '{"addressId":1}',
         }
      )
      check.equal(checkout.status, 503, "killed checkout returns 503")
      check.equal(client.text(checkout, "error"), "FEATURE_DISABLED", "feature disabled code")
      check.equal(client.text(checkout, "messageKey"), "MAINTENANCE_PAYMENT_OUTAGE", "messageKey returned")
      check.equal(client.header(checkout, "Retry-After"), "120", "Retry-After header returned")

      local login_on = client.edge(
         "PUT",
         "/bff/edge/kill-switches/login",
         {
            app = "backoffice",
            cookie = flows.session(admin_cookie),
            body = '{"enabled":true,"retryAfter":45}',
         }
      )
      check.equal(login_on.status, 200, "login switch enabled")

      local bff_login = client.edge(
         "POST",
         "/bff/login",
         { body = client.json({ email = "seller@example.test", password = "correct-password" }) }
      )
      check.equal(bff_login.status, 503, "killed BFF login returns 503")
      check.equal(client.header(bff_login, "Retry-After"), "45", "BFF login Retry-After")
      check.equal(fake.count("login"), 1, "identity not called while login switch active")

      local ws_on = client.edge(
         "PUT",
         "/bff/edge/kill-switches/events_ws",
         {
            app = "backoffice",
            cookie = flows.session(admin_cookie),
            body = '{"enabled":true}',
         }
      )
      check.equal(ws_on.status, 200, "events_ws switch enabled")

      local ws_blocked = socket.upgrade(
         "/ws/v1/events",
         { headers = { ["Authorization"] = "Bearer " .. buyer_bearer() } },
         nil
      )
      check.equal(ws_blocked.status, 503, "killed event WebSocket refused with 503")

      local disabled = client.edge(
         "DELETE",
         "/bff/edge/kill-switches/checkout",
         { app = "backoffice", cookie = flows.session(admin_cookie) }
      )
      check.equal(disabled.status, 200, "checkout switch cleared")
      check.equal(client.flag(disabled, "enabled"), false, "enabled flag false")
      check.equal(#redis_admin.keys("edge:kill:checkout"), 0, "redis key deleted")

      local recovered = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["Authorization"] = "Bearer " .. buyer_bearer(),
               ["Idempotency-Key"] = "idem-ks-2",
            },
            body = '{"addressId":1}',
         }
      )
      check.equal(recovered.status, 200, "checkout recovers once switch disabled")
   end)
end)
