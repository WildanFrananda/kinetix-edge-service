local record response_headers
end

function response_headers.filter()
   ngx.header["Cache-Control"] = "no-store"
   ngx.header["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
   ngx.header["X-Content-Type-Options"] = "nosniff"
   ngx.header["X-Frame-Options"] = "DENY"
   ngx.header["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
   ngx.header["Referrer-Policy"] = "no-referrer"
   ngx.header["X-Powered-By"] = nil
end

return response_headers
