local type AppName = require("types.app_name")

local record AppPolicy
   name: AppName
   client: string
   host: string
   hostname: string
   origin: string
   roles: {string}
   enrolment: boolean
   sign_up: boolean
   passkeys: boolean
   merchant_socket_roles: {string}
   persistent_cookie: boolean
   idle_seconds: integer
   absolute_seconds: integer
end

return AppPolicy
