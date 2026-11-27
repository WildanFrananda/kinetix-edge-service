local check = require("tests.support.check")
local early_checks = require("http.early_checks")
local type ApiRouteRule = require("types.api_route_rule")

local CHECKOUT_RULE: ApiRouteRule = {
   name = "/api/v1/orders/checkout",
   prefix = "/api/v1/orders/checkout",
   exact = true,
   methods = { "POST" },
   target = "api",
   max_body_bytes = 64,
   require_json = true,
   require_idempotency = true,
   strip_client_header = true,
}

local GENERAL_RULE: ApiRouteRule = {
   name = "/api/v1/orders/{path}",
   prefix = "/api/v1/orders",
   exact = false,
   methods = { "GET", "POST" },
   target = "api",
   max_body_bytes = 64,
   require_json = true,
   require_idempotency = false,
   strip_client_header = true,
}

local function never_read(): string
   error("read_body must not be called when headers already fail")
end

local function returning(body: string): function(): string
   return function(): string
      return body
   end
end

describe("early_checks", function()
   it("requires a bounded non-empty Idempotency-Key on idempotent POST routes", function()
      local missing = early_checks.evaluate(
         CHECKOUT_RULE,
         "POST",
         { ["content-type"] = "application/json" },
         never_read
      )
      check.falsy(missing.ok, "missing key")
      check.equal(missing.error_code, "IDEMPOTENCY_KEY_REQUIRED", "missing error code")

      local blank = early_checks.evaluate(CHECKOUT_RULE, "POST", { ["idempotency-key"] = "   " }, never_read)
      check.falsy(blank.ok, "blank key")

      local too_long = early_checks.evaluate(
         CHECKOUT_RULE,
         "POST",
         { ["idempotency-key"] = string.rep("a", 129) },
         never_read
      )
      check.falsy(too_long.ok, "oversized key")

      local passed = early_checks.evaluate(
         CHECKOUT_RULE,
         "POST",
         { ["idempotency-key"] = "key-123", ["content-type"] = "application/json" },
         returning('{"items":1}')
      )
      check.truthy(passed.ok, "valid key passes")
   end)

   it("refuses oversized Content-Length before reading the body", function()
      local refused = early_checks.evaluate(
         GENERAL_RULE,
         "POST",
         { ["content-length"] = "65", ["content-type"] = "application/json" },
         never_read
      )
      check.falsy(refused.ok, "oversized content-length")
      check.equal(refused.error_code, "PAYLOAD_TOO_LARGE", "413 code")

      local bad_len = early_checks.evaluate(GENERAL_RULE, "POST", { ["content-length"] = "abc" }, never_read)
      check.falsy(bad_len.ok, "invalid content-length")
      check.equal(bad_len.error_code, "INVALID_REQUEST", "400 code")
   end)

   it("refuses oversized body, non-JSON Content-Type, and malformed JSON", function()
      local big_body = early_checks.evaluate(
         GENERAL_RULE,
         "POST",
         { ["content-type"] = "application/json" },
         returning(string.rep("a", 65))
      )
      check.falsy(big_body.ok, "oversized body")
      check.equal(big_body.error_code, "PAYLOAD_TOO_LARGE", "413 code")

      local wrong_type = early_checks.evaluate(
         GENERAL_RULE,
         "POST",
         { ["content-type"] = "text/plain", ["content-length"] = "5" },
         returning("hello")
      )
      check.falsy(wrong_type.ok, "non-json")
      check.equal(wrong_type.error_code, "JSON_REQUIRED", "415 code")

      local malformed = early_checks.evaluate(
         GENERAL_RULE,
         "POST",
         { ["content-type"] = "application/json", ["content-length"] = "4" },
         returning("{bad")
      )
      check.falsy(malformed.ok, "malformed json")
      check.equal(malformed.error_code, "INVALID_REQUEST", "400 code")

      local nan_json = early_checks.evaluate(
         GENERAL_RULE,
         "POST",
         { ["content-type"] = "application/json", ["content-length"] = "9" },
         returning('{"x":NaN}')
      )
      check.falsy(nan_json.ok, "NaN json")
      check.equal(nan_json.error_code, "INVALID_REQUEST", "400 code")
   end)

   it("allows empty POST bodies and GET requests cleanly", function()
      local empty_post = early_checks.evaluate(GENERAL_RULE, "POST", {}, returning(""))
      check.truthy(empty_post.ok, "empty post allowed")

      local get_req = early_checks.evaluate(GENERAL_RULE, "GET", {}, never_read)
      check.truthy(get_req.ok, "GET allowed")
   end)
end)
