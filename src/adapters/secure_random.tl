local base64 = require("ngx.base64")
local random = require("resty.random")
local resty_string = require("resty.string")

local record secure_random
end

local SESSION_BYTES = 32

function secure_random.session_value(): string
   local bytes = random.bytes(SESSION_BYTES, true)
   if bytes == nil or #bytes ~= SESSION_BYTES then
      return nil
   end

   return base64.encode_base64url(bytes)
end

function secure_random.hex(count: integer): string
   local bytes = random.bytes(count, true)
   if bytes == nil or #bytes ~= count then
      return nil
   end

   return resty_string.to_hex(bytes)
end

return secure_random
