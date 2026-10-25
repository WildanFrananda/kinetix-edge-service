local check = require("tests.support.check")
local request_id = require("http.request_id")

describe("request_id", function()
   it("keeps the gateway's id", function()
      local gateway = "7b1f2c3d-aaaa-bbbb-cccc-0123456789ab#12"
      check.equal(request_id.accepted(gateway), gateway, "uuid#n")
   end)

   it("refuses an id that could break a log line or grow without bound", function()
      check.absent(request_id.accepted("a b"), "space")
      check.absent(request_id.accepted("a\"b"), "quote")
      check.absent(request_id.accepted(string.rep("a", 129)), "too long")
      check.absent(request_id.accepted(""), "empty")
   end)
end)
