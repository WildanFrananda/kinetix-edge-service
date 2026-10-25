local record forwarding
   methods: {string}
   request_headers: {string}
   dropped_response_headers: {string}
   refused_paths: {string}
   identity_paths: {string}
end

forwarding.methods = { "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE" }

forwarding.request_headers = {
   "accept",
   "accept-language",
   "content-type",
   "idempotency-key",
   "if-match",
   "if-none-match",
   "user-agent",
}

forwarding.dropped_response_headers = {
   "set-cookie",
   "set-cookie2",
   "connection",
   "keep-alive",
   "proxy-authenticate",
   "proxy-connection",
   "te",
   "trailer",
   "transfer-encoding",
   "upgrade",
   "content-length",
   "server",
   "x-powered-by",
   "cache-control",
   "expires",
   "pragma",
}

forwarding.refused_paths = {
   "/api/v1/auth/login",
   "/api/v1/auth/register",
   "/api/v1/auth/refresh",
   "/api/v1/auth/logout",
   "/api/v1/auth/2fa/verify",
   "/api/v1/couriers/register",
}

forwarding.identity_paths = { "/api/v1/auth", "/api/v1/couriers" }

return forwarding
