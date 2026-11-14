local record host_aliases
end

local function trim(value: string): string
   return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

function host_aliases.parse(contents: string): {string: string}
   local aliases: {string: string} = {}
   if contents == nil then
      return aliases
   end

   for line in string.gmatch(contents, "[^\r\n]+") do
      local stripped = string.gsub(line, "#.*$", "")
      local address, names = string.match(trim(stripped), "^(%d+%.%d+%.%d+%.%d+)%s+(.+)$")
      if address ~= nil and names ~= nil then
         for name in string.gmatch(names, "%S+") do
            local key = string.lower(name)
            if aliases[key] == nil then
               aliases[key] = address
            end
         end
      end
   end

   return aliases
end

function host_aliases.read(path?: string): {string: string}
   local target = path or "/etc/hosts"
   local handle = io.open(target, "r")
   if handle == nil then
      return {}
   end

   local contents = handle:read("*a")
   handle:close()
   return host_aliases.parse(contents)
end

local function is_default_port(scheme: string, port_part: string): boolean
   return (scheme == "http://" and port_part == ":80")
      or (scheme == "https://" and port_part == ":443")
end

function host_aliases.resolve_url(url: string, aliases: {string: string}): string, string
   if aliases == nil then
      return url, nil
   end

   local scheme, host, rest = string.match(url, "^(https?://)([^/:?#]+)(.*)$")
   if scheme == nil or host == nil then
      return url, nil
   end

   local address = aliases[string.lower(host)]
   if address == nil then
      return url, nil
   end

   local port_part = string.match(rest or "", "^(:%d+)")
   local host_header = host
   if port_part ~= nil and not is_default_port(scheme, port_part) then
      host_header = host .. port_part
   end

   return scheme .. address .. (rest or ""), host_header
end

return host_aliases
