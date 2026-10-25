local type AppName = require("types.app_name")
local type Lifetime = require("types.lifetime")

local lifetimes: {AppName: Lifetime} = {
   ["backoffice"] = { idle_seconds = 2, absolute_seconds = 6 },
   ["seller-web"] = { idle_seconds = 3, absolute_seconds = 5 },
}

return lifetimes
