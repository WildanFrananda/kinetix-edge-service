local type AppPolicy = require("types.app_policy")
local type Environment = require("types.environment")

local record Settings
   environment: Environment
   apps: {AppPolicy}
end

return Settings
