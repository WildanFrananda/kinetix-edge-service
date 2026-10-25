local record cookies
   session_name: string
   pending_name: string
end

cookies.session_name = "__Host-kx_session"
cookies.pending_name = "__Host-kx_pending"

local ATTRIBUTES = "Path=/; Secure; HttpOnly; SameSite=Strict"

local function trimmed(value: string): string
   return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

function cookies.is_value(value: string): boolean
   return value ~= nil and #value == 43 and string.match(value, "^[%w%-_]+$") ~= nil
end

function cookies.read(header: string, name: string): string
   if header == nil then
      return nil
   end

   local found: string = nil
   local seen = 0
   for pair in string.gmatch(header, "[^;]+") do
      local separator = string.find(pair, "=", 1, true)
      if separator ~= nil and trimmed(string.sub(pair, 1, separator - 1)) == name then
         seen = seen + 1
         found = trimmed(string.sub(pair, separator + 1))
      end
   end

   if seen ~= 1 or not cookies.is_value(found) then
      return nil
   end

   return found
end

function cookies.session(value: string, max_age_seconds: integer): string
   local cookie = cookies.session_name .. "=" .. value .. "; " .. ATTRIBUTES
   if max_age_seconds ~= nil then
      return cookie .. "; Max-Age=" .. string.format("%d", max_age_seconds)
   end

   return cookie
end

function cookies.pending(value: string, max_age_seconds: integer): string
   local max_age = string.format("%d", max_age_seconds)

   return cookies.pending_name .. "=" .. value .. "; " .. ATTRIBUTES .. "; Max-Age=" .. max_age
end

function cookies.expired(name: string): string
   return name .. "=; " .. ATTRIBUTES .. "; Max-Age=0"
end

return cookies
