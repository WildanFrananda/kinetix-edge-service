local record RateLimitRule
   name: string
   max_requests: integer
   window_ms: integer
   key_scope: string
end

return RateLimitRule
