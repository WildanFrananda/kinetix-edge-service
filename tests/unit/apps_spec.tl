local apps = require("config.apps")
local check = require("tests.support.check")

describe("config.apps", function()
   local policies = apps.policies({
      redis_host = "r",
      redis_port = 6379,
      redis_user = "edge",
      redis_password = "p",
      identity_url = "http://i:5000",
      api_upstream = "http://g:8000",
      backoffice_host = "Backoffice.Example.Test",
      seller_host = "seller.example.test:8443",
      service_version = "v",
   })

   it("keeps the backoffice strict: admins only, 15 min idle, 8 h absolute, a browser-session cookie", function()
      local backoffice = policies[1]
      check.equal(backoffice.name, "backoffice", "name")
      check.equal(backoffice.client, "backoffice", "client name sent to identity")
      check.equal(backoffice.host, "backoffice.example.test", "host lowered")
      check.equal(backoffice.hostname, "backoffice.example.test", "host name")
      check.equal(backoffice.origin, "https://backoffice.example.test", "origin")
      check.equal(#backoffice.roles, 1, "one role")
      check.equal(backoffice.roles[1], "admin", "admin")
      check.truthy(backoffice.enrolment, "admins enrol here")
      check.falsy(backoffice.sign_up, "no sign-up")
      check.equal(#backoffice.merchant_socket_roles, 0, "no merchant socket")
      check.falsy(backoffice.persistent_cookie, "browser-session cookie")
      check.equal(backoffice.idle_seconds, 900, "idle")
      check.equal(backoffice.absolute_seconds, 28800, "absolute")
   end)

   it("keeps the seller web lenient: sellers and applicants, 7 days idle, 30 days absolute", function()
      local seller = policies[2]
      check.equal(seller.name, "seller-web", "name")
      check.equal(seller.client, "seller-web", "client name sent to identity")
      check.equal(seller.origin, "https://seller.example.test:8443", "origin with port")
      check.equal(seller.hostname, "seller.example.test", "host name without the port")
      check.equal(seller.roles[1], "seller", "seller")
      check.equal(seller.roles[2], "customer", "applicant")
      check.equal(#seller.roles, 2, "two roles")
      check.falsy(seller.enrolment, "no enrolment here")
      check.truthy(seller.sign_up, "sign-up")
      check.equal(#seller.merchant_socket_roles, 1, "one role opens the merchant socket")
      check.equal(seller.merchant_socket_roles[1], "seller", "the seller")
      check.truthy(seller.persistent_cookie, "kept across restarts")
      check.equal(seller.idle_seconds, 604800, "idle")
      check.equal(seller.absolute_seconds, 2592000, "absolute")
   end)
end)
