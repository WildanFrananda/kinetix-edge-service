local apps = require("config.apps")
local cjson = require("cjson.safe")
local environment = require("adapters.environment")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local settings = require("http.settings")

local record startup
end

function startup.run()
   local read, problems = environment.read(os.getenv)
   if read == nil then
      error("kinetix-edge-service refuses to start: " .. table.concat(problems, "; "), 0)
   end

   cjson.encode_escape_forward_slash(false)
   settings.current = { environment = read, apps = apps.policies(read) }
   metrics.prepublish()
   logger.info(
      "configured",
      {
         version = read.service_version,
         backoffice_host = settings.current.apps[1].host,
         seller_host = settings.current.apps[2].host,
      }
   )
end

return startup
