local record client
   record Options
      protocols: {string}
      origin: string
      host: string
      headers: {string}
      timeout: integer
   end

   record Connection
      connect: function(Connection, string, Options): integer, string, string
      recv_frame: function(Connection): string, string, string
      send_text: function(Connection, string): integer, string
      send_close: function(Connection): integer, string
      close: function(Connection): integer, string
   end

   new: function(client, Options): Connection, string
end

return client
