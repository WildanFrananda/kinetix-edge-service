local check = require("tests.support.check")
local kill_switches = require("http.kill_switches")
local kill_switches_config = require("config.kill_switches")
local type KillSwitchState = require("types.kill_switch_state")

describe("kill_switches", function()
   it("knows all switchable edge features and rejects unknown names", function()
      for _, name in ipairs({ "login", "register", "checkout", "topup", "cart", "payment", "events_ws" }) do
         check.truthy(kill_switches.is_known(name), name .. " is registered")
         local rule = kill_switches_config.find(string.upper(name))
         check.present(rule, name .. " rule lookup is case-insensitive")
         check.equal(rule.default_retry_after, 60, name .. " default Retry-After")
      end

      check.falsy(kill_switches.is_known("catalog_public"), "unknown feature rejected")
      check.falsy(kill_switches.is_known(nil), "nil rejected")
   end)

   it("evaluates active, inactive, and unavailable switch states fail-closed", function()
      local inactive = kill_switches.evaluate_state(nil, false, "checkout")
      check.truthy(inactive.ok, "nil state allows request")
      check.falsy(inactive.unavailable, "not unavailable")

      local disabled_state: KillSwitchState = {
         feature = "checkout",
         enabled = false,
         reason = "",
         messageKey = "MAINTENANCE_CHECKOUT",
         retryAfter = 60,
         updatedAt = "",
         updatedBy = "",
         expiresAt = "",
      }
      local disabled = kill_switches.evaluate_state(disabled_state, false, "checkout")
      check.truthy(disabled.ok, "disabled state allows request")

      local active_state: KillSwitchState = {
         feature = "checkout",
         enabled = true,
         reason = "payment incident",
         messageKey = "MAINTENANCE_PAYMENT_OUTAGE",
         retryAfter = 120,
         updatedAt = "2026-11-27T00:00:00Z",
         updatedBy = "abc",
         expiresAt = "2026-11-27T01:00:00Z",
      }
      local blocked = kill_switches.evaluate_state(active_state, false, "checkout")
      check.falsy(blocked.ok, "enabled switch blocks request")
      check.falsy(blocked.unavailable, "not store failure")
      check.equal(blocked.message_key, "MAINTENANCE_PAYMENT_OUTAGE", "custom messageKey returned")
      check.equal(blocked.retry_after, "120", "custom Retry-After returned")

      local broken = kill_switches.evaluate_state(nil, true, "checkout")
      check.falsy(broken.ok, "Redis failure blocks fail-closed")
      check.truthy(broken.unavailable, "marked unavailable")
   end)
end)
