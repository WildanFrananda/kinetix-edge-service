local check = require("tests.support.check")
local http = require("resty.http")
local socket_handshake = require("http.socket_handshake")

local function upgrade(): {string: http.HeaderValue}
   return {
      ["upgrade"] = "websocket",
      ["connection"] = "keep-alive, Upgrade",
      ["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==",
      ["sec-websocket-version"] = "13",
   }
end

describe("socket_handshake", function()
   it("recognises a WebSocket upgrade and nothing less", function()
      check.truthy(socket_handshake.is_upgrade(upgrade()), "a browser's upgrade")

      local split = upgrade()
      split["connection"] = { "keep-alive", "Upgrade" }
      check.truthy(socket_handshake.is_upgrade(split), "Connection sent twice")

      for _, name in ipairs({ "upgrade", "connection", "sec-websocket-key", "sec-websocket-version" }) do
         local missing = upgrade()
         missing[name] = nil
         check.falsy(socket_handshake.is_upgrade(missing), "without " .. name)
      end

      local other = upgrade()
      other["upgrade"] = "h2c"
      check.falsy(socket_handshake.is_upgrade(other), "another protocol")

      local old = upgrade()
      old["sec-websocket-version"] = "8"
      check.falsy(socket_handshake.is_upgrade(old), "an old version")

      local lookalike = upgrade()
      lookalike["connection"] = "upgraded"
      check.falsy(socket_handshake.is_upgrade(lookalike), "a token that only contains upgrade")
   end)

   it("answers phoenix only to a browser that offered it", function()
      check.truthy(socket_handshake.offers_phoenix({ ["sec-websocket-protocol"] = "phoenix" }), "alone")
      check.truthy(
         socket_handshake.offers_phoenix({ ["sec-websocket-protocol"] = "chat ,phoenix, base64url.bearer.phx.eA" }),
         "among others"
      )
      check.truthy(socket_handshake.offers_phoenix({ ["sec-websocket-protocol"] = { "chat", "phoenix" } }), "twice")
      check.falsy(socket_handshake.offers_phoenix({ ["sec-websocket-protocol"] = "phoenixes" }), "a longer word")
      check.falsy(socket_handshake.offers_phoenix({}), "none")
   end)

   it("puts the access token in Phoenix's bearer subprotocol, base64url without padding", function()
      check.equal(socket_handshake.protocols_for("a.b"), "phoenix, base64url.bearer.phx.YS5i", "three bytes")
      check.equal(socket_handshake.protocols_for("ab"), "phoenix, base64url.bearer.phx.YWI", "no padding")
   end)

   it("names the upstream's own host, as the API forwarder sends it", function()
      check.equal(socket_handshake.upstream_host("http://kinetix-api-gateway:8000"), "kinetix-api-gateway:8000", "port")
      check.equal(socket_handshake.upstream_host("http://kinetix-api-gateway"), "kinetix-api-gateway", "no port")
      check.equal(socket_handshake.upstream_host("http://kinetix-api-gateway:80"), "kinetix-api-gateway", "default")
   end)
end)
