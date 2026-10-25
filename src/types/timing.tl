local record Timing
   refresh_before_ms: integer
   refresh_lock_ms: integer
   refresh_wait_ms: integer
   refresh_poll_seconds: number
   pending_max_seconds: integer
   redis_timeout_ms: integer
   redis_keepalive_ms: integer
   redis_pool_size: integer
   identity_connect_ms: integer
   identity_send_ms: integer
   identity_read_ms: integer
   api_connect_ms: integer
   api_send_ms: integer
   api_read_ms: integer
   upstream_keepalive_ms: integer
   upstream_pool_size: integer
end

return Timing
