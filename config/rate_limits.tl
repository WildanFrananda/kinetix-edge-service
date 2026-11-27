local type RateLimitRule = require("types.rate_limit_rule")

local record rate_limits
   groups: {string: {RateLimitRule}}
end

rate_limits.groups = {
   ["auth_login"] = {
      { name = "auth_login_ip", max_requests = 10, window_ms = 60000, key_scope = "ip" },
      { name = "auth_login_email", max_requests = 5, window_ms = 60000, key_scope = "email" },
   },
   ["auth_register"] = {
      { name = "auth_register_ip", max_requests = 5, window_ms = 60000, key_scope = "ip" },
      { name = "auth_register_email", max_requests = 3, window_ms = 60000, key_scope = "email" },
   },
   ["auth_public"] = {
      { name = "auth_public_ip", max_requests = 20, window_ms = 60000, key_scope = "ip" },
   },
   ["checkout"] = {
      { name = "checkout_principal", max_requests = 20, window_ms = 60000, key_scope = "principal" },
   },
   ["topup"] = {
      { name = "topup_principal", max_requests = 10, window_ms = 60000, key_scope = "principal" },
   },
   ["api_user"] = {
      { name = "api_user_principal", max_requests = 120, window_ms = 60000, key_scope = "principal" },
   },
   ["api_admin"] = {
      { name = "api_admin_principal", max_requests = 180, window_ms = 60000, key_scope = "principal" },
   },
}

function rate_limits.for_group(group: string): {RateLimitRule}
   if group == nil or group == "" then
      return {}
   end

   return rate_limits.groups[group] or {}
end

return rate_limits
