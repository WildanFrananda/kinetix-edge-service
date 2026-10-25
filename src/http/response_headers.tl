local record response_headers
end

function response_headers.filter()
   ngx.header["Cache-Control"] = "no-store"
end

return response_headers
