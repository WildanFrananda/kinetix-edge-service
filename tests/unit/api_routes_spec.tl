local api_routes = require("config.api_routes")
local check = require("tests.support.check")

describe("api_routes", function()
   it("matches specific checkout and payment routes before prefixes", function()
      local checkout = api_routes.match("/api/v1/orders/checkout")
      check.present(checkout, "checkout matched")
      check.equal(checkout.name, "/api/v1/orders/checkout", "checkout template")
      check.truthy(checkout.require_idempotency, "checkout requires idempotency")

      local order_detail = api_routes.match("/api/v1/orders/ORD-123")
      check.present(order_detail, "order prefix matched")
      check.equal(order_detail.name, "/api/v1/orders/{path}", "order template")
      check.falsy(order_detail.require_idempotency, "order GET does not require idempotency")

      local topup = api_routes.match("/api/v1/payment/wallet/customer/topup")
      check.present(topup, "topup matched")
      check.truthy(topup.require_idempotency, "topup requires idempotency")

      local webhook = api_routes.match("/api/v1/payment/gateway/midtrans/notifications")
      check.present(webhook, "midtrans webhook matched")
      check.falsy(webhook.require_idempotency, "webhook does not require idempotency")
   end)

   it("routes identity paths to identity and ignores unconfigured prefixes", function()
      local login = api_routes.match("/api/v1/auth/login")
      check.present(login, "login matched")
      check.equal(login.target, "identity", "identity target")
      check.falsy(login.strip_client_header, "keeps client header for identity")

      check.absent(api_routes.match("/api/v1/products"), "unlisted API prefix not matched")
   end)
end)
