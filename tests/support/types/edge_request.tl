local record EdgeRequest
   app: string
   host: string
   cookie: string
   origin: string
   omit_origin: boolean
   fetch_site: string
   content_type: string
   body: string
   headers: {string: string}
   request_id: string
   forwarded_for: string
   omit_forwarded_for: boolean
end

return EdgeRequest
