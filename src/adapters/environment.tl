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
   "KINETIX_BACKOFFICE_ORIGINS",
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

local function is_plain_base_url(value: string): boolean
   return string.match(value, "^http://[%w%.%-]+$") ~= nil
      or string.match(value, "^http://[%w%.%-]+:%d+$") ~= nil
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

local function origin_parts(value: string): string, string
   local scheme, host = string.match(value, "^(https?)://([%w%.%-]+)$")
   if scheme == nil then
      scheme, host = string.match(value, "^(https?)://([%w%.%-]+:%d+)$")
   end

   return scheme, host
end

local function backoffice_origins(value: string, seller_hostname: string, problems: {string}): {string}
   local origins: {string} = {}
   local seen: {string: boolean} = {}
   local position = 0

   for entry in string.gmatch(value, "[^,]+") do
      position = position + 1
      local origin = string.lower(trimmed(entry))
      local scheme, host = origin_parts(origin)
      local label = "KINETIX_BACKOFFICE_ORIGINS entry " .. tostring(position)
      if scheme == nil then
         table.insert(problems, label .. " must be http(s)://host[:port] with no path")
      else
         local hostname = hostname_of(host)
         if scheme == "http" and string.match(hostname, "%.onion$") == nil then
            table.insert(problems, label .. " may use http only for a .onion host, which browsers treat as secure")
         elseif seen[hostname] then
            table.insert(problems, label .. " repeats a host name an earlier entry names")
         elseif hostname == seller_hostname then
            table.insert(problems, label .. " names KINETIX_SELLER_HOST's host; each app needs its own")
         else
            seen[hostname] = true
            table.insert(origins, origin)
         end
      end
   end

   if position == 0 then
      table.insert(problems, "KINETIX_BACKOFFICE_ORIGINS must name at least one origin")
   end

   return origins
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
      is_plain_base_url(values["EDGE_API_UPSTREAM"]),
      "EDGE_API_UPSTREAM must be http://host[:port] with no path: the gateway's internal plaintext listener"
   )
   check(problems, is_host(values["KINETIX_SELLER_HOST"]), "KINETIX_SELLER_HOST must be host or host:port")
   local origins = backoffice_origins(
      values["KINETIX_BACKOFFICE_ORIGINS"],
      hostname_of(values["KINETIX_SELLER_HOST"]),
      problems
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
      backoffice_origins = origins,
      seller_host = values["KINETIX_SELLER_HOST"],
      service_version = values["KINETIX_SERVICE_VERSION"],
   }, problems
end

return environment
