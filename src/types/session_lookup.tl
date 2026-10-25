local type Session = require("types.session")
local type SessionState = require("types.session_state")

local record SessionLookup
   state: SessionState
   key: string
   session: Session
end

return SessionLookup
