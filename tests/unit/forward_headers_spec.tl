local check = require("tests.support.check")
local forward_headers = require("http.forward_headers")
local type RequestContext = require("types.request_context")

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
      local upstream = forward_headers.upstream(browser, REQUEST, "access-1", "seller-web")
      check.equal(upstream["x-kinetix-client"], "seller-web", "the edge's own client name, not the browser's")
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
end)
