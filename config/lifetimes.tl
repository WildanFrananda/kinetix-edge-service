local type AppName = require("types.app_name")
local type Lifetime = require("types.lifetime")

local lifetimes: {AppName: Lifetime} = {
   ["backoffice"] = { idle_seconds = 900, absolute_seconds = 28800 },
   ["seller-web"] = { idle_seconds = 604800, absolute_seconds = 2592000 },
}

return lifetimes
