local record RateLimitResult
   ok: boolean
   unavailable: boolean
   reason: string
   error_code: string
   retry_after: string
end

return RateLimitResult
