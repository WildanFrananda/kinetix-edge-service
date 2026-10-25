local cjson = require("cjson.safe")
local clock = require("adapters.clock")

local record logger
   type Fields = {string: string | number | boolean}
end

local function write(level: string, event: string, fields: logger.Fields)
   local entry: logger.Fields = {}
   for key, value in pairs(fields) do
      entry[key] = value
   end

   entry["time"] = clock.iso8601(clock.now_ms())
   entry["level"] = level
   entry["event"] = event
   entry["service"] = "kinetix-edge-service"

   local line = cjson.encode(entry)
   if line ~= nil then
      io.stderr:write(line, "\n")
   end
end

function logger.info(event: string, fields: logger.Fields)
   write("info", event, fields)
end

function logger.warn(event: string, fields: logger.Fields)
   write("warn", event, fields)
end

function logger.error(event: string, fields: logger.Fields)
   write("error", event, fields)
end

return logger
