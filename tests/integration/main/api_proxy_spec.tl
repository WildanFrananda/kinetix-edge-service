local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")

local function encode_b64url(text: string): string
   local encoded = ngx.encode_base64(text, true)
   return (string.gsub(string.gsub(encoded, "+", "-"), "/", "_"))
end

local function bearer_with(sub: string, role: string, token_use: string, aud: string): string
   local header = encode_b64url('{"alg":"RS256","typ":"JWT"}')
   local encoded_payload = cjson.encode({
      sub = sub,
      role = role,
      token_use = token_use,
      aud = aud,
   })
   local payload = encode_b64url(encoded_payload)
   return header .. "." .. payload .. ".sig"
end

local function bearer_for(role: string): string
   return bearer_with("prn_test_1", role, "access", "kinetix")
end

local function echoed_headers(answer: Answer): {string: string}
   local decoded = cjson.decode(answer.body)
   if not decoded is cjson.Document then
      return {}
   end

   return (decoded["headers"] as {string: string}) or {}
end

local function metric_value(text: string, series: string): number
   for line in string.gmatch(text, "[^\n]+") do
      if string.sub(line, 1, #series + 1) == series .. " " then
         return tonumber(string.sub(line, #series + 2))
      end
   end

   return nil
end

describe("public API proxy, security headers, early checks, and metrics", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("sets security headers and strips Server and X-Powered-By on every response", function()
      local health = client.call(scenario.edge_url, "GET", "/health", {}, nil)
      check.equal(health.status, 200, "health status")
      check.equal(
         client.header(health, "Strict-Transport-Security"),
         "max-age=31536000; includeSubDomains",
         "hsts"
      )
      check.equal(client.header(health, "X-Content-Type-Options"), "nosniff", "nosniff")
      check.equal(client.header(health, "X-Frame-Options"), "DENY", "x-frame-options")
      check.equal(
         client.header(health, "Content-Security-Policy"),
         "default-src 'none'; frame-ancestors 'none'",
         "csp"
      )
      check.equal(client.header(health, "Referrer-Policy"), "no-referrer", "referrer policy")
      check.absent(client.header(health, "Server"), "no Server")
      check.absent(client.header(health, "X-Powered-By"), "no X-Powered-By")

      local api_answer = client.edge(
         "GET",
         "/api/v1/orders/ORD-100",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = { ["Authorization"] = "Bearer " .. bearer_for("customer") },
         }
      )
      check.equal(api_answer.status, 200, "proxied API status")
      check.equal(client.header(api_answer, "X-Content-Type-Options"), "nosniff", "api nosniff")
      check.absent(client.header(api_answer, "X-Powered-By"), "api strips X-Powered-By")
   end)

   it("enforces Idempotency-Key, JSON validity, Content-Type, and route body caps before upstream", function()
      local customer_auth = { ["Authorization"] = "Bearer " .. bearer_for("customer") }
      local no_idem = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = customer_auth,
            body = '{"items":1}',
         }
      )
      check.equal(no_idem.status, 400, "checkout requires idempotency key")
      check.equal(client.text(no_idem, "error"), "IDEMPOTENCY_KEY_REQUIRED", "idempotency code")

      local topup_no_idem = client.edge(
         "POST",
         "/api/v1/payment/wallet/customer/topup",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = customer_auth,
            body = '{"amount":10000}',
         }
      )
      check.equal(topup_no_idem.status, 400, "topup requires idempotency key")
      check.equal(client.text(topup_no_idem, "error"), "IDEMPOTENCY_KEY_REQUIRED", "topup idempotency code")

      local non_json = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            content_type = "text/plain",
            headers = {
               ["Authorization"] = customer_auth["Authorization"],
               ["Idempotency-Key"] = "idem-1",
            },
            body = "hello",
         }
      )
      check.equal(non_json.status, 415, "non-json refused")
      check.equal(client.text(non_json, "error"), "JSON_REQUIRED", "json required code")

      local bad_json = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["Authorization"] = customer_auth["Authorization"],
               ["Idempotency-Key"] = "idem-2",
            },
            body = "{not-json",
         }
      )
      check.equal(bad_json.status, 400, "malformed json refused")
      check.equal(client.text(bad_json, "error"), "INVALID_REQUEST", "invalid request code")

      local too_big = client.edge(
         "POST",
         "/api/v1/payment/wallet/customer/topup",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["Authorization"] = customer_auth["Authorization"],
               ["Idempotency-Key"] = "idem-3",
            },
            body = '{"pad":"' .. string.rep("x", 17000) .. '"}',
         }
      )
      check.equal(too_big.status, 413, "route max_body_bytes enforced")
      check.equal(client.text(too_big, "error"), "PAYLOAD_TOO_LARGE", "payload too large code")

      local wrong_method = client.edge(
         "GET",
         "/api/v1/orders/checkout",
         { host = "api.localhost:8443", omit_origin = true }
      )
      check.equal(wrong_method.status, 405, "method not allowed")
      check.equal(client.header(wrong_method, "Allow"), "POST", "allow header")

      local untrusted_webhook = client.edge(
         "POST",
         "/api/v1/payment/gateway/midtrans/notifications",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            forwarded_for = "10.0.0.2, 198.51.100.77",
            body = '{"order_id":"ORD-1"}',
         }
      )
      check.equal(untrusted_webhook.status, 403, "untrusted IP refused on midtrans webhook")
      check.equal(client.text(untrusted_webhook, "error"), "WEBHOOK_FORBIDDEN", "webhook forbidden code")

      local sandbox_webhook = client.edge(
         "POST",
         "/api/v1/payment/gateway/midtrans/notifications",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            forwarded_for = "10.0.0.2, 34.101.68.130",
            body = '{"order_id":"ORD-1"}',
         }
      )
      check.equal(sandbox_webhook.status, 200, "midtrans sandbox IP admitted without idempotency key")

      local prod_webhook = client.edge(
         "POST",
         "/api/v1/payment/gateway/midtrans/notifications",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            forwarded_for = "10.0.0.2, 103.208.23.6",
            body = '{"order_id":"ORD-2"}',
         }
      )
      check.equal(prod_webhook.status, 200, "midtrans production CIDR admitted")
   end)

   it("sanitizes incoming X-Kinetix-* hints, routes identity directly, and records X18 metrics", function()
      local token = bearer_for("customer")
      local request_id = client.request_id()
      local checkout = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            request_id = request_id,
            forwarded_for = "10.0.0.2, 198.51.100.77",
            headers = {
               ["Authorization"] = "Bearer " .. token,
               ["Idempotency-Key"] = "idem-ok-1",
               ["X-Kinetix-Client"] = "mobile-buyer",
               ["X-Kinetix-Origin"] = "https://forged.example",
               ["X-Kinetix-Locale"] = "id",
               ["X-Kinetix-App-Version"] = "9.9.9",
               ["X-Kinetix-Experiment"] = "canary",
               ["X-User-Id"] = "42",
               ["Cookie"] = "session=evil",
            },
            body = '{"addressId":1}',
         }
      )
      check.equal(checkout.status, 200, "valid checkout forwarded")
      local headers = echoed_headers(checkout)
      check.equal(headers["authorization"], "Bearer " .. token, "bearer forwarded")
      check.equal(headers["idempotency-key"], "idem-ok-1", "idempotency key forwarded")
      check.equal(headers["x-request-id"], request_id, "request id forwarded")
      check.equal(headers["x-forwarded-for"], "198.51.100.77", "last client ip forwarded")
      check.absent(headers["x-kinetix-client"], "client stripped on non-identity route")
      check.absent(headers["x-kinetix-origin"], "origin hint stripped")
      check.absent(headers["x-kinetix-locale"], "locale hint stripped")
      check.absent(headers["x-kinetix-app-version"], "app version hint stripped")
      check.absent(headers["x-kinetix-experiment"], "experiment hint stripped")
      check.absent(headers["x-user-id"], "user id hint stripped")
      check.absent(headers["cookie"], "cookie stripped")

      local login = client.edge(
         "POST",
         "/api/v1/auth/login",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["X-Kinetix-Client"] = "seller-web",
               ["X-Kinetix-Origin"] = "https://forged.example",
               ["X-Kinetix-Locale"] = "id",
            },
            body = '{"email":"seller@example.test","password":"correct-password"}',
         }
      )
      check.equal(login.status, 200, "identity route reached directly")
      check.present(client.text(login, "accessToken"), "identity issued token")
      local id_headers = fake.headers("login")
      check.equal(id_headers["x-kinetix-client"], "seller-web", "client header forwarded to identity")
      check.absent(id_headers["x-kinetix-origin"], "origin hint stripped before identity")
      check.absent(id_headers["x-kinetix-locale"], "locale hint stripped before identity")

      local scrape = client.call(scenario.metrics_url, "GET", "/metrics", {}, nil).body
      check.at_least(
         metric_value(
            scrape,
            'kinetix_edge_api_requests_total{route="/api/v1/orders/checkout",principal_class="buyer",status="200"}'
         ),
         1,
         "api request counted by route and principal_class"
      )
      check.at_least(
         metric_value(
            scrape,
            'kinetix_edge_api_request_duration_seconds_count{route="/api/v1/orders/checkout",principal_class="buyer"}'
         ),
         1,
         "api duration recorded"
      )
      check.at_least(
         metric_value(scrape, 'kinetix_edge_decisions_total{rule="early_check",outcome="allowed"}'),
         1,
         "early check allowed counted"
      )
      check.excludes(scrape, "ORD-100", "no raw order id in metrics")
      check.excludes(scrape, "prn_test_1", "no principal id in metrics")
   end)

   it("enforces X6 mobile app minimum versions and forwards validated version headers", function()
      local outdated = client.edge(
         "POST",
         "/api/v1/auth/login",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["X-Kinetix-Client"] = "courier-app",
               ["X-Kinetix-App-Version"] = "0.9.5",
            },
            body = '{"email":"courier@example.test","password":"correct-password"}',
         }
      )
      check.equal(outdated.status, 426, "outdated mobile app refused")
      check.equal(client.text(outdated, "error"), "UPGRADE_REQUIRED", "upgrade required code")
      check.equal(client.text(outdated, "minimumVersion"), "1.0.0", "minimumVersion returned")
      check.matches(client.text(outdated, "storeUrl"), "^https://play%.google%.com/", "storeUrl returned")

      local malformed = client.edge(
         "POST",
         "/api/v1/auth/login",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["X-Kinetix-Client"] = "courier-app",
               ["X-Kinetix-App-Version"] = "invalid-ver",
            },
            body = '{"email":"courier@example.test","password":"correct-password"}',
         }
      )
      check.equal(malformed.status, 400, "malformed version refused")
      check.equal(client.text(malformed, "error"), "INVALID_REQUEST", "malformed code")

      local valid = client.edge(
         "POST",
         "/api/v1/auth/login",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["X-Kinetix-Client"] = "courier-app",
               ["X-Kinetix-App-Version"] = "1.0.0",
            },
            body = '{"email":"seller@example.test","password":"correct-password"}',
         }
      )
      check.equal(valid.status, 200, "supported app version allowed")
      check.equal(fake.headers("login")["x-kinetix-app-version"], "1.0.0", "validated version forwarded to identity")
   end)

   it("enforces X1 token claims, audience, and per-route roles before upstream", function()
      local no_auth = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = { ["Idempotency-Key"] = "idem-auth-1" },
            body = '{"addressId":1}',
         }
      )
      check.equal(no_auth.status, 401, "missing token -> 401")
      check.equal(client.text(no_auth, "error"), "TOKEN_REQUIRED", "token required code")

      local refresh_tok = bearer_with("prn_test_1", "customer", "refresh", "kinetix")
      local wrong_use = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["Authorization"] = "Bearer " .. refresh_tok,
               ["Idempotency-Key"] = "idem-auth-2",
            },
            body = '{"addressId":1}',
         }
      )
      check.equal(wrong_use.status, 401, "refresh token rejected on API")
      check.equal(client.text(wrong_use, "error"), "TOKEN_REQUIRED", "wrong token_use code")

      local wrong_aud_tok = bearer_with("prn_test_1", "customer", "access", "other-aud")
      local bad_aud = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["Authorization"] = "Bearer " .. wrong_aud_tok,
               ["Idempotency-Key"] = "idem-auth-3",
            },
            body = '{"addressId":1}',
         }
      )
      check.equal(bad_aud.status, 401, "wrong audience rejected")

      local courier_on_checkout = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = {
               ["Authorization"] = "Bearer " .. bearer_for("courier"),
               ["Idempotency-Key"] = "idem-auth-4",
            },
            body = '{"addressId":1}',
         }
      )
      check.equal(courier_on_checkout.status, 403, "courier forbidden on checkout")
      check.equal(client.text(courier_on_checkout, "error"), "FORBIDDEN", "forbidden code")

      local buyer_on_courier_apps = client.edge(
         "GET",
         "/api/v1/couriers/applications",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = { ["Authorization"] = "Bearer " .. bearer_for("customer") },
         }
      )
      check.equal(buyer_on_courier_apps.status, 403, "customer forbidden on courier admin applications")

      local buyer_on_merchant_wallet = client.edge(
         "GET",
         "/api/v1/payment/wallet/merchant/balance",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = { ["Authorization"] = "Bearer " .. bearer_for("customer") },
         }
      )
      check.equal(buyer_on_merchant_wallet.status, 403, "customer forbidden on merchant wallet")

      local seller_on_merchant_wallet = client.edge(
         "GET",
         "/api/v1/payment/wallet/merchant/balance",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = { ["Authorization"] = "Bearer " .. bearer_for("seller") },
         }
      )
      check.equal(seller_on_merchant_wallet.status, 200, "seller allowed on merchant wallet")

      local admin_search = client.edge(
         "GET",
         "/api/v1/orders/search",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            headers = { ["Authorization"] = "Bearer " .. bearer_for("admin") },
         }
      )
      check.equal(admin_search.status, 200, "admin allowed on orders search")
   end)

   it("enforces X2 Redis sliding-window rate limits and hashes keys with TTL", function()
      for attempt = 1, 5 do
         local ok_login = client.edge(
            "POST",
            "/api/v1/auth/login",
            {
               host = "api.localhost:8443",
               omit_origin = true,
               forwarded_for = "198.51.100." .. tostring(10 + attempt),
               headers = { ["X-Kinetix-Client"] = "seller-web" },
               body = '{"email":"seller@example.test","password":"correct-password"}',
            }
         )
         check.equal(ok_login.status, 200, "login attempt " .. tostring(attempt) .. " within limit")
      end

      local blocked = client.edge(
         "POST",
         "/api/v1/auth/login",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            forwarded_for = "198.51.100.99",
            headers = { ["X-Kinetix-Client"] = "seller-web" },
            body = '{"email":"Seller@Example.Test","password":"correct-password"}',
         }
      )
      check.equal(blocked.status, 429, "6th login for same email limited across IPs")
      check.equal(client.text(blocked, "error"), "TOO_MANY_REQUESTS", "rate limit error code")
      check.present(client.header(blocked, "Retry-After"), "Retry-After header present")
      check.equal(fake.count("login"), 5, "identity only called 5 times")

      local keys = redis_admin.keys("edge:rl:*")
      check.at_least(#keys, 2, "rate limit zset keys written")
      local email_hash = digest.sha256_hex("seller@example.test")
      local found_email_key = false
      for _, key in ipairs(keys) do
         check.excludes(key, "seller@example.test", "no raw email in redis key")
         check.excludes(key, "198.51.100", "no raw ip in redis key")
         check.at_least(redis_admin.pttl(key), 1, key .. " has positive TTL")
         if key == "edge:rl:auth_login_email:email:" .. email_hash then
            found_email_key = true
         end
      end
      check.truthy(found_email_key, "hashed email zset key exists")

      for attempt = 1, 30 do
         local rotating_tok = bearer_with("prn_rot_" .. tostring(attempt), "customer", "access", "kinetix")
         local res = client.edge(
            "POST",
            "/api/v1/orders/checkout",
            {
               host = "api.localhost:8443",
               omit_origin = true,
               forwarded_for = "198.51.100.200",
               headers = {
                  ["Authorization"] = "Bearer " .. rotating_tok,
                  ["Idempotency-Key"] = "idem-rot-" .. tostring(attempt),
               },
               body = '{"addressId":1}',
            }
         )
         check.equal(res.status, 200, "checkout " .. tostring(attempt) .. " within source IP cap")
      end

      local capped = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            forwarded_for = "198.51.100.200",
            headers = {
               ["Authorization"] = "Bearer " .. bearer_with("prn_rot_31", "customer", "access", "kinetix"),
               ["Idempotency-Key"] = "idem-rot-31",
            },
            body = '{"addressId":1}',
         }
      )
      check.equal(capped.status, 429, "source IP cap stops rotating sub values on checkout")
   end)
end)
