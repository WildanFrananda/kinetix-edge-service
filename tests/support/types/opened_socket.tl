local websocket_client = require("resty.websocket.client")

local record OpenedSocket
   status: integer
   headers: {string: string}
   raw: string
   connection: websocket_client.Connection
end

return OpenedSocket
