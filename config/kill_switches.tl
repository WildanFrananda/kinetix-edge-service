local type KillSwitchRule = require("types.kill_switch_rule")

local record kill_switches_config
   features: {string}
   rules: {string: KillSwitchRule}
end

kill_switches_config.features = {
   "login",
   "register",
   "checkout",
   "topup",
   "cart",
   "payment",
   "events_ws",
}

kill_switches_config.rules = {
   login = {
      feature = "login",
      default_message_key = "MAINTENANCE_LOGIN",
      default_retry_after = 60,
   },
   register = {
      feature = "register",
      default_message_key = "MAINTENANCE_REGISTER",
      default_retry_after = 60,
   },
   checkout = {
      feature = "checkout",
      default_message_key = "MAINTENANCE_CHECKOUT",
      default_retry_after = 60,
   },
   topup = {
      feature = "topup",
      default_message_key = "MAINTENANCE_TOPUP",
      default_retry_after = 60,
   },
   cart = {
      feature = "cart",
      default_message_key = "MAINTENANCE_CART",
      default_retry_after = 60,
   },
   payment = {
      feature = "payment",
      default_message_key = "MAINTENANCE_PAYMENT",
      default_retry_after = 60,
   },
   events_ws = {
      feature = "events_ws",
      default_message_key = "MAINTENANCE_EVENTS",
      default_retry_after = 60,
   },
}

function kill_switches_config.find(feature: string): KillSwitchRule
   if feature == nil or feature == "" then
      return nil
   end

   return kill_switches_config.rules[string.lower(feature)]
end

return kill_switches_config
