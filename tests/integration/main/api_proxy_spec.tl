local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")

local function encode_b64url(text: string): string
   local encoded = ngx.encode_base64(text, true)
   return (string.gsub(string.gsub(encoded, "+", "-"), "/", "_"))
end

local function bearer_for(role: string): string
   local header = encode_b64url('{"alg":"RS256","typ":"JWT"}')
   local encoded_payload = cjson.encode({ sub = "prn_test_1", role = role })
   local payload = encode_b64url(encoded_payload)
   return header .. "." .. payload .. ".sig"
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
         { host = "api.localhost:8443", omit_origin = true }
      )
      check.equal(api_answer.status, 200, "proxied API status")
      check.equal(client.header(api_answer, "X-Content-Type-Options"), "nosniff", "api nosniff")
      check.absent(client.header(api_answer, "X-Powered-By"), "api strips X-Powered-By")
   end)

   it("enforces Idempotency-Key, JSON validity, Content-Type, and route body caps before upstream", function()
      local no_idem = client.edge(
         "POST",
         "/api/v1/orders/checkout",
         {
            host = "api.localhost:8443",
            omit_origin = true,
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
            headers = { ["Idempotency-Key"] = "idem-1" },
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
            headers = { ["Idempotency-Key"] = "idem-2" },
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
            headers = { ["Idempotency-Key"] = "idem-3" },
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

      local webhook = client.edge(
         "POST",
         "/api/v1/payment/gateway/midtrans/notifications",
         {
            host = "api.localhost:8443",
            omit_origin = true,
            body = '{"order_id":"ORD-1"}',
         }
      )
      check.equal(webhook.status, 200, "webhook does not require idempotency key")
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
end)
