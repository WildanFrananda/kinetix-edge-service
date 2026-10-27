local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local type Answer = require("tests.support.types.answer")

local function echoed_headers(answer: Answer): {string: string}
   local decoded = cjson.decode(answer.body)
   if not decoded is cjson.Document then
      return {}
   end

   return (decoded["headers"] as {string: string}) or {}
end

describe("the API forwarder", function()
   local cookie: string = nil

   before_each(function()
      fake.reset()
      redis_admin.flush()
      cookie = flows.session(flows.session_cookie("seller-web", "seller@example.test"))
   end)

   it("adds the bearer and the request context, and strips what the browser must not decide", function()
      local request_id = client.request_id()
      local answer = client.edge(
         "GET",
         "/bff/api/v1/orders/OR-1?x=1&y=two",
         {
            cookie = cookie .. "; other=1",
            request_id = request_id,
            forwarded_for = "10.9.8.7, 203.0.113.50",
            headers = {
               ["Authorization"] = "Bearer forged",
               ["X-Kinetix-Client"] = "backoffice",
               ["X-User-Id"] = "7",
               ["Idempotency-Key"] = "k-1",
               ["Accept-Language"] = "id",
            },
         }
      )
      check.equal(answer.status, 200, "status")
      check.equal(client.text(answer, "method"), "GET", "method")
      check.equal(client.text(answer, "path"), "/api/v1/orders/OR-1", "path")
      check.equal(client.text(answer, "query"), "x=1&y=two", "query")

      local headers = echoed_headers(answer)
      check.equal(headers["authorization"], "Bearer " .. fake.issued("access"), "the session's access token")
      check.equal(headers["x-request-id"], request_id, "the gateway's request id")
      check.equal(headers["x-forwarded-for"], "203.0.113.50", "the browser's address alone")
      check.equal(headers["idempotency-key"], "k-1", "idempotency key")
      check.equal(headers["accept-language"], "id", "language")
      check.equal(headers["host"], "127.0.0.1:18002", "the upstream's own host, not the browser's")
      check.absent(headers["cookie"], "no cookie upstream")
      check.absent(headers["x-kinetix-client"], "no client name upstream")
      check.absent(headers["x-user-id"], "no identity hint upstream")

      check.equal(#answer.set_cookies, 0, "no upstream Set-Cookie")
      check.equal(client.header(answer, "Cache-Control"), "no-store", "no-store over the upstream's caching")
      check.equal(client.header(answer, "X-Upstream"), "fake-api", "other upstream headers pass")
      check.absent(client.header(answer, "X-Powered-By"), "no X-Powered-By")
   end)

   it("forwards a JSON body and the method", function()
      local body = client.json({ items = 2 })
      local answer = client.edge("POST", "/bff/api/v1/orders", { cookie = cookie, body = body })
      check.equal(answer.status, 200, "status")
      check.equal(client.text(answer, "method"), "POST", "method")
      check.equal(client.text(answer, "body"), body, "body")
      check.equal(echoed_headers(answer)["content-type"], "application/json", "content type")
   end)

   it("passes the upstream's status through", function()
      local answer = client.edge("GET", "/bff/api/v1/fake/status/418", { cookie = cookie })
      check.equal(answer.status, 418, "status")
   end)

   it("never forwards to identity's token-issuing routes", function()
      local direct = client.edge("POST", "/bff/api/v1/auth/login", { cookie = cookie, body = "{}" })
      check.equal(direct.status, 404, "login")
      check.equal(client.text(direct, "error"), "NOT_FOUND", "code")

      local encoded = client.edge("POST", "/bff/api/v1/auth/%6Cogin", { cookie = cookie, body = "{}" })
      check.equal(encoded.status, 404, "percent-encoded")

      local refresh = client.edge("POST", "/bff/api/v1/AUTH/refresh/", { cookie = cookie, body = "{}" })
      check.equal(refresh.status, 404, "case and trailing slash")

      local register = client.edge("POST", "/bff/api/v1/auth/register", { cookie = cookie, body = "{}" })
      check.equal(register.status, 404, "register, which issues tokens too")
      check.equal(fake.count("login"), 1, "only the sign-in of the setup reached identity")
   end)

   it("asks for a session, and ends a cookie that names none", function()
      local none = client.edge("GET", "/bff/api/v1/orders", {})
      check.equal(none.status, 401, "no cookie")
      check.equal(client.text(none, "error"), "SESSION_REQUIRED", "code")

      local unknown = client.edge("GET", "/bff/api/v1/orders", { cookie = flows.session(string.rep("Z", 43)) })
      check.equal(unknown.status, 401, "unknown cookie")
      check.equal(client.text(unknown, "error"), "SESSION_ENDED", "code")
      check.equal(
         unknown.set_cookies[1],
         "__Host-kx_session=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0",
         "expired"
      )
   end)

   it("answers 503 when the API cannot be reached", function()
      local answer = client.edge("GET", "/bff/api/v1/fake/close", { cookie = cookie })
      check.equal(answer.status, 503, "status")
      check.equal(client.text(answer, "error"), "API_UNAVAILABLE", "code")
   end)

   it("serves only /bff/api/ and below", function()
      check.equal(client.edge("GET", "/bff/api", { cookie = cookie }).status, 404, "the bare prefix")
      check.equal(client.edge("GET", "/bff/apix/v1", { cookie = cookie }).status, 404, "a longer word")
   end)
end)
