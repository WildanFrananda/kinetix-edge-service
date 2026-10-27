local type AppPolicy = require("types.app_policy")
local type Environment = require("types.environment")
local lifetimes = require("config.lifetimes")

local record apps
end

function apps.policies(environment: Environment): {AppPolicy}
   local backoffice_host = string.lower(environment.backoffice_host)
   local seller_host = string.lower(environment.seller_host)
   local backoffice_hostname = string.gsub(backoffice_host, ":%d+$", "")
   local seller_hostname = string.gsub(seller_host, ":%d+$", "")

   return {
      {
         name = "backoffice",
         client = "backoffice",
         host = backoffice_host,
         hostname = backoffice_hostname,
         origin = "https://" .. backoffice_host,
         roles = { "admin" },
         enrolment = true,
         sign_up = false,
         merchant_socket_roles = {},
         persistent_cookie = false,
         idle_seconds = lifetimes["backoffice"].idle_seconds,
         absolute_seconds = lifetimes["backoffice"].absolute_seconds,
      },
      {
         name = "seller-web",
         client = "seller-web",
         host = seller_host,
         hostname = seller_hostname,
         origin = "https://" .. seller_host,
         roles = { "seller", "customer" },
         enrolment = false,
         sign_up = true,
         merchant_socket_roles = { "seller" },
         persistent_cookie = true,
         idle_seconds = lifetimes["seller-web"].idle_seconds,
         absolute_seconds = lifetimes["seller-web"].absolute_seconds,
      },
   }
end

return apps
