local type AppVersionRule = require("types.app_version_rule")

local record app_versions
   rules: {string: AppVersionRule}
end

app_versions.rules = {
   ["courier-app"] = {
      client = "courier-app",
      minimum_version = "1.0.0",
      store_url = "https://play.google.com/store/apps/details?id=com.kinetix.courier",
   },
   ["buyer-app"] = {
      client = "buyer-app",
      minimum_version = "1.0.0",
      store_url = "https://play.google.com/store/apps/details?id=com.kinetix.buyer",
   },
}

function app_versions.find(client: string): AppVersionRule
   if client == nil or client == "" then
      return nil
   end

   return app_versions.rules[string.lower(client)]
end

return app_versions
