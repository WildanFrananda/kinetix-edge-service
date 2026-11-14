local type AppPolicy = require("types.app_policy")
local type Environment = require("types.environment")

local record Settings
   environment: Environment
   apps: {AppPolicy}
   host_aliases: {string: string}
end

return Settings
