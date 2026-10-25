local cjson = require("cjson.safe")

local record api
end

function api.serve()
   local uri = ngx.var.uri
   if uri == "/api/v1/fake/close" then
      return ngx.exit(444)
   end

   local headers = ngx.req.get_headers(100, false)
   local flat: {string: string} = {}
   for key, value in pairs(headers) do
      if value is string then
         flat[key] = value
      else
         flat[key] = table.concat(value, ", ")
      end
   end

   ngx.req.read_body()

   local status = tonumber(string.match(uri, "^/api/v1/fake/status/(%d%d%d)$")) or 200
   ngx.status = math.floor(status)
   ngx.header["Content-Type"] = "application/json"
   ngx.header["Set-Cookie"] = { "upstream=1; Path=/", "tracker=2; Path=/; HttpOnly" }
   ngx.header["Cache-Control"] = "public, max-age=600"
   ngx.header["X-Upstream"] = "fake-api"
   ngx.header["X-Powered-By"] = "fake"
   local echoed = cjson.encode({
      method = ngx.req.get_method(),
      path = uri,
      query = ngx.var.args or "",
      body = ngx.req.get_body_data() or "",
      headers = flat,
   })
   ngx.print(echoed)
end

return api
