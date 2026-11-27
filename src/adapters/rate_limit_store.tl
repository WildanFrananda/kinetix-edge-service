local metrics = require("adapters.metrics")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local secure_random = require("adapters.secure_random")
local type Environment = require("types.environment")

local record rate_limit_store
end

local function extract_count(replies: redis.Replies): integer
   if replies == nil or #replies < 4 then
      return nil
   end

   local raw = tostring(replies[3])
   if string.match(raw, "^%d+$") == nil then
      return nil
   end

   local parsed = tonumber(raw)
   if parsed == nil then
      return nil
   end

   return math.floor(parsed)
end

function rate_limit_store.consume(
   environment: Environment,
   key: string,
   max_requests: integer,
   window_ms: integer,
   now_ms: integer
): boolean, boolean, integer
   local client = redis_store.open(environment)
   if client == nil then
      metrics.dependency_failed("redis")
      return false, true, 0
   end

   local unique = secure_random.hex(6)
   if unique == nil then
      redis_store.discard(client)
      metrics.dependency_failed("redis")
      return false, true, 0
   end

   local cutoff = now_ms - window_ms
   local member = tostring(now_ms) .. ":" .. unique

   local multi_ok = client:multi()
   if not multi_ok then
      redis_store.discard(client)
      metrics.dependency_failed("redis")
      return false, true, 0
   end

   client:zremrangebyscore(key, "-inf", cutoff)
   client:zadd(key, now_ms, member)
   client:zcard(key)
   client:pexpire(key, window_ms)

   local replies = client:exec()
   local count = extract_count(replies)
   if count == nil then
      redis_store.discard(client)
      metrics.dependency_failed("redis")
      return false, true, 0
   end

   redis_store.release(client)
   return count <= max_requests, false, count
end

return rate_limit_store
