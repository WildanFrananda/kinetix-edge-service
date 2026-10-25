local check = require("tests.support.check")
local errors = require("http.errors")

describe("errors", function()
   it("keys every entry by its own code, with a client or server status and a fixed message", function()
      for code, entry in pairs(errors.catalogue) do
         check.equal(entry.code, code, "code of " .. code)
         check.at_least(entry.status, 400, "status of " .. code)
         check.at_most(entry.status, 599, "status of " .. code)
         check.truthy(#entry.message > 0, "message of " .. code)
         check.excludes(entry.message, "kinetix-", "no internal host in " .. code)
      end
   end)

   it("answers outages with 503, never a 401", function()
      check.equal(errors.catalogue["SESSION_STORE_UNAVAILABLE"].status, 503, "redis")
      check.equal(errors.catalogue["IDENTITY_UNAVAILABLE"].status, 503, "identity")
      check.equal(errors.catalogue["API_UNAVAILABLE"].status, 503, "api")
   end)

   it("keeps nginx's own status for the refusals nginx makes", function()
      check.equal(errors.for_status(413).status, 413, "too large")
      check.equal(errors.for_status(400).code, "INVALID_REQUEST", "bad request")
      check.equal(errors.for_status(500).code, "INTERNAL_ERROR", "internal")
   end)
end)
