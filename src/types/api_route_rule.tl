local record ApiRouteRule
   name: string
   prefix: string
   exact: boolean
   methods: {string}
   target: string
   max_body_bytes: integer
   require_json: boolean
   require_idempotency: boolean
   strip_client_header: boolean
end

return ApiRouteRule
