local cjson = require("cjson.safe")
local event_protocol = require("http.event_protocol")
local type PrincipalClass = require("types.principal_class")

local record principal
end

local ROLE_MAP: {string: PrincipalClass} = {
   ["customer"] = "buyer",
   ["buyer"] = "buyer",
   ["seller"] = "seller",
   ["courier"] = "courier",
   ["admin"] = "admin",
}

local function decode_base64url(segment: string): string
   if segment == nil or segment == "" then
      return nil
   end

   local padded = string.gsub(string.gsub(segment, "-", "+"), "_", "/")
   local rem = #padded % 4
   if rem == 2 then
      padded = padded .. "=="
   elseif rem == 3 then
      padded = padded .. "="
   elseif rem == 1 then
      return nil
   end

   return ngx.decode_base64(padded)
end

function principal.class_of_role(role: string): PrincipalClass
   if role == nil or role == "" then
      return "anonymous"
   end

   return ROLE_MAP[string.lower(role)] or "anonymous"
end

function principal.class_from_bearer(authorization: string): PrincipalClass
   local token = event_protocol.bearer_token(authorization)
   if token == nil then
      return "anonymous"
   end

   local _, payload = string.match(token, "^([^%.]+)%.([^%.]+)%.[^%.]+$")
   if payload == nil then
      return "anonymous"
   end

   local raw_json = decode_base64url(payload)
   if raw_json == nil then
      return "anonymous"
   end

   local decoded = cjson.decode(raw_json)
   if not (decoded is cjson.Document) then
      return "anonymous"
   end

   local role = decoded["role"]
   if not (role is string) then
      return "anonymous"
   end

   return principal.class_of_role(role)
end

return principal
