local metrics = require("adapters.metrics")
local settings = require("http.settings")

local record metrics_endpoint
end

function metrics_endpoint.serve()
   ngx.header["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"
   ngx.print(metrics.render("kinetix-edge-service", settings.current.environment.service_version))
end

return metrics_endpoint
