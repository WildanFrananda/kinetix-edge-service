local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")

local function shaped(answer: Answer, status: integer, code: string, label: string)
   check.equal(answer.status, status, label)
   check.equal(client.text(answer, "error"), code, label .. " code")
   check.present(client.text(answer, "message"), label .. " message")
   check.present(client.text(answer, "requestId"), label .. " request id")
   check.equal(client.header(answer, "Cache-Control"), "no-store", label .. " no-store")
   check.matches(client.header(answer, "Content-Type"), "^application/json", label .. " JSON")
end

describe("every error in one shape", function()
   before_each(function()
      fake.reset()
   end)

   it("for unknown paths, wrong methods and the paths beside /bff/", function()
      shaped(client.edge("GET", "/bff/nothing", {}), 404, "NOT_FOUND", "unknown path")
      shaped(client.edge("GET", "/bff", {}), 404, "NOT_FOUND", "/bff")
      shaped(client.edge("GET", "/bffx/session", {}), 404, "NOT_FOUND", "/bffx")

      local wrong = client.edge("DELETE", "/bff/session", {})
      shaped(wrong, 405, "METHOD_NOT_ALLOWED", "wrong method")
      check.equal(client.header(wrong, "Allow"), "GET", "allow")
   end)

   it("for a body nginx refuses as too large", function()
      local big = string.rep("a", 1100000)
      shaped(client.edge("POST", "/bff/api/v1/orders", { body = big }), 413, "PAYLOAD_TOO_LARGE", "too large")
   end)

   it("echoes the gateway's request id, and makes one when there is none or it is unusable", function()
      local answer = client.edge("GET", "/bff/nothing", { request_id = "gw-123#4" })
      check.equal(client.text(answer, "requestId"), "gw-123#4", "kept")

      local raw = client.call(
         scenario.edge_url,
         "GET",
         "/bff/nothing",
         { ["Host"] = scenario.hosts["seller-web"], ["X-Forwarded-For"] = scenario.forwarded_for },
         nil
      )
      check.matches(client.text(raw, "requestId"), "^%x+$", "generated")
      check.equal(#client.text(raw, "requestId"), 32, "nginx's 128-bit id")

      local unusable = client.edge("GET", "/bff/nothing", { request_id = "a b" })
      check.differ(client.text(unusable, "requestId"), "a b", "replaced")
   end)

   it("refuses an unknown host and a request that did not come through the gateway", function()
      shaped(client.edge("GET", "/bff/session", { host = "evil.example" }), 404, "NOT_FOUND", "unknown host")
      shaped(
         client.edge("GET", "/bff/session", { omit_forwarded_for = true }),
         400,
         "CLIENT_ADDRESS_REQUIRED",
         "no X-Forwarded-For"
      )
      shaped(
         client.edge("GET", "/bff/session", { forwarded_for = "198.51.100.23, not-an-address" }),
         400,
         "CLIENT_ADDRESS_REQUIRED",
         "the last entry is not an address"
      )
   end)

   it("matches the application by host name, whatever port the browser named", function()
      local answer = client.edge("GET", "/bff/session", { host = "seller.localhost" })
      check.equal(answer.status, 200, "production-style Host without a port")
   end)
end)
