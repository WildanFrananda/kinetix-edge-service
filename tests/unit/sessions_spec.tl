local apps = require("config.apps")
local check = require("tests.support.check")
local clock = require("adapters.clock")
local redis = require("resty.redis")
local sessions = require("http.sessions")
local type RequestContext = require("types.request_context")
local type SessionLookup = require("types.session_lookup")

local POLICIES = apps.policies({
   redis_host = "r",
   redis_port = 6379,
   redis_user = "edge",
   redis_password = "p",
   identity_url = "http://i:5000",
   api_upstream = "http://g:8000",
   backoffice_origins = { "https://backoffice.example.test" },
   seller_host = "seller.example.test",
   service_version = "v",
})

local REQUEST: RequestContext = {
   request_id = "req-1",
   client_address = "198.51.100.23",
   method = "GET",
   headers = {},
   app = POLICIES[2],
}

local KEY = "edge:session:0123"

local function store(refuses_writes: boolean, deleted: {string}): redis.Client
   return {
      del = function(_: redis.Client, ...: string): redis.Reply, string
         for _, key in ipairs({ ... }) do
            table.insert(deleted, key)
         end

         return 1, nil
      end,
      multi = function(_: redis.Client): redis.Reply, string
         if refuses_writes then
            return nil, "closed"
         end

         return "OK", nil
      end,
      hset = function(_: redis.Client, _: string): redis.Reply, string
         return "QUEUED", nil
      end,
      pexpire = function(_: redis.Client, _: string, _: integer): redis.Reply, string
         return "QUEUED", nil
      end,
      exec = function(_: redis.Client): redis.Replies, string
         return { 1, 1 }, nil
      end,
      close = function(_: redis.Client): integer, string
         return 1, nil
      end,
   }
end

local function found(absolute_end: integer): SessionLookup
   return {
      state = "found",
      key = KEY,
      session = {
         access_token = "a",
         refresh_token = "r",
         access_expires_at = clock.now_ms() + 900000,
         app = "seller-web",
         role = "seller",
         principal_id = "p",
         created_at = 0,
         last_seen = 0,
         absolute_end = absolute_end,
      },
   }
end

describe("sessions.touch", function()
   local scheduled = 0
   local schedule = ngx.timer.at

   before_each(function()
      scheduled = 0
      ngx.timer.at = function(_: number, _: function(boolean)): boolean, string
         scheduled = scheduled + 1
         return true, nil
      end
   end)

   after_each(function()
      ngx.timer.at = schedule
   end)

   it("ends a session that crossed its absolute end after the lookup, instead of calling it a store failure", function()
      local deleted: {string} = {}
      local state = sessions.touch(store(false, deleted), REQUEST, found(clock.now_ms() - 1))
      check.equal(state, "ended", "the session ended")
      check.equal(deleted[1], KEY, "and is deleted")
      check.equal(scheduled, 1, "its tokens are logged out at identity, off the request")
   end)

   it("reports a write the store refused as unavailable", function()
      local state = sessions.touch(store(true, {}), REQUEST, found(clock.now_ms() + 600000))
      check.equal(state, "unavailable", "a store failure")
      check.equal(scheduled, 0, "nothing logged out")
   end)

   it("extends a live session", function()
      local state = sessions.touch(store(false, {}), REQUEST, found(clock.now_ms() + 600000))
      check.equal(state, "found", "touched")
   end)
end)
