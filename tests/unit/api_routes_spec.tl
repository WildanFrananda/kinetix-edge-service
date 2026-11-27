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
      check.falsy(login.require_auth, "login is public")

      local logout = api_routes.match("/api/v1/auth/logout")
      check.present(logout, "logout matched")
      check.truthy(logout.require_auth, "logout requires auth")

      local passkey_verify = api_routes.match("/api/v1/auth/2fa/passkey/verify")
      check.present(passkey_verify, "passkey verify matched")
      check.falsy(passkey_verify.require_auth, "passkey verify stays public")

      local setup_2fa = api_routes.match("/api/v1/auth/2fa/setup/42")
      check.present(setup_2fa, "2fa setup matched")
      check.falsy(setup_2fa.require_auth, "2fa setup lets identity check enrolment bearer")
      check.equal(setup_2fa.rate_limit_group, "auth_public", "2fa setup keeps rate limit")

      local enable_2fa = api_routes.match("/api/v1/auth/2fa/enable/42")
      check.present(enable_2fa, "2fa enable matched")
      check.falsy(enable_2fa.require_auth, "2fa enable lets identity check enrolment bearer")
      check.equal(enable_2fa.rate_limit_group, "auth_public", "2fa enable keeps rate limit")

      local disable_2fa = api_routes.match("/api/v1/auth/2fa/disable/42")
      check.present(disable_2fa, "2fa disable matched")
      check.truthy(disable_2fa.require_auth, "2fa disable still requires access token")

      local courier_apps = api_routes.match("/api/v1/couriers/applications")
      check.present(courier_apps, "courier apps matched")
      check.truthy(courier_apps.require_auth, "courier apps require auth")
      check.equal(courier_apps.allowed_roles[1], "admin", "courier apps require admin")

      local midtrans = api_routes.match("/api/v1/payment/gateway/midtrans/notifications")
      check.present(midtrans, "webhook matched")
      check.present(midtrans.allowed_cidrs, "webhook configures Midtrans CIDRs")

      check.absent(api_routes.match("/api/v1/products"), "unlisted API prefix not matched")
   end)
end)
