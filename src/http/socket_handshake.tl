local base64 = require("ngx.base64")
local http = require("resty.http")

local record socket_handshake
   subprotocol: string
   token_prefix: string
end

socket_handshake.subprotocol = "phoenix"
socket_handshake.token_prefix = "base64url.bearer.phx."

local function joined(headers: {string: http.HeaderValue}, name: string): string
   local value = headers[name]
   if value == nil or value is string then
      return value as string
   end

   return table.concat(value, ",")
end

local function entries(value: string): {string}
   local found: {string} = {}
   if value == nil then
      return found
   end

   for item in string.gmatch(value, "[^,]+") do
      local trimmed = string.match(item, "^%s*(.-)%s*$")
      if trimmed ~= "" then
         table.insert(found, trimmed)
      end
   end

   return found
end

local function lists(value: string, wanted: string): boolean
   for _, entry in ipairs(entries(value)) do
      if entry == wanted then
         return true
      end
   end

   return false
end

function socket_handshake.is_upgrade(headers: {string: http.HeaderValue}): boolean
   local upgrade = headers["upgrade"]
   if not upgrade is string or string.lower(upgrade) ~= "websocket" then
      return false
   end

   if not lists(string.lower(joined(headers, "connection") or ""), "upgrade") then
      return false
   end

   local key = headers["sec-websocket-key"]
   local version = headers["sec-websocket-version"]

   return key is string and #key > 0 and version is string and version == "13"
end

function socket_handshake.offers_phoenix(headers: {string: http.HeaderValue}): boolean
   return lists(joined(headers, "sec-websocket-protocol"), socket_handshake.subprotocol)
end

function socket_handshake.protocols_for(access_token: string): string
   return socket_handshake.subprotocol .. ", " .. socket_handshake.token_prefix .. base64.encode_base64url(access_token)
end

function socket_handshake.upstream_host(base_url: string): string
   local authority = string.match(base_url, "^http://(.+)$")

   return (string.gsub(authority, ":80$", ""))
end

return socket_handshake
