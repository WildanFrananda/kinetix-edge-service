local forwarding = require("config.forwarding")

local record api_path
   prefix: string
end

api_path.prefix = "/bff/api"

function api_path.normalize(rest: string): string
   if rest == nil then
      return nil
   end

   local segments: {string} = {}
   for segment in string.gmatch(rest, "[^/]+") do
      if segment == "." or segment == ".." then
         return nil
      end

      table.insert(segments, ngx.escape_uri(segment))
   end

   local path = "/" .. table.concat(segments, "/")
   if string.sub(rest, -1) == "/" and #segments > 0 then
      return path .. "/"
   end

   return path
end

function api_path.upstream(uri: string): string
   if string.sub(uri, 1, #api_path.prefix + 1) ~= api_path.prefix .. "/" then
      return nil
   end

   local normalized = api_path.normalize(string.sub(uri, #api_path.prefix + 1))
   if normalized == nil then
      return nil
   end

   return "/api" .. normalized
end

local function under_any(path: string, prefixes: {string}): boolean
   local lowered = string.lower(path)
   for _, prefix in ipairs(prefixes) do
      if lowered == prefix or string.sub(lowered, 1, #prefix + 1) == prefix .. "/" then
         return true
      end
   end

   return false
end

function api_path.is_refused(path: string): boolean
   return under_any(path, forwarding.refused_paths)
end

function api_path.is_identity(path: string): boolean
   return under_any(path, forwarding.identity_paths)
end

function api_path.needs_face(path: string): boolean
   return under_any(path, forwarding.face_paths)
end

return api_path
