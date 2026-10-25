local record http
   type HeaderValue = string | {string}

   record Params
      method: string
      body: string
      headers: {string: string}
      keepalive_timeout: integer
      keepalive_pool: integer
   end

   record Response
      status: integer
      headers: {string: HeaderValue}
      body: string
   end

   record Client
      set_timeouts: function(Client, integer, integer, integer)
      request_uri: function(Client, string, Params): Response, string
   end

   new: function(): Client, string
end

return http
