local check = require("tests.support.check")
local metrics = require("adapters.metrics")

local function line_of(text: string, prefix: string): string
   for line in string.gmatch(text, "[^\n]+") do
      if string.sub(line, 1, #prefix) == prefix then
         return line
      end
   end

   return nil
end

describe("metrics", function()
   setup(function()
      metrics.prepublish()
   end)

   it("publishes the edge's counters at zero before anything happened", function()
      local text = metrics.render("kinetix-edge-service", "abc123")
      check.equal(line_of(text, "kinetix_edge_sessions_started_total{app=\"backoffice\"}"),
         "kinetix_edge_sessions_started_total{app=\"backoffice\"} 0", "sessions started")
      check.present(line_of(text, "kinetix_edge_sessions_ended_total{app=\"seller-web\",reason=\"refresh_refused\"} 0"),
         "sessions ended")
      check.present(line_of(text, "kinetix_edge_refreshes_total{app=\"backoffice\",outcome=\"unavailable\"} 0"),
         "refreshes")
      check.present(line_of(text, "kinetix_edge_csrf_refusals_total{app=\"seller-web\",reason=\"origin\"} 0"), "csrf")
      check.present(line_of(text, "kinetix_edge_dependency_failures_total{dependency=\"redis\"} 0"), "dependency")
      check.present(line_of(text, "kinetix_http_requests_total{method=\"GET\",route=\"/health\",status=\"200\"} 0"),
         "requests")
      check.present(line_of(text, "kinetix_http_request_duration_seconds_count{method=\"GET\",route=\"/health\"} 0"),
         "duration")
   end)

   it("names the service and its build only in kinetix_build_info", function()
      local text = metrics.render("kinetix-edge-service", "abc123")
      check.equal(line_of(text, "kinetix_build_info"),
         "kinetix_build_info{service=\"kinetix-edge-service\",version=\"abc123\"} 1", "build info")
      check.absent(line_of(text, "kinetix_http_requests_total{service"), "no service label on requests")
   end)

   it("counts a request and orders its buckets by bound", function()
      metrics.request("POST", "/bff/login", 200, 0.3)
      local text = metrics.render("kinetix-edge-service", "abc123")
      check.equal(line_of(text, "kinetix_http_requests_total{method=\"POST\",route=\"/bff/login\",status=\"200\"}"),
         "kinetix_http_requests_total{method=\"POST\",route=\"/bff/login\",status=\"200\"} 1", "counted")

      local prefix = "kinetix_http_request_duration_seconds_bucket{method=\"POST\",route=\"/bff/login\",le=\""
      check.equal(line_of(text, prefix .. "0.25\"}"), prefix .. "0.25\"} 0", "below")
      check.equal(line_of(text, prefix .. "0.5\"}"), prefix .. "0.5\"} 1", "above")
      check.equal(line_of(text, prefix .. "+Inf\"}"), prefix .. "+Inf\"} 1", "infinity")

      local two = string.find(text, prefix .. "2.5\"}", 1, true)
      local ten = string.find(text, prefix .. "10\"}", 1, true)
      check.truthy(two < ten, "2.5 before 10")
   end)

   it("folds an unknown method into OTHER, so a client cannot mint series", function()
      metrics.request("BREW", "unmatched", 405, 0.001)
      local text = metrics.render("kinetix-edge-service", "abc123")
      check.present(line_of(text, "kinetix_http_requests_total{method=\"OTHER\",route=\"unmatched\",status=\"405\"}"),
         "other")
      check.absent(line_of(text, "kinetix_http_requests_total{method=\"BREW\""), "no BREW series")
   end)
end)
