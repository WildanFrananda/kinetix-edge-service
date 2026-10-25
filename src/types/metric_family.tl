local type MetricKind = require("types.metric_kind")

local record MetricFamily
   name: string
   help: string
   kind: MetricKind
end

return MetricFamily
