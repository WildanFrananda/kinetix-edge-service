local check = require("tests.support.check")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local redis_admin = require("tests.support.redis_admin")

describe("the edge's Redis user", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("may use its own prefix", function()
      local connection = redis_admin.as_edge()
      local reply, failure = connection:set("edge:probe", "1", "PX", "5000")
      connection:close()
      check.equal(reply, "OK", "SET under edge:")
      check.absent(failure, "no refusal")
   end)

   it("is refused every key outside edge: and every command it does not use", function()
      local connection = redis_admin.as_edge()

      local _, other_key = connection:get("KinetixOrder:cart:principal:1")
      check.matches(other_key, "^NOPERM", "another service's key")

      local _, hash_elsewhere = connection:hset("session:1", "a", "b")
      check.matches(hash_elsewhere, "^NOPERM", "a key without the prefix")

      local _, keys = connection:keys("edge:*")
      check.matches(keys, "^NOPERM", "KEYS")

      local _, flush = connection:flushall()
      check.matches(flush, "^NOPERM", "FLUSHALL")

      local _, acl = connection:acl("WHOAMI")
      check.matches(acl, "^NOPERM", "ACL")

      local _, ttl = connection:pttl("edge:probe")
      check.matches(ttl, "^NOPERM", "PTTL, which the edge does not use")

      local _, pub = connection:publish("matching:position:ORD-1", "{}")
      check.matches(pub, "^NOPERM", "PUBLISH is refused for edge")

      local _, other_chan = connection:subscribe("other:channel:1")
      check.matches(other_chan, "^NOPERM", "channels outside matching:position:*")

      connection:close()
   end)

   it("may subscribe to matching:position:* channels and receive position broadcasts", function()
      local subscriber = redis_admin.as_edge()
      local subscribed, sub_err = subscriber:subscribe("matching:position:ORD-ACL-1")
      check.truthy(subscribed ~= nil, "SUBSCRIBE matching:position:* allowed")
      check.absent(sub_err, "no subscribe error")

      redis_admin.publish("matching:position:ORD-ACL-1", "{\"latitude\":-6.2}")
      local reply, read_err = subscriber:read_reply()
      check.absent(read_err, "no read error")
      check.truthy(reply ~= nil and reply[1] == "message", "received pubsub message")
      check.equal(reply[2], "matching:position:ORD-ACL-1", "expected channel")
      check.equal(reply[3], "{\"latitude\":-6.2}", "expected payload")
      subscriber:close()
   end)

   it("gives every key the edge writes a TTL", function()
      flows.session_cookie("seller-web", "seller@example.test")
      flows.login("backoffice", "admin-2fa@example.test", nil)

      local keys = redis_admin.keys("*")
      check.equal(#keys, 2, "a session and a pending sign-in")
      for _, key in ipairs(keys) do
         check.matches(key, "^edge:", key .. " prefix")
         check.at_least(redis_admin.pttl(key), 1, key .. " TTL")
      end
   end)
end)
