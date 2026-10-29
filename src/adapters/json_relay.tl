local cjson = require("cjson.safe")

local record json_relay
end

local codec = cjson.new()
codec.decode_array_with_array_mt(true)
codec.decode_invalid_numbers(false)
codec.encode_escape_forward_slash(false)

function json_relay.document(text: string): cjson.Document
   if text == nil or text == "" then
      return nil
   end

   local decoded = codec.decode(text)
   if decoded is cjson.Document and getmetatable(decoded) == nil then
      return decoded
   end

   return nil
end

function json_relay.object(document: cjson.Document, name: string): cjson.Object
   if document == nil then
      return nil
   end

   local value = document[name]
   if value is cjson.Object and getmetatable(value) == nil then
      return value
   end

   return nil
end

function json_relay.encode<T>(value: T): string
   local text = codec.encode(value)

   return text
end

return json_relay
