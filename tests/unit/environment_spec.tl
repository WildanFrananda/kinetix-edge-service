local check = require("tests.support.check")
local environment = require("adapters.environment")
local type Environment = require("types.environment")

local function complete(): {string: string}
   return {
      EDGE_REDIS_HOST = "kinetix-redis",
      EDGE_REDIS_PORT = "6379",
      EDGE_REDIS_USER = "edge",
      EDGE_REDIS_PASSWORD = "secret",
      IDENTITY_HTTP_URL = "http://kinetix-identity-service:5000",
      EDGE_API_UPSTREAM = "http://kinetix-api-gateway:8000",
      KINETIX_BACKOFFICE_ORIGINS = "https://backoffice.example.com",
      KINETIX_SELLER_HOST = "seller.wildanfrananda.my.id",
      KINETIX_SERVICE_VERSION = "0123456789abcdef",
   }
end

local function read(values: {string: string}): Environment, {string}
   return environment.read(function(name: string): string
      return values[name]
   end)
end

describe("environment", function()
   it("reads every required variable", function()
      local read_environment = read(complete())
      check.equal(read_environment.redis_port, 6379, "port")
      check.equal(read_environment.identity_url, "http://kinetix-identity-service:5000", "identity")
      check.equal(read_environment.service_version, "0123456789abcdef", "version")
   end)

   it("names every missing variable", function()
      for _, name in ipairs(environment.names) do
         local values = complete()
         values[name] = nil
         local read_environment, problems = read(values)
         check.absent(read_environment, name .. " missing")
         check.equal(problems[1], name .. " is required", "problem for " .. name)
      end
   end)

   it("treats a blank value as missing", function()
      local values = complete()
      values["EDGE_REDIS_PASSWORD"] = "   "
      local _, problems = read(values)
      check.equal(problems[1], "EDGE_REDIS_PASSWORD is required", "blank")
   end)

   it("refuses values that cannot be what they name", function()
      local cases: {{string}} = {
         { "EDGE_REDIS_PORT", "0" },
         { "EDGE_REDIS_PORT", "redis" },
         { "IDENTITY_HTTP_URL", "kinetix-identity-service:5000" },
         { "EDGE_API_UPSTREAM", "http://kinetix-api-gateway:8000/api" },
         { "EDGE_API_UPSTREAM", "https://kinetix-api-gateway:8443" },
         { "KINETIX_SELLER_HOST", "https://seller.example" },
         { "KINETIX_SERVICE_VERSION", "unknown" },
         { "KINETIX_SERVICE_VERSION", "1.2.3-SNAPSHOT" },
      }
      for _, case in ipairs(cases) do
         local values = complete()
         values[case[1]] = case[2]
         local read_environment, problems = read(values)
         check.absent(read_environment, case[1] .. "=" .. case[2])
         check.present(problems[1], "problem for " .. case[1])
      end
   end)

   it("reads the backoffice's origins, an onion over http and the rest over https", function()
      local values = complete()
      values["KINETIX_BACKOFFICE_ORIGINS"] = " http://ABCDEFGHIJKLMNOPQRSTUVWXYZ234567abcdefghijklmnopqrstuv.onion"
         .. " , https://192.0.2.1 "
      local read_environment, problems = read(values)
      check.equal(#problems, 0, "no problem")
      check.equal(#read_environment.backoffice_origins, 2, "two origins")
      check.equal(
         read_environment.backoffice_origins[1],
         "http://abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuv.onion",
         "the onion, lowered"
      )
      check.equal(read_environment.backoffice_origins[2], "https://192.0.2.1", "the tunnel address")
   end)

   it("refuses a backoffice origin that is not secure, not an origin, or not the backoffice's alone", function()
      local cases: {string} = {
         "http://backoffice.example.com",
         "backoffice.example.com",
         "https://backoffice.example.com/",
         "https://backoffice.example.com/path",
         "ftp://backoffice.example.com",
         ",",
         "https://192.0.2.1,https://192.0.2.1:9443",
         "https://seller.wildanfrananda.my.id",
      }
      for _, origins in ipairs(cases) do
         local values = complete()
         values["KINETIX_BACKOFFICE_ORIGINS"] = origins
         local read_environment, problems = read(values)
         check.absent(read_environment, origins)
         check.present(problems[1], "problem for " .. origins)
      end
   end)

   it("names a refused origin by its position, never by its value", function()
      local values = complete()
      values["KINETIX_BACKOFFICE_ORIGINS"] = "https://192.0.2.1,http://secretaddress.example"
      local _, problems = read(values)
      check.equal(
         problems[1],
         "KINETIX_BACKOFFICE_ORIGINS entry 2 may use http only for a .onion host, which browsers treat as secure",
         "positional problem"
      )
   end)

   it("refuses one host for both applications, since the port does not tell them apart", function()
      local values = complete()
      values["KINETIX_SELLER_HOST"] = "BACKOFFICE.example.com"
      check.absent(read(values), "same host")

      values["KINETIX_SELLER_HOST"] = "backoffice.example.com:8443"
      check.absent(read(values), "same host, another port")
   end)
end)
