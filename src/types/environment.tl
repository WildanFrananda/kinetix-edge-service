local record Environment
   redis_host: string
   redis_port: integer
   redis_user: string
   redis_password: string
   identity_url: string
   api_upstream: string
   backoffice_origins: {string}
   seller_host: string
   service_version: string
end

return Environment
