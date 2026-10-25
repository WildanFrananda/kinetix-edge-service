local cjson = require("cjson.safe")
local context = require("http.context")
local type RequestContext = require("types.request_context")

local record json_body
end

function json_body.is_present(request: RequestContext): boolean
   local length = context.single(request.headers, "content-length")
   if length ~= nil and length ~= "0" then
      return true
   end

   return request.headers["transfer-encoding"] ~= nil
end

function json_body.raw(): string
   ngx.req.read_body()

   local data = ngx.req.get_body_data()
   if data == nil and ngx.req.get_body_file() ~= nil then
      return nil
   end

   return data or ""
end

function json_body.object(): cjson.Document
   local raw = json_body.raw()
   if raw == nil or raw == "" then
      return nil
   end

   local decoded = cjson.decode(raw)
   if decoded is cjson.Document and #(decoded as {cjson.Field}) == 0 then
      return decoded
   end

   return nil
end

function json_body.text(document: cjson.Document, name: string, longest: integer): string
   if document == nil then
      return nil
   end

   local value = document[name]
   if value is string and #value > 0 and #value <= longest then
      return value
   end

   return nil
end

return json_body
