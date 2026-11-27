local check = require("tests.support.check")
local digest = require("adapters.digest")
local redis = require("resty.redis")
local socket_cap_store = require("adapters.socket_cap_store")
local socket_caps = require("http.socket_caps")
local socket_caps_config = require("config.socket_caps")

local function make_client(replies: {redis.Reply}, rolled_back_out: {boolean}, state: {string: boolean}): redis.Client
   local exec_calls = 0
   return {
      multi = function(_: redis.Client): redis.Reply, string
         return "OK", nil
      end,
      zremrangebyscore = function(
         _: redis.Client,
         _k: string,
         _a: string | integer,
         _b: string | integer
      ): redis.Reply, string
         return "QUEUED", nil
      end,
      zadd = function(_: redis.Client, _k: string, score: integer, _m: string): redis.Reply, string
         if score == 0 then
            rolled_back_out[1] = true
         end
         return "QUEUED", nil
      end,
      zcard = function(_: redis.Client, _k: string): redis.Reply, string
         return "QUEUED", nil
      end,
      pexpire = function(_: redis.Client, _k: string, _ttl: integer): redis.Reply, string
         return "QUEUED", nil
      end,
      exec = function(_: redis.Client): redis.Replies, string
         exec_calls = exec_calls + 1
         if exec_calls == 1 then
            return replies, nil
         end
         return { 1, 0, 1 }, nil
      end,
      close = function(_: redis.Client): integer, string
         state["closed"] = true
         return 1, nil
      end,
      set_keepalive = function(_: redis.Client, _a: integer, _b: integer): integer, string
         state["pooled"] = true
         return 1, nil
      end,
   } as redis.Client
end

describe("socket_caps", function()
   it("hashes principal IDs in Redis keys and looks up role connection caps", function()
      local key = socket_caps.key_of("prn_driver_77")
      check.equal(key, "edge:ws:cap:" .. digest.sha256_hex("prn_driver_77"), "hashed key")
      check.excludes(key, "prn_driver_77", "raw principal id absent")
      check.equal(socket_caps_config.limit_for_role("courier"), 2, "courier cap")
      check.equal(socket_caps_config.limit_for_role("customer"), 3, "customer cap")
      check.equal(socket_caps_config.limit_for_role("seller"), 5, "seller cap")
      check.equal(socket_caps_config.limit_for_role("unknown"), 3, "default cap")
   end)

   it("admits within cap, rolls back excess connections, and fails closed on Redis error", function()
      local rb1 = { false }
      local st1: {string: boolean} = {}
      local ok, unavail = socket_cap_store.acquire_client(
         make_client({ 0, 1, 2, 1 }, rb1, st1),
         "edge:ws:cap:test",
         "conn-1",
         2,
         1000,
         180000
      )
      check.truthy(ok, "count 2 within cap 2 allowed")
      check.falsy(unavail, "not unavailable")
      check.falsy(rb1[1], "no rollback")
      check.truthy(st1["pooled"], "client released to pool")

      local rb2 = { false }
      local st2: {string: boolean} = {}
      local capped, unavail2 = socket_cap_store.acquire_client(
         make_client({ 0, 1, 3, 1 }, rb2, st2),
         "edge:ws:cap:test",
         "conn-3",
         2,
         1000,
         180000
      )
      check.falsy(capped, "count 3 above cap 2 refused")
      check.falsy(unavail2, "cap refusal not store error")
      check.truthy(rb2[1], "rejected slot rolled back")
      check.truthy(st2["pooled"], "client released after rollback")

      local rb3 = { false }
      local st3: {string: boolean} = {}
      local broken, unavail3 = socket_cap_store.acquire_client(
         make_client({ 0, ngx.null, 1, 1 }, rb3, st3),
         "edge:ws:cap:test",
         "conn-err",
         2,
         1000,
         180000
      )
      check.falsy(broken, "error reply refused")
      check.truthy(unavail3, "marked store failure")
      check.truthy(st3["closed"], "broken client discarded")
      check.falsy(st3["pooled"], "broken client not pooled")
   end)
end)
