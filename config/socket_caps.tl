local record socket_caps_config
   max_sockets_by_role: {string: integer}
   default_max: integer
   slot_ttl_ms: integer
   renew_interval_ms: integer
end

socket_caps_config.max_sockets_by_role = {
   customer = 3,
   buyer = 3,
   seller = 5,
   merchant = 5,
   courier = 2,
   driver = 2,
   admin = 5,
   staff = 5,
}

socket_caps_config.default_max = 3
socket_caps_config.slot_ttl_ms = 180000
socket_caps_config.renew_interval_ms = 60000

function socket_caps_config.limit_for_role(role: string): integer
   if role == nil or role == "" then
      return socket_caps_config.default_max
   end

   return socket_caps_config.max_sockets_by_role[string.lower(role)] or socket_caps_config.default_max
end

return socket_caps_config
