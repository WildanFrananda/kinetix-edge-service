local type AppName = require("types.app_name")
local type PendingKind = require("types.pending_kind")

local record PendingSignIn
   kind: PendingKind
   token: string
   app: AppName
   user_id: integer
end

return PendingSignIn
