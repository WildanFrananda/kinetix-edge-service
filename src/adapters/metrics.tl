local type MetricFamily = require("types.metric_family")

local record metrics
   type Labels = {{string}}

   dict_name: string
   buckets: {number}
   methods: {string}
   apps: {string}
   end_reasons: {string}
   refresh_outcomes: {string}
   csrf_reasons: {string}
   dependencies: {string}
   socket_outcomes: {string}
   revocation_outcomes: {string}
end

metrics.dict_name = "edge_metrics"

metrics.buckets = { 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 }

metrics.methods = { "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" }

metrics.apps = { "backoffice", "seller-web" }

metrics.end_reasons = { "logout", "refresh_refused", "role_refused", "absolute_limit", "replaced", "unknown" }

metrics.refresh_outcomes = { "renewed", "refused", "unavailable", "role_refused" }

metrics.csrf_reasons = { "origin", "fetch_site", "content_type" }

metrics.dependencies = { "redis", "identity", "api" }

metrics.socket_outcomes = {
   "upgraded",
   "refused",
   "unavailable",
   "not_websocket",
   "origin_refused",
   "session_refused",
   "session_unavailable",
   "role_refused",
}

metrics.revocation_outcomes = { "revoked", "already_revoked", "failed" }

local REQUESTS = "kinetix_http_requests_total"
local DURATION = "kinetix_http_request_duration_seconds"
local BUILD_INFO = "kinetix_build_info"
local SESSIONS_STARTED = "kinetix_edge_sessions_started_total"
local SESSIONS_ENDED = "kinetix_edge_sessions_ended_total"
local REFRESHES = "kinetix_edge_refreshes_total"
local CSRF_REFUSALS = "kinetix_edge_csrf_refusals_total"
local DEPENDENCY_FAILURES = "kinetix_edge_dependency_failures_total"
local SOCKET_UPGRADES = "kinetix_edge_socket_upgrades_total"
local SESSION_REVOCATIONS = "kinetix_edge_session_revocations_total"

local FAMILIES: {MetricFamily} = {
   { name = REQUESTS, help = "HTTP requests answered, by method, route and status.", kind = "counter" },
   { name = DURATION, help = "Seconds spent answering an HTTP request, by method and route.", kind = "histogram" },
   { name = BUILD_INFO, help = "Always 1. The labels say which build answered this scrape.", kind = "gauge" },
   { name = SESSIONS_STARTED, help = "Browser sessions started, by application.", kind = "counter" },
   { name = SESSIONS_ENDED, help = "Browser sessions ended, by application and reason.", kind = "counter" },
   { name = REFRESHES, help = "Token refreshes asked of identity, by application and outcome.", kind = "counter" },
   {
      name = CSRF_REFUSALS,
      help = "State-changing requests refused before anything was asked, by application and reason.",
      kind = "counter",
   },
   {
      name = DEPENDENCY_FAILURES,
      help = "Calls to a dependency that got no usable answer, by dependency.",
      kind = "counter",
   },
   {
      name = SOCKET_UPGRADES,
      help = "Merchant socket upgrade requests, by application and outcome.",
      kind = "counter",
   },
   {
      name = SESSION_REVOCATIONS,
      help = "Ended sessions whose tokens the edge asked identity to revoke, by application and outcome.",
      kind = "counter",
   },
}

local function escaped(value: string): string
   local slashes = string.gsub(value, "\\", "\\\\")
   local quotes = string.gsub(slashes, "\"", "\\\"")
   local lines = string.gsub(quotes, "\n", "\\n")

   return lines
end

local function series(name: string, labels: metrics.Labels): string
   local parts: {string} = {}
   for _, pair in ipairs(labels) do
      table.insert(parts, pair[1] .. "=\"" .. escaped(pair[2]) .. "\"")
   end

   return name .. "{" .. table.concat(parts, ",") .. "}"
end

local function bucket_label(bound: number): string
   return tostring(bound)
end

local function dict(): ngx.SharedDict
   return ngx.shared[metrics.dict_name]
end

local function add(key: string, value: number)
   dict():incr(key, value, 0)
end

local function zero(key: string)
   dict():safe_add(key, 0)
end

local function method_label(method: string): string
   for _, known in ipairs(metrics.methods) do
      if known == method then
         return method
      end
   end

   return "OTHER"
end

local function histogram_keys(labels: metrics.Labels): {string}
   local keys: {string} = {}
   for _, bound in ipairs(metrics.buckets) do
      local with_bound: metrics.Labels = {}
      for _, pair in ipairs(labels) do
         table.insert(with_bound, pair)
      end

      table.insert(with_bound, { "le", bucket_label(bound) })
      table.insert(keys, series(DURATION .. "_bucket", with_bound))
   end

   local with_infinity: metrics.Labels = {}
   for _, pair in ipairs(labels) do
      table.insert(with_infinity, pair)
   end

   table.insert(with_infinity, { "le", "+Inf" })
   table.insert(keys, series(DURATION .. "_bucket", with_infinity))

   return keys
end

