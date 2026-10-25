local resty_string = require("resty.string")
local sha256 = require("resty.sha256")

local record digest
end

function digest.sha256_hex(value: string): string
   local hasher = sha256.new()
   hasher:update(value)

   return resty_string.to_hex(hasher:final())
end

return digest
