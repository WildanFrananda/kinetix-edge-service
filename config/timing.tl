local type Timing = require("types.timing")

local timing: Timing = {
   refresh_before_ms = 60000,
   refresh_lock_ms = 15000,
   refresh_wait_ms = 9000,
   refresh_poll_seconds = 0.025,
   pending_max_seconds = 600,
   redis_timeout_ms = 1000,
   redis_keepalive_ms = 60000,
   redis_pool_size = 64,
   identity_connect_ms = 1000,
   identity_send_ms = 2000,
   identity_read_ms = 5000,
   api_connect_ms = 2000,
   api_send_ms = 30000,
   api_read_ms = 60000,
   upstream_keepalive_ms = 60000,
   upstream_pool_size = 64,
}

return timing
