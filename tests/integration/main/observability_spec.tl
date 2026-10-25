local check = require("tests.support.check")
local client = require("tests.support.client")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")

local function metrics(): string
   return client.call(scenario.metrics_url, "GET", "/metrics", {}, nil).body
end

local function value_of(text: string, series: string): number
   for line in string.gmatch(text, "[^\n]+") do
      if string.sub(line, 1, #series + 1) == series .. " " then
         return tonumber(string.sub(line, #series + 2))
      end
   end

   return nil
end

describe("health and metrics", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("answers liveness and, with Redis answering PING as the edge user, readiness", function()
      local live = client.call(scenario.edge_url, "GET", "/health", {}, nil)
      check.equal(live.status, 200, "live")
      check.equal(client.text(live, "status"), "ok", "live body")
      check.equal(client.header(live, "Cache-Control"), "no-store", "no-store")
      check.absent(client.header(live, "Server"), "no Server header")

      local ready = client.call(scenario.edge_url, "GET", "/health/ready", {}, nil)
      check.equal(ready.status, 200, "ready")
      check.equal(client.text(ready, "status"), "ready", "ready body")
   end)

   it("publishes the estate's names on 9145, the build in build_info, and counts by route name", function()
      flows.session_cookie("seller-web", "seller@example.test")
      client.edge("GET", "/bff/session", {})
      client.edge("POST", "/bff/login", { origin = "https://evil.example", body = "{}" })

      local answer = client.call(scenario.metrics_url, "GET", "/metrics", {}, nil)
      check.equal(answer.status, 200, "status")
      check.matches(client.header(answer, "Content-Type"), "^text/plain", "text format")

      local text = answer.body
      check.equal(
         value_of(text, "kinetix_build_info{service=\"kinetix-edge-service\",version=\"" .. scenario.version .. "\"}"),
         1,
         "build info"
      )
      check.at_least(
         value_of(text, "kinetix_http_requests_total{method=\"POST\",route=\"/bff/login\",status=\"200\"}"),
         1,
         "requests by route name"
      )
      check.at_least(
         value_of(text, "kinetix_http_request_duration_seconds_count{method=\"GET\",route=\"/bff/session\"}"),
         1,
         "duration"
      )
      check.at_least(value_of(text, "kinetix_edge_sessions_started_total{app=\"seller-web\"}"), 1, "sessions")
      check.at_least(
         value_of(text, "kinetix_edge_csrf_refusals_total{app=\"seller-web\",reason=\"origin\"}"),
         1,
         "csrf refusals"
      )
      check.equal(
         value_of(text, "kinetix_edge_refreshes_total{app=\"backoffice\",outcome=\"role_refused\"}"),
         0,
         "pre-published at zero"
      )
      check.excludes(text, "/bff/api/v1", "no raw path in a label")
      check.excludes(metrics(), "example.test", "no email in a label")
   end)
end)
