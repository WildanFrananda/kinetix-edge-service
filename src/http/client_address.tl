local record client_address
end

local function trimmed(value: string): string
   return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function is_ipv4(value: string): boolean
   local a, b, c, d = string.match(value, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
   if a == nil then
      return false
   end

   for _, part in ipairs({ a, b, c, d }) do
      if #part > 3 or tonumber(part) > 255 then
         return false
      end
   end

   return true
end

local function is_ipv6(value: string): boolean
   return #value <= 45 and string.find(value, ":", 1, true) ~= nil and string.match(value, "^[%x:%.]+$") ~= nil
end

function client_address.from_forwarded_for(header: string): string
   if header == nil then
      return nil
   end

   local last: string = nil
   for entry in string.gmatch(header, "[^,]+") do
      last = entry
   end

   if last == nil then
      return nil
   end

   local address = trimmed(last)
   if is_ipv4(address) or is_ipv6(address) then
      return address
   end

   return nil
end

return client_address
