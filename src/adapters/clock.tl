local record clock
end

function clock.now_ms(): integer
   ngx.update_time()

   return math.floor(ngx.now() * 1000)
end

function clock.iso8601(ms: integer): string
   local seconds = math.floor(ms / 1000)
   local millis = ms - seconds * 1000

   return os.date("!%Y-%m-%dT%H:%M:%S", seconds) .. string.format(".%03dZ", millis)
end

return clock