function metrics.request(method: string, route: string, status: integer, seconds: number)
   local verb = method_label(method)
   add(series(REQUESTS, { { "method", verb }, { "route", route }, { "status", string.format("%d", status) } }), 1)

   local labels: metrics.Labels = { { "method", verb }, { "route", route } }
   local keys = histogram_keys(labels)
   for index, bound in ipairs(metrics.buckets) do
      if seconds <= bound then
         add(keys[index], 1)
      end
   end

   add(keys[#keys], 1)
   add(series(DURATION .. "_sum", labels), seconds)
   add(series(DURATION .. "_count", labels), 1)
end

function metrics.session_started(app: string)
   add(series(SESSIONS_STARTED, { { "app", app } }), 1)
end

function metrics.session_ended(app: string, reason: string)
   add(series(SESSIONS_ENDED, { { "app", app }, { "reason", reason } }), 1)
end

function metrics.refresh(app: string, outcome: string)
   add(series(REFRESHES, { { "app", app }, { "outcome", outcome } }), 1)
end

function metrics.csrf_refused(app: string, reason: string)
   add(series(CSRF_REFUSALS, { { "app", app }, { "reason", reason } }), 1)
end

function metrics.dependency_failed(dependency: string)
   add(series(DEPENDENCY_FAILURES, { { "dependency", dependency } }), 1)
end

function metrics.socket_upgrade(app: string, outcome: string)
   add(series(SOCKET_UPGRADES, { { "app", app }, { "outcome", outcome } }), 1)
end

function metrics.session_revocation(app: string, outcome: string)
   add(series(SESSION_REVOCATIONS, { { "app", app }, { "outcome", outcome } }), 1)
end

local function prepublish_route(route: string)
   zero(series(REQUESTS, { { "method", "GET" }, { "route", route }, { "status", "200" } }))

   local labels: metrics.Labels = { { "method", "GET" }, { "route", route } }
   for _, key in ipairs(histogram_keys(labels)) do
      zero(key)
   end

   zero(series(DURATION .. "_sum", labels))
   zero(series(DURATION .. "_count", labels))
end

function metrics.prepublish()
   prepublish_route("/health")
   prepublish_route("/health/ready")

   for _, app in ipairs(metrics.apps) do
      zero(series(SESSIONS_STARTED, { { "app", app } }))

      for _, reason in ipairs(metrics.end_reasons) do
         zero(series(SESSIONS_ENDED, { { "app", app }, { "reason", reason } }))
      end

      for _, outcome in ipairs(metrics.refresh_outcomes) do
         zero(series(REFRESHES, { { "app", app }, { "outcome", outcome } }))
      end

      for _, reason in ipairs(metrics.csrf_reasons) do
         zero(series(CSRF_REFUSALS, { { "app", app }, { "reason", reason } }))
      end

      for _, outcome in ipairs(metrics.socket_outcomes) do
         zero(series(SOCKET_UPGRADES, { { "app", app }, { "outcome", outcome } }))
      end

      for _, outcome in ipairs(metrics.revocation_outcomes) do
         zero(series(SESSION_REVOCATIONS, { { "app", app }, { "outcome", outcome } }))
      end
   end

   for _, dependency in ipairs(metrics.dependencies) do
      zero(series(DEPENDENCY_FAILURES, { { "dependency", dependency } }))
   end
end

local function starts_with(value: string, prefix: string): boolean
   return string.sub(value, 1, #prefix) == prefix
end

local function number_text(value: number): string
   if value == math.floor(value) and value < 1e15 then
      return string.format("%d", value)
   end

   return string.format("%.9g", value)
end

local function histogram_lines(lines: {string}, keys: {string}, values: {string: number})
   local label_sets: {string} = {}
   local count_prefix = DURATION .. "_count{"
   for _, key in ipairs(keys) do
      if starts_with(key, count_prefix) then
         table.insert(label_sets, string.sub(key, #count_prefix + 1, #key - 1))
      end
   end

   table.sort(label_sets)

   for _, labels in ipairs(label_sets) do
      for _, bound in ipairs(metrics.buckets) do
         local key = DURATION .. "_bucket{" .. labels .. ",le=\"" .. bucket_label(bound) .. "\"}"
         table.insert(lines, key .. " " .. number_text(values[key] or 0))
      end

      local infinity = DURATION .. "_bucket{" .. labels .. ",le=\"+Inf\"}"
      table.insert(lines, infinity .. " " .. number_text(values[infinity] or 0))

      local sum = DURATION .. "_sum{" .. labels .. "}"
      table.insert(lines, sum .. " " .. number_text(values[sum] or 0))

      local count = DURATION .. "_count{" .. labels .. "}"
      table.insert(lines, count .. " " .. number_text(values[count] or 0))
   end
end

function metrics.render(service: string, version: string): string
   local shared = dict()
   local keys = shared:get_keys(0)
   table.sort(keys)

   local values: {string: number} = {}
   for _, key in ipairs(keys) do
      values[key] = shared:get(key)
   end

   local lines: {string} = {}
   for _, family in ipairs(FAMILIES) do
      table.insert(lines, "# HELP " .. family.name .. " " .. family.help)
      table.insert(lines, "# TYPE " .. family.name .. " " .. family.kind)

      if family.kind == "histogram" then
         histogram_lines(lines, keys, values)
      elseif family.name == BUILD_INFO then
         table.insert(lines, series(BUILD_INFO, { { "service", service }, { "version", version } }) .. " 1")
      else
         for _, key in ipairs(keys) do
            if starts_with(key, family.name .. "{") then
               table.insert(lines, key .. " " .. number_text(values[key] or 0))
            end
         end
      end
   end

   return table.concat(lines, "\n") .. "\n"
end

return metrics
