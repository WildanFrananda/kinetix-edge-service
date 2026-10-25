local forwarding = require("config.forwarding")

local record api_path
   prefix: string
end

api_path.prefix = "/bff/api"

function api_path.upstream(uri: string): string
   if string.sub(uri, 1, #api_path.prefix + 1) ~= api_path.prefix .. "/" then
      return nil
   end

   local rest = string.sub(uri, #api_path.prefix + 1)
   local segments: {string} = {}
   for segment in string.gmatch(rest, "[^/]+") do
      if segment == "." or segment == ".." then
         return nil
      end

      table.insert(segments, ngx.escape_uri(segment))
   end

   local path = "/api/" .. table.concat(segments, "/")
   if string.sub(rest, -1) == "/" and #segments > 0 then
      return path .. "/"
   end

   return path
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

return api_path
