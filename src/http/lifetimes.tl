local type AppPolicy = require("types.app_policy")
local type Session = require("types.session")

local record lifetimes
end

function lifetimes.absolute_end(app: AppPolicy, now_ms: integer): integer
   return now_ms + app.absolute_seconds * 1000
end

function lifetimes.idle_ttl_ms(app: AppPolicy, absolute_end: integer, now_ms: integer): integer
   local idle = app.idle_seconds * 1000
   local remaining = absolute_end - now_ms
   if remaining < idle then
      return remaining
   end

   return idle
end

function lifetimes.is_past_absolute(session: Session, now_ms: integer): boolean
   return now_ms >= session.absolute_end
end

function lifetimes.needs_refresh(session: Session, now_ms: integer, before_ms: integer): boolean
   return session.access_expires_at - now_ms < before_ms
end

function lifetimes.ends_at(app: AppPolicy, session: Session): integer
   local idle_end = session.last_seen + app.idle_seconds * 1000
   if idle_end < session.absolute_end then
      return idle_end
   end

   return session.absolute_end
end

function lifetimes.cookie_max_age(app: AppPolicy): integer
   if app.persistent_cookie then
      return app.absolute_seconds
   end

   return nil
end

return lifetimes
