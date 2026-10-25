local type AppName = require("types.app_name")

local record Session
   access_token: string
   refresh_token: string
   access_expires_at: integer
   app: AppName
   role: string
   principal_id: string
   created_at: integer
   last_seen: integer
   absolute_end: integer
end

return Session
