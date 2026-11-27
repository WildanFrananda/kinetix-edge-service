local metrics = require("adapters.metrics")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local type Environment = require("types.environment")

local record socket_cap_store
end

local function reply_integer(reply: redis.Reply): integer
   if reply == nil then
      return nil
   end

   local raw = tostring(reply)
   if string.match(raw, "^%d+$") == nil then
      return nil
   end

   local parsed = tonumber(raw)
   if parsed == nil then
      return nil
   end

   return math.floor(parsed)
end

local function replies_ok(replies: redis.Replies, count: integer): boolean
   if replies == nil or #replies < count then
      return false
   end

   for index = 1, count do
      if reply_integer(replies[index]) == nil then
         return false
      end
   end

   return true
end

local function drop_slot(client: redis.Client, key: string, conn_id: string, now_ms: integer, ttl_ms: integer): boolean
   local multi_ok = client:multi()
   if not multi_ok then
      return false
   end

   client:zadd(key, 0, conn_id)
   client:zremrangebyscore(key, "-inf", now_ms)
   client:pexpire(key, ttl_ms)

   local replies = client:exec()
   return replies_ok(replies, 3)
end

function socket_cap_store.acquire_client(
   client: redis.Client,
   key: string,
   conn_id: string,
   max_sockets: integer,
   now_ms: integer,
   ttl_ms: integer
): boolean, boolean
   local multi_ok = client:multi()
   if not multi_ok then
      redis_store.discard(client)
      metrics.dependency_failed("redis")
      return false, true
   end

   client:zremrangebyscore(key, "-inf", now_ms)
   client:zadd(key, now_ms + ttl_ms, conn_id)
   client:zcard(key)
   client:pexpire(key, ttl_ms)

   local replies = client:exec()
   if not replies_ok(replies, 4) then
      redis_store.discard(client)
      metrics.dependency_failed("redis")
      return false, true
   end

   local active = reply_integer(replies[3])
   if active > max_sockets then
      if not drop_slot(client, key, conn_id, now_ms, ttl_ms) then
         redis_store.discard(client)
         metrics.dependency_failed("redis")
         return false, true
      end

      redis_store.release(client)
      return false, false
   end

   redis_store.release(client)
   return true, false
end

function socket_cap_store.acquire(
   environment: Environment,
   key: string,
   conn_id: string,
   max_sockets: integer,
   now_ms: integer,
   ttl_ms: integer
): boolean, boolean
   local client = redis_store.open(environment)
   if client == nil then
      metrics.dependency_failed("redis")
      return false, true
   end

   return socket_cap_store.acquire_client(client, key, conn_id, max_sockets, now_ms, ttl_ms)
end

function socket_cap_store.renew(
   environment: Environment,
   key: string,
   conn_id: string,
   now_ms: integer,
   ttl_ms: integer
): boolean
   local client = redis_store.open(environment)
   if client == nil then
      return false
   end

   local multi_ok = client:multi()
   if not multi_ok then
      redis_store.discard(client)
      return false
   end

   client:zremrangebyscore(key, "-inf", now_ms)
   client:zadd(key, now_ms + ttl_ms, conn_id)
   client:pexpire(key, ttl_ms)

   local replies = client:exec()
   if not replies_ok(replies, 3) then
      redis_store.discard(client)
      return false
   end

   redis_store.release(client)
   return true
end

function socket_cap_store.release(
   environment: Environment,
   key: string,
   conn_id: string,
   now_ms: integer,
   ttl_ms: integer
)
   local client = redis_store.open(environment)
   if client == nil then
      return
   end

   if not drop_slot(client, key, conn_id, now_ms, ttl_ms) then
      redis_store.discard(client)
      return
   end

   redis_store.release(client)
end

return socket_cap_store
