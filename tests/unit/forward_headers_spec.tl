local check = require("tests.support.check")
local forward_headers = require("http.forward_headers")
local type ApiRouteRule = require("types.api_route_rule")
local type RequestContext = require("types.request_context")

local STRIP_RULE: ApiRouteRule = {
   name = "/api/v1/orders/checkout",
   prefix = "/api/v1/orders/checkout",
   exact = true,
   methods = { "POST" },
   target = "api",
   max_body_bytes = 65536,
   require_json = true,
   require_idempotency = true,
   strip_client_header = true,
}

local IDENTITY_RULE: ApiRouteRule = {
   name = "/api/v1/auth/login",
   prefix = "/api/v1/auth/login",
   exact = true,
   methods = { "POST" },
   target = "identity",
   max_body_bytes = 16384,
   require_json = true,
   require_idempotency = false,
   strip_client_header = false,
}

local REQUEST: RequestContext = {
   request_id = "req-1",
   client_address = "198.51.100.23",
   method = "POST",
   headers = {},
}

describe("forward_headers", function()
   it("adds the bearer, the request id and the browser's address, and keeps only listed headers", function()
      local upstream = forward_headers.upstream(
         {
            ["cookie"] = "__Host-kx_session=x",
            ["authorization"] = "Bearer forged",
            ["x-forwarded-for"] = "1.2.3.4",
            ["x-kinetix-client"] = "backoffice",
            ["x-user-id"] = "7",
            ["content-type"] = "application/json",
            ["idempotency-key"] = "k-1",
            ["accept-language"] = { "id", "en" },
         },
         REQUEST,
         "access-1",
         nil,
         nil
      )
      check.equal(upstream["authorization"], "Bearer access-1", "bearer")
      check.equal(upstream["x-request-id"], "req-1", "request id")
      check.equal(upstream["x-forwarded-for"], "198.51.100.23", "browser address")
      check.equal(upstream["content-type"], "application/json", "content type")
      check.equal(upstream["idempotency-key"], "k-1", "idempotency key")
      check.equal(upstream["accept-language"], "id, en", "repeated header")
      check.absent(upstream["cookie"], "cookie")
      check.absent(upstream["x-kinetix-client"], "client name")
      check.absent(upstream["x-user-id"], "identity hint")
   end)

   it("names the application to identity only when the call goes to identity", function()
      local browser = { ["x-kinetix-client"] = "courier-app" }
      local upstream = forward_headers.upstream(browser, REQUEST, "access-1", "seller-web", nil)
      check.equal(upstream["x-kinetix-client"], "seller-web", "the edge's own client name, not the browser's")
   end)

   it("names the face to identity only when the forwarder gives one, never the browser's", function()
      local browser = { ["x-kinetix-origin"] = "https://evil.example" }
      local named = forward_headers.upstream(
         browser,
         REQUEST,
         "access-1",
         "backoffice",
         "https://backoffice.localhost:8443"
      )
      check.equal(named["x-kinetix-origin"], "https://backoffice.localhost:8443", "the face the edge matched")

      local unnamed = forward_headers.upstream(browser, REQUEST, "access-1", "backoffice", nil)
      check.absent(unnamed["x-kinetix-origin"], "the browser's own header stays behind")
   end)

   it("drops cookies, hop-by-hop and cache headers from the answer", function()
      local downstream = forward_headers.downstream({
         ["Set-Cookie"] = { "a=1", "b=2" },
         ["Content-Type"] = "application/json",
         ["Cache-Control"] = "max-age=600",
         ["Connection"] = "keep-alive",
         ["Transfer-Encoding"] = "chunked",
         ["X-Powered-By"] = "x",
         ["X-Request-Id"] = "req-1",
      })
      check.absent(downstream["Set-Cookie"], "set-cookie")
      check.absent(downstream["Cache-Control"], "cache-control")
      check.absent(downstream["Connection"], "connection")
      check.absent(downstream["Transfer-Encoding"], "transfer-encoding")
      check.absent(downstream["X-Powered-By"], "x-powered-by")
      check.equal(downstream["Content-Type"], "application/json", "content type kept")
      check.equal(downstream["X-Request-Id"], "req-1", "request id kept")
   end)

   it("sanitizes X-Kinetix-* hint headers on proxied API routes", function()
      local browser = {
         ["x-kinetix-client"] = "courier",
         ["x-firebase-appcheck"] = "appcheck-1",
         ["x-kinetix-origin"] = "https://forged.example",
         ["x-kinetix-locale"] = "id",
         ["x-kinetix-app-version"] = "9.9.9",
         ["x-kinetix-experiment"] = "canary",
         ["x-user-id"] = "999",
         ["cookie"] = "secret=1",
         ["idempotency-key"] = "idem-1",
      }
      local api_headers = forward_headers.api_upstream(browser, REQUEST, STRIP_RULE, "tok-1")
      check.equal(api_headers["authorization"], "Bearer tok-1", "bearer kept")
      check.equal(api_headers["idempotency-key"], "idem-1", "idempotency key kept")
      check.absent(api_headers["x-kinetix-client"], "client stripped on non-identity routes")
      check.absent(api_headers["x-firebase-appcheck"], "appcheck stripped on non-identity routes")
      check.absent(api_headers["x-kinetix-origin"], "origin hint stripped")
      check.absent(api_headers["x-kinetix-locale"], "locale hint stripped")
      check.absent(api_headers["x-kinetix-app-version"], "app version hint stripped")
      check.absent(api_headers["x-kinetix-experiment"], "experiment hint stripped")
      check.absent(api_headers["x-user-id"], "user id stripped")
      check.absent(api_headers["cookie"], "cookie stripped")

      local id_headers = forward_headers.api_upstream(browser, REQUEST, IDENTITY_RULE, nil)
      check.equal(id_headers["x-kinetix-client"], "courier", "client kept for identity")
      check.equal(id_headers["x-firebase-appcheck"], "appcheck-1", "appcheck kept for identity")
      check.absent(id_headers["x-kinetix-origin"], "origin hint still stripped for identity")
      check.absent(id_headers["x-kinetix-locale"], "locale hint still stripped for identity")
   end)
end)
