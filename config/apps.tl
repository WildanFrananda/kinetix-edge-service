local type AppPolicy = require("types.app_policy")
local type Environment = require("types.environment")
local lifetimes = require("config.lifetimes")

local record apps
end

local function host_of(origin: string): string
   return (string.gsub(origin, "^https?://", ""))
end

local function hostname_of(host: string): string
   return (string.gsub(host, ":%d+$", ""))
end

function apps.policies(environment: Environment): {AppPolicy}
   local policies: {AppPolicy} = {}

   for _, origin in ipairs(environment.backoffice_origins) do
      local host = host_of(string.lower(origin))
      table.insert(policies, {
         name = "backoffice",
         client = "backoffice",
         host = host,
         hostname = hostname_of(host),
         origin = string.lower(origin),
         roles = { "admin" },
         enrolment = true,
         sign_up = false,
         merchant_socket_roles = {},
         persistent_cookie = false,
         idle_seconds = lifetimes["backoffice"].idle_seconds,
         absolute_seconds = lifetimes["backoffice"].absolute_seconds,
      })
   end

   local seller_host = string.lower(environment.seller_host)
   table.insert(policies, {
      name = "seller-web",
      client = "seller-web",
      host = seller_host,
      hostname = hostname_of(seller_host),
      origin = "https://" .. seller_host,
      roles = { "seller", "customer" },
      enrolment = false,
      sign_up = true,
      merchant_socket_roles = { "seller" },
      persistent_cookie = true,
      idle_seconds = lifetimes["seller-web"].idle_seconds,
      absolute_seconds = lifetimes["seller-web"].absolute_seconds,
   })

   return policies
end

return apps
