local check = require("tests.support.check")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")

local REFUSAL = "NOPERM User edge has no permissions to run the 'del' command"

local function refusing(closed: {boolean}): redis.Client
   return {
      del = function(_: redis.Client): redis.Reply, string
         return false as redis.Reply, REFUSAL
      end,
      hgetall = function(_: redis.Client, _: string): {string}, string
         return false as {string}, REFUSAL
      end,
      multi = function(_: redis.Client): redis.Reply, string
         return false as redis.Reply, REFUSAL
      end,
      set = function(_: redis.Client, _: string, _: string): redis.Reply, string
         return false as redis.Reply, REFUSAL
      end,
      close = function(_: redis.Client): integer, string
         closed[1] = true
         return 1, nil
      end,
   }
end

describe("redis_store", function()
   it("reads a Redis error reply as a failure, never as success, and closes the connection", function()
      local closed: {boolean} = { false }
      local deleted, failure = redis_store.delete(refusing(closed), { "edge:session:x" })
      check.falsy(deleted, "DEL refused")
      check.equal(failure, REFUSAL, "the reason")
      check.truthy(closed[1], "the connection is not pooled")
   end)

   it("reports a refused read, write and claim as failures", function()
      local fields, read_failure = redis_store.read_hash(refusing({ false }), "edge:session:x")
      check.absent(fields, "HGETALL refused")
      check.equal(read_failure, REFUSAL, "read reason")

      local written = redis_store.write_hash(refusing({ false }), "edge:session:x", { a = "1" }, 1000, {})
      check.falsy(written, "MULTI refused")

      local claimed, claim_failure = redis_store.claim(refusing({ false }), "edge:refresh:x", "owner", 1000)
      check.falsy(claimed, "SET NX refused")
      check.equal(claim_failure, REFUSAL, "claim reason")
   end)
end)
