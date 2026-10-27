local record server
   record Options
      timeout: integer
      max_payload_len: integer
   end

   record Connection
      recv_frame: function(Connection): string, string, string
      send_text: function(Connection, string): integer, string
      send_close: function(Connection): integer, string
   end

   new: function(server, Options): Connection, string
end

return server
