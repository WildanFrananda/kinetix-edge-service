local type Environment = require("types.environment")

local record environment
   names: {string}
end

environment.names = {
   "EDGE_REDIS_HOST",
   "EDGE_REDIS_PORT",
   "EDGE_REDIS_USER",
   "EDGE_REDIS_PASSWORD",
   "IDENTITY_HTTP_URL",
   "EDGE_API_UPSTREAM",
   "KINETIX_BACKOFFICE_HOST",
   "KINETIX_SELLER_HOST",
   "KINETIX_SERVICE_VERSION",
}

local UNIDENTIFIED_VERSIONS: {string} = { "unknown", "unset", "none", "n/a", "null", "dev", "latest" }

local function trimmed(value: string): string
   return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function port_of(value: string): integer
   if string.match(value, "^%d+$") == nil then
      return nil
   end

   local port = math.floor(tonumber(value))
   if port < 1 or port > 65535 then
      return nil
   end

   return port
end

local function is_base_url(value: string): boolean
   return string.match(value, "^https?://[%w%.%-]+$") ~= nil
      or string.match(value, "^https?://[%w%.%-]+:%d+$") ~= nil
end

local function is_host(value: string): boolean
   return string.match(value, "^[%w%.%-]+$") ~= nil
      or string.match(value, "^[%w%.%-]+:%d+$") ~= nil
end

local function identifies_a_build(value: string): boolean
   local lowered = string.lower(value)
   for _, unidentified in ipairs(UNIDENTIFIED_VERSIONS) do
      if lowered == unidentified then
         return false
      end
   end

   if string.match(lowered, "^0%.0%.0") ~= nil then
      return false
   end

   return string.match(lowered, "%-snapshot$") == nil and string.match(lowered, "%-dev$") == nil
end

local function hostname_of(host: string): string
   return (string.gsub(string.lower(host), ":%d+$", ""))
end

local function check(problems: {string}, holds: boolean, problem: string)
   if not holds then
      table.insert(problems, problem)
   end
end

function environment.read(getenv: function(string): string): Environment, {string}
   local values: {string: string} = {}
   local problems: {string} = {}

   for _, name in ipairs(environment.names) do
      local raw = getenv(name)
      local value = raw ~= nil and trimmed(raw) or ""
      if value == "" then
         table.insert(problems, name .. " is required")
      else
         values[name] = value
      end
   end

   if #problems > 0 then
      return nil, problems
   end

   local port = port_of(values["EDGE_REDIS_PORT"])
   check(problems, port ~= nil, "EDGE_REDIS_PORT must be a TCP port")
   check(
      problems,
      is_base_url(values["IDENTITY_HTTP_URL"]),
      "IDENTITY_HTTP_URL must be http(s)://host[:port] with no path"
   )
   check(
      problems,
      is_base_url(values["EDGE_API_UPSTREAM"]),
      "EDGE_API_UPSTREAM must be http(s)://host[:port] with no path"
   )
   check(problems, is_host(values["KINETIX_BACKOFFICE_HOST"]), "KINETIX_BACKOFFICE_HOST must be host or host:port")
   check(problems, is_host(values["KINETIX_SELLER_HOST"]), "KINETIX_SELLER_HOST must be host or host:port")
   check(
      problems,
      hostname_of(values["KINETIX_BACKOFFICE_HOST"]) ~= hostname_of(values["KINETIX_SELLER_HOST"]),
      "KINETIX_BACKOFFICE_HOST and KINETIX_SELLER_HOST must name different hosts"
   )
   check(
      problems,
      identifies_a_build(values["KINETIX_SERVICE_VERSION"]),
      "KINETIX_SERVICE_VERSION must identify a build"
   )

   if #problems > 0 then
      return nil, problems
   end

   return {
      redis_host = values["EDGE_REDIS_HOST"],
      redis_port = port,
      redis_user = values["EDGE_REDIS_USER"],
      redis_password = values["EDGE_REDIS_PASSWORD"],
      identity_url = values["IDENTITY_HTTP_URL"],
      api_upstream = values["EDGE_API_UPSTREAM"],
      backoffice_host = values["KINETIX_BACKOFFICE_HOST"],
      seller_host = values["KINETIX_SELLER_HOST"],
      service_version = values["KINETIX_SERVICE_VERSION"],
   }, problems
end

return environment
