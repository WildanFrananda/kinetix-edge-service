local type CsrfRefusal = require("types.csrf_refusal")

local record csrf
end

local SAFE_METHODS: {string: boolean} = { ["GET"] = true, ["HEAD"] = true }

function csrf.changes_state(method: string): boolean
   return not SAFE_METHODS[method]
end

function csrf.refusal(method: string, origin: string, fetch_site: string, app_origin: string): CsrfRefusal
   if not csrf.changes_state(method) then
      return nil
   end

   if origin ~= nil then
      if origin == app_origin then
         return nil
      end

      return "origin"
   end

   if fetch_site == "same-origin" then
      return nil
   end

   return "fetch_site"
end

function csrf.is_json(content_type: string): boolean
   if content_type == nil then
      return false
   end

   local media = string.lower((string.gsub(content_type, ";.*$", "")))
   local bare = string.gsub(media, "%s", "")

   return bare == "application/json"
end

return csrf
