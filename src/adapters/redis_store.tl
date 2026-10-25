local redis = require("resty.redis")
local timing = require("config.timing")
local type Environment = require("types.environment")

local record redis_store
   type Fields = {string: string}

   commands: {string}
end

redis_store.commands = { "AUTH", "PING", "GET", "SET", "DEL", "HSET", "HGETALL", "PEXPIRE", "MULTI", "EXEC" }

local function pool_of(environment: Environment): string
   return "edge:" .. environment.redis_user .. "@" .. environment.redis_host .. ":" .. tostring(environment.redis_port)
end

local function sorted_keys(fields: redis_store.Fields): {string}
   local keys: {string} = {}
   for key in pairs(fields) do
      table.insert(keys, key)
   end

   table.sort(keys)

   return keys
end

function redis_store.open(environment: Environment): redis.Client, string
   local client, failure = redis.new()
   if client == nil then
      return nil, failure
   end

   client:set_timeouts(timing.redis_timeout_ms, timing.redis_timeout_ms, timing.redis_timeout_ms)

   local connected, refused = client:connect(
      environment.redis_host,
      environment.redis_port,
      { pool = pool_of(environment), pool_size = timing.redis_pool_size, backlog = timing.redis_pool_size }
   )
   if connected == nil then
      return nil, refused
   end

   local reused = client:get_reused_times()
   if reused ~= nil and reused > 0 then
      return client, nil
   end

   local authed, denied = client:auth(environment.redis_user, environment.redis_password)
   if authed == nil then
      client:close()
      return nil, denied
   end

   return client, nil
end

function redis_store.release(client: redis.Client)
   client:set_keepalive(timing.redis_keepalive_ms, timing.redis_pool_size)
end

function redis_store.discard(client: redis.Client)
   client:close()
end

function redis_store.ping(client: redis.Client): boolean, string
   local reply, failure = client:ping()
   if reply == nil then
      return false, failure
   end

   return reply == "PONG", nil
end

function redis_store.read_hash(client: redis.Client, key: string): redis_store.Fields, string
   local flat, failure = client:hgetall(key)
   if flat == nil then
      return nil, failure
   end

   local fields: redis_store.Fields = {}
   for index = 1, #flat - 1, 2 do
      fields[flat[index]] = flat[index + 1]
   end

   return fields, nil
end

function redis_store.write_hash(
   client: redis.Client,
   key: string,
   fields: redis_store.Fields,
   ttl_ms: integer,
   removed: {string}
): boolean, string
   local arguments: {string} = {}
   for _, name in ipairs(sorted_keys(fields)) do
      table.insert(arguments, name)
      table.insert(arguments, fields[name])
   end

   local opened, refused = client:multi()
   if opened == nil then
      return false, refused
   end

   for _, gone in ipairs(removed) do
      client:del(gone)
   end

   client:hset(key, table.unpack(arguments))
   client:pexpire(key, ttl_ms)

   local results, failure = client:exec()
   if results == nil then
      return false, failure
   end

   if #results ~= #removed + 2 then
      return false, "the transaction did not run every command"
   end

   return true, nil
end

function redis_store.delete(client: redis.Client, keys: {string}): boolean, string
   if #keys == 0 then
      return true, nil
   end

   local reply, failure = client:del(table.unpack(keys))
   if reply == nil then
      return false, failure
   end

   return true, nil
end

function redis_store.claim(client: redis.Client, key: string, owner: string, ttl_ms: integer): boolean, string
   local reply, failure = client:set(key, owner, "NX", "PX", tostring(ttl_ms))
   if reply == nil then
      return false, failure
   end

   return reply == "OK", nil
end

function redis_store.read(client: redis.Client, key: string): string, string
   local reply, failure = client:get(key)
   if reply == nil then
      return nil, failure
   end

   if reply is string then
      return reply, nil
   end

   return nil, nil
end

return redis_store
