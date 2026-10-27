local record scenario
   edge_url: string
   socket_url: string
   metrics_url: string
   identity_url: string
   api_url: string
   hosts: {string: string}
   browser_address: string
   forwarded_for: string
   password: string
   code: string
   version: string
end

scenario.edge_url = "http://127.0.0.1:8080"
scenario.socket_url = "ws://127.0.0.1:8080"
scenario.metrics_url = "http://127.0.0.1:9145"
scenario.identity_url = "http://127.0.0.1:18001"
scenario.api_url = "http://127.0.0.1:18002"
scenario.hosts = { ["backoffice"] = "backoffice.localhost:8443", ["seller-web"] = "seller.localhost:8443" }
scenario.browser_address = "198.51.100.23"
scenario.forwarded_for = "203.0.113.7, 198.51.100.23"
scenario.password = "correct-password"
scenario.code = "123456"
scenario.version = "itest-0123abc"

function scenario.origin(app: string): string
   return "https://" .. scenario.hosts[app]
end

return scenario
