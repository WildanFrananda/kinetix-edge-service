local check = require("tests.support.check")
local host_aliases = require("adapters.host_aliases")

describe("host_aliases", function()
   it("parses IPv4 entries from a hosts file and skips comments and IPv6 lines", function()
      local sample = table.concat({
         "# Docker extra_hosts",
         "127.0.0.1\tlocalhost",
         "::1\tlocalhost ip6-localhost",
         "10.43.252.59\tkinetix-api-gateway gateway.alias # cluster vip",
         "10.43.252.99\tkinetix-api-gateway",
         "invalid-ip-line some-host",
      }, "\n")

      local parsed = host_aliases.parse(sample)

      check.equal(parsed["localhost"], "127.0.0.1", "IPv4 entry kept ahead of ::1")
      check.equal(parsed["kinetix-api-gateway"], "10.43.252.59", "first matching IPv4 entry wins")
      check.equal(parsed["gateway.alias"], "10.43.252.59", "secondary alias on same line")
      check.absent(parsed["ip6-localhost"], "IPv6 aliases skipped for ipv6=off")
      check.absent(parsed["some-host"], "malformed address ignored")
   end)

   it("returns an empty map when a hosts file does not exist", function()
      local missing = host_aliases.read("/nonexistent-hosts-path-kinetix")

      check.absent(missing["kinetix-api-gateway"], "missing file yields empty table")
   end)

   it("rewrites aliased hosts to their IPv4 address while preserving the original Host authority", function()
      local aliases = { ["kinetix-api-gateway"] = "10.43.252.59" }

      local url, host = host_aliases.resolve_url("http://kinetix-api-gateway:8000/api/v1/products?q=kb", aliases)
      check.equal(url, "http://10.43.252.59:8000/api/v1/products?q=kb", "connect URL rewritten")
      check.equal(host, "kinetix-api-gateway:8000", "non-default port kept in Host")

      local default_url, default_host = host_aliases.resolve_url("http://Kinetix-API-Gateway:80/api/ping", aliases)
      check.equal(default_url, "http://10.43.252.59:80/api/ping", "case-insensitive host lookup")
      check.equal(default_host, "Kinetix-API-Gateway", "default :80 port omitted from Host")

      local plain_url, plain_host = host_aliases.resolve_url("http://kinetix-api-gateway", aliases)
      check.equal(plain_url, "http://10.43.252.59", "bare base URL rewritten")
      check.equal(plain_host, "kinetix-api-gateway", "bare Host preserved")
   end)

   it("leaves unaliased hosts and IP literals untouched", function()
      local aliases = { ["kinetix-api-gateway"] = "10.43.252.59" }

      local direct_url, direct_host = host_aliases.resolve_url("http://kinetix-identity-service:5000/health", aliases)
      check.equal(direct_url, "http://kinetix-identity-service:5000/health", "Docker DNS host unchanged")
      check.absent(direct_host, "no Host override returned")

      local ip_url, ip_host = host_aliases.resolve_url("http://127.0.0.1:18002/api/v1/ping", aliases)
      check.equal(ip_url, "http://127.0.0.1:18002/api/v1/ping", "IP literal unchanged")
      check.absent(ip_host, "no Host override for literal")
   end)
end)
