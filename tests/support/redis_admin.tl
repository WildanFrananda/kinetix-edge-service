local redis = require("resty.redis")

local record redis_admin
   host: string
   port: integer
   edge_password: string
end

redis_admin.host = os.getenv("EDGE_TEST_REDIS_HOST")
redis_admin.port = math.floor(tonumber(os.getenv("EDGE_TEST_REDIS_PORT") or "0"))
redis_admin.edge_password = os.getenv("EDGE_TEST_REDIS_EDGE_PASSWORD")

local function connect(user: string, password: string): redis.Client
   local connection = redis.new()
   connection:set_timeouts(2000, 2000, 2000)

   local connected, failure = connection:connect(redis_admin.host, redis_admin.port, nil)
   if connected == nil then
      error("cannot reach the test Redis: " .. tostring(failure))
   end

   local authed, denied = connection:auth(user, password)
   if authed == nil then
      error("the test Redis refused " .. user .. ": " .. tostring(denied))
   end

   return connection
end

function redis_admin.admin(): redis.Client
   return connect("default", os.getenv("EDGE_TEST_REDIS_ADMIN_PASSWORD"))
end

function redis_admin.as_edge(): redis.Client
   return connect("edge", redis_admin.edge_password)
end

function redis_admin.hash(key: string): {string: string}
   local connection = redis_admin.admin()
   local flat = connection:hgetall(key)
   connection:close()

   local fields: {string: string} = {}
   for index = 1, #flat - 1, 2 do
      fields[flat[index]] = flat[index + 1]
   end

   return fields
end

function redis_admin.pttl(key: string): integer
   local connection = redis_admin.admin()
   local reply = connection:pttl(key)
   connection:close()
   if reply is string or reply is userdata then
      return nil
   end

   return reply
end

function redis_admin.keys(pattern: string): {string}
   local connection = redis_admin.admin()
   local reply = connection:keys(pattern)
   connection:close()

   return reply or {}
end

function redis_admin.flush()
   local connection = redis_admin.admin()
   connection:flushall()
   connection:close()
end

return redis_admin
