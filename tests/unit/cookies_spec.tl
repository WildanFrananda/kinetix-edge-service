local check = require("tests.support.check")
local cookies = require("http.cookies")

local VALUE = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN-_q"

describe("cookies", function()
   it("builds the session cookie with exactly the attributes the design names", function()
      check.equal(
         cookies.session(VALUE, nil),
         "__Host-kx_session=" .. VALUE .. "; Path=/; Secure; HttpOnly; SameSite=Strict",
         "browser-session cookie"
      )
   end)

   it("adds Max-Age only when the application keeps sessions across browser restarts", function()
      check.equal(
         cookies.session(VALUE, 2592000),
         "__Host-kx_session=" .. VALUE .. "; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=2592000",
         "persistent cookie"
      )
   end)

   it("builds the pending cookie with the challenge lifetime", function()
      check.equal(
         cookies.pending(VALUE, 300),
         "__Host-kx_pending=" .. VALUE .. "; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=300",
         "pending cookie"
      )
   end)

   it("expires a cookie with the same attributes and Max-Age=0", function()
      check.equal(
         cookies.expired("__Host-kx_session"),
         "__Host-kx_session=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0",
         "expired cookie"
      )
   end)

   it("reads its own cookie among others", function()
      check.equal(cookies.read("a=1; __Host-kx_session=" .. VALUE .. "; b=2", "__Host-kx_session"), VALUE, "read")
   end)

   it("refuses a cookie sent twice, so no second copy can shadow the first", function()
      local twice = "__Host-kx_session=" .. VALUE .. "; __Host-kx_session=" .. VALUE
      check.absent(cookies.read(twice, "__Host-kx_session"), "duplicate")
   end)

   it("refuses a value that is not 43 base64url characters", function()
      check.absent(cookies.read("__Host-kx_session=short", "__Host-kx_session"), "short value")
      check.absent(cookies.read("__Host-kx_session=" .. VALUE .. "x", "__Host-kx_session"), "long value")
      check.absent(cookies.read("__Host-kx_session=" .. string.rep("+", 43), "__Host-kx_session"), "not base64url")
      check.absent(cookies.read(nil, "__Host-kx_session"), "no header")
   end)

   it("does not read a cookie whose name only ends with the session name", function()
      check.absent(cookies.read("x__Host-kx_session=" .. VALUE, "__Host-kx_session"), "suffix")
   end)
end)
