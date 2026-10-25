local record request_id
end

function request_id.accepted(value: string): string
   if value == nil or #value == 0 or #value > 128 then
      return nil
   end

   if string.match(value, "^[%w%.%-_:#@]+$") == nil then
      return nil
   end

   return value
end

return request_id
