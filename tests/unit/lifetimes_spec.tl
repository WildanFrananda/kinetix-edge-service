local check = require("tests.support.check")
local lifetimes = require("http.lifetimes")
local type AppPolicy = require("types.app_policy")
local type Session = require("types.session")

local APP: AppPolicy = {
   name = "backoffice",
   client = "backoffice",
   host = "backoffice.localhost:8443",
   hostname = "backoffice.localhost",
   origin = "https://backoffice.localhost:8443",
   roles = { "admin" },
   enrolment = true,
   persistent_cookie = false,
   idle_seconds = 900,
   absolute_seconds = 28800,
}

local function session(last_seen: integer, absolute_end: integer, access_expires_at: integer): Session
   return {
      access_token = "a",
      refresh_token = "r",
      access_expires_at = access_expires_at,
      app = "backoffice",
      role = "admin",
      principal_id = "p",
      created_at = 0,
      last_seen = last_seen,
      absolute_end = absolute_end,
   }
end

describe("lifetimes", function()
   it("extends the idle limit on use, but never past the absolute end", function()
      check.equal(lifetimes.idle_ttl_ms(APP, 28800000, 0), 900000, "far from the end")
      check.equal(lifetimes.idle_ttl_ms(APP, 28800000, 28500000), 300000, "five minutes before the end")
      check.equal(lifetimes.idle_ttl_ms(APP, 28800000, 28800000), 0, "at the end")
   end)

   it("ends a session at its absolute end however recently it was used", function()
      check.falsy(lifetimes.is_past_absolute(session(0, 1000, 0), 999), "before")
      check.truthy(lifetimes.is_past_absolute(session(999, 1000, 0), 1000), "at")
   end)

   it("refreshes when under the threshold is left", function()
      check.falsy(lifetimes.needs_refresh(session(0, 1, 100000), 39999, 60000), "60.001 s left")
      check.truthy(lifetimes.needs_refresh(session(0, 1, 100000), 40001, 60000), "59.999 s left")
      check.truthy(lifetimes.needs_refresh(session(0, 1, 100000), 200000, 60000), "expired")
   end)

   it("reports the earlier of the idle end and the absolute end", function()
      check.equal(lifetimes.ends_at(APP, session(1000, 28800000, 0)), 901000, "idle first")
      check.equal(lifetimes.ends_at(APP, session(28700000, 28800000, 0)), 28800000, "absolute first")
   end)

   it("gives a cookie a Max-Age only for an application that persists sessions", function()
      check.absent(lifetimes.cookie_max_age(APP), "backoffice")
   end)
end)
